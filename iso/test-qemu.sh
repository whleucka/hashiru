#!/usr/bin/env bash
# test-qemu.sh — boot the most recently built ISO in QEMU (UEFI) against a
# throwaway virtual disk, so you can exercise the full installer without
# touching real hardware. Safe to run as a normal user.
#
# Requires: qemu (qemu-full), edk2-ovmf (UEFI firmware).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISO="$(ls -t "${HERE}"/out/*.iso 2>/dev/null | head -1 || true)"
[[ -n "${ISO}" ]] || { echo "No ISO in ${HERE}/out/. Run ./build.sh first."; exit 1; }

DISK="${HERE}/work/test-disk.qcow2"
mkdir -p "${HERE}/work"
[[ -f "${DISK}" ]] || qemu-img create -f qcow2 "${DISK}" 30G

# OVMF path differs across distros; adjust if QEMU can't find UEFI firmware.
OVMF="/usr/share/edk2/x64/OVMF_CODE.4m.fd"
[[ -f "${OVMF}" ]] || OVMF="/usr/share/ovmf/x64/OVMF_CODE.fd"

echo "==> Booting ${ISO##*/} in QEMU (UEFI). Ctrl+Alt+G releases the mouse."
exec qemu-system-x86_64 \
  -enable-kvm -m 4096 -smp 2 -machine q35 \
  -drive if=pflash,format=raw,readonly=on,file="${OVMF}" \
  -cdrom "${ISO}" \
  -drive file="${DISK}",if=virtio,format=qcow2 \
  -boot d -vga virtio
