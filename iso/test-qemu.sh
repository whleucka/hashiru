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
# Requires: qemu-desktop (NOT qemu-base — `-display gtk` below needs the gtk UI
# module, which only the desktop/full packages pull in), edk2-ovmf (UEFI
# firmware), and /dev/kvm.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${1:-install}"

DISK="${HERE}/work/test-disk.qcow2"
mkdir -p "${HERE}/work"
[[ -f "${DISK}" ]] || qemu-img create -f qcow2 "${DISK}" 30G

# UEFI firmware: read-only CODE + a writable per-VM VARS copy so the installed
# bootloader's UEFI entry persists across reboots within the VM.
OVMF_CODE="/usr/share/edk2/x64/OVMF_CODE.4m.fd"
[[ -f "${OVMF_CODE}" ]] || OVMF_CODE="/usr/share/ovmf/x64/OVMF_CODE.fd"
OVMF_VARS_SRC="/usr/share/edk2/x64/OVMF_VARS.4m.fd"
[[ -f "${OVMF_VARS_SRC}" ]] || OVMF_VARS_SRC="/usr/share/ovmf/x64/OVMF_VARS.fd"
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
  # shellcheck disable=SC2012  # ls -t for newest-first is fine; our ISO names have no spaces
  ISO="$(ls -t "${HERE}"/out/*.iso 2>/dev/null | head -1 || true)"
  [[ -n "${ISO}" ]] || { echo "No ISO in ${HERE}/out/. Run ./build.sh first."; exit 1; }
  echo "==> Booting installer ISO ${ISO##*/}"
  echo "    (after install + reboot, use './test-qemu.sh run' to boot the installed system)"
  QEMU_ARGS+=(-cdrom "${ISO}" -boot d)
fi

echo "    Ctrl+Alt+G releases the mouse."
exec qemu-system-x86_64 "${QEMU_ARGS[@]}"
