#!/usr/bin/env bash
# test-qemu.sh — boot the Hashiru ISO / installed system in QEMU (UEFI) against
# a throwaway virtual disk. Safe to run as a normal user.
#
#   ./test-qemu.sh          install mode — boots the latest out/*.iso (the installer)
#   ./test-qemu.sh run      run mode     — boots the INSTALLED disk, no ISO attached
#
# After the installer finishes and reboots, it would otherwise loop back into
# the ISO (the CD is still "in the drive"). Use `run` mode to boot the system
# you just installed — the equivalent of pulling the USB stick out.
#
# Requires: qemu-base plus qemu-ui-gtk (`-display gtk` below needs the gtk UI
# module, which qemu-base leaves out), edk2-ovmf (UEFI firmware), and /dev/kvm.
# pacman/dev.txt installs all of them; the preflight below says what's missing.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${1:-install}"

case "${MODE}" in
  install|run) ;;
  *) echo "Usage: $0 [install|run]" >&2; exit 2 ;;
esac

# UEFI firmware: read-only CODE + a writable per-VM VARS copy so the installed
# bootloader's UEFI entry persists across reboots within the VM.
OVMF_CODE="/usr/share/edk2/x64/OVMF_CODE.4m.fd"
[[ -f "${OVMF_CODE}" ]] || OVMF_CODE="/usr/share/ovmf/x64/OVMF_CODE.fd"
OVMF_VARS_SRC="/usr/share/edk2/x64/OVMF_VARS.4m.fd"
[[ -f "${OVMF_VARS_SRC}" ]] || OVMF_VARS_SRC="/usr/share/ovmf/x64/OVMF_VARS.fd"

# --- preflight ----------------------------------------------------------------
# Check everything up front and report it all at once, with the package that
# fixes each gap. Without this the first missing piece surfaces as a bare
# "qemu-img: command not found" halfway through, and the next one only after
# that is fixed.
missing_pkgs=()
problems=()
if ! command -v qemu-img &>/dev/null || ! command -v qemu-system-x86_64 &>/dev/null; then
  missing_pkgs+=(qemu-base qemu-ui-gtk)
  problems+=("QEMU is not installed (qemu-img / qemu-system-x86_64).")
elif ! compgen -G '/usr/lib/qemu/ui-gtk*.so' >/dev/null; then
  # qemu-base has the binaries but not the gtk display this script opens.
  missing_pkgs+=(qemu-ui-gtk)
  problems+=("QEMU has no gtk display module (qemu-base doesn't include it).")
fi
if [[ ! -f "${OVMF_CODE}" || ! -f "${OVMF_VARS_SRC}" ]]; then
  missing_pkgs+=(edk2-ovmf)
  problems+=("No UEFI firmware (OVMF) — the ISO only boots UEFI.")
fi
if [[ ! -e /dev/kvm ]]; then
  problems+=("/dev/kvm does not exist: enable virtualization (VT-x / AMD-V, SVM) in the firmware setup, then reboot.")
elif [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
  problems+=("/dev/kvm is not accessible to ${USER}: run 'sudo usermod -aG kvm ${USER}', then log out and back in.")
fi

if (( ${#problems[@]} > 0 )); then
  echo "!! test-qemu.sh can't start the VM yet:" >&2
  for p in "${problems[@]}"; do
    echo "   - ${p}" >&2
  done
  if (( ${#missing_pkgs[@]} > 0 )); then
    echo >&2
    echo "   Install the missing packages with (pacman/dev.txt lists them, so" >&2
    echo "   './install.sh 99' does the same):" >&2
    echo "     sudo pacman -S --needed ${missing_pkgs[*]}" >&2
  fi
  exit 1
fi

# Find the ISO before creating anything, so a missing build doesn't leave a
# fresh 30 GiB disk image behind.
ISO=""
if [[ "${MODE}" == "install" ]]; then
  # shellcheck disable=SC2012  # ls -t for newest-first is fine; our ISO names have no spaces
  ISO="$(ls -t "${HERE}"/out/*.iso 2>/dev/null | head -1 || true)"
  [[ -n "${ISO}" ]] || { echo "!! No ISO in ${HERE}/out/ — run 'sudo ./iso/build.sh' first." >&2; exit 1; }
fi

DISK="${HERE}/work/test-disk.qcow2"
mkdir -p "${HERE}/work"
if [[ ! -f "${DISK}" ]]; then
  if [[ "${MODE}" == "run" ]]; then
    echo "!! No installed disk at ${DISK} — run './test-qemu.sh' (install mode) first." >&2
    exit 1
  fi
  qemu-img create -f qcow2 "${DISK}" 30G
fi

OVMF_VARS="${HERE}/work/OVMF_VARS.fd"
[[ -f "${OVMF_VARS}" ]] || cp "${OVMF_VARS_SRC}" "${OVMF_VARS}"

# shellcheck disable=SC2054  # commas are qemu option syntax, not element separators
QEMU_ARGS=(
  -enable-kvm -m 4096 -smp 2 -machine q35
  -drive if=pflash,format=raw,readonly=on,file="${OVMF_CODE}"
  -drive if=pflash,format=raw,file="${OVMF_VARS}"
  -drive file="${DISK}",if=virtio,format=qcow2
  -vga std -display gtk
)

if [[ "${MODE}" == "run" ]]; then
  echo "==> Booting the INSTALLED system from disk (no ISO attached)."
  QEMU_ARGS+=(-boot c)
else
  echo "==> Booting installer ISO ${ISO##*/}"
  echo "    (after install + reboot, use './test-qemu.sh run' to boot the installed system)"
  QEMU_ARGS+=(-cdrom "${ISO}" -boot d)
fi

echo "    Ctrl+Alt+G releases the mouse."
exec qemu-system-x86_64 "${QEMU_ARGS[@]}"
