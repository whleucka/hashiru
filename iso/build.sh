#!/usr/bin/env bash
# build.sh — assemble and build the Hashiru live ISO.
#
# Strategy: start from the official archiso `releng` profile, overlay our
# Hashiru customizations on top, brand it, then run mkarchiso. We deliberately
# do NOT vendor the whole releng profile into the repo — copying it at build
# time means we track upstream archiso (bootloaders, package list) for free.
#
# Requires: archiso (provides mkarchiso). Must run as root.
#   sudo pacman -S archiso
#   sudo ./iso/build.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELENG="/usr/share/archiso/configs/releng"
WORK="${HERE}/work"
OUT="${HERE}/out"
PROFILE="${WORK}/profile"

[[ ${EUID} -eq 0 ]] || { echo "Run as root — mkarchiso needs it."; exit 1; }
[[ -d "${RELENG}" ]] || { echo "archiso not installed. Run: pacman -S archiso"; exit 1; }

echo "==> Resetting profile from releng (${RELENG})"
rm -rf "${PROFILE}"
mkdir -p "${PROFILE}" "${OUT}"
cp -a "${RELENG}/." "${PROFILE}/"

echo "==> Overlaying Hashiru airootfs"
cp -a "${HERE}/overlay/airootfs/." "${PROFILE}/airootfs/"
mkdir -p "${PROFILE}/airootfs/root/archinstall"
cp -a "${HERE}/archinstall/." "${PROFILE}/airootfs/root/archinstall/"

echo "==> Adding extra packages to the live image"
# git + archinstall already ship in releng; jq is what stage0 needs for creds.
cat "${HERE}/overlay/packages.x86_64.extra" >> "${PROFILE}/packages.x86_64"

echo "==> Branding profiledef"
sed -i \
  -e 's|^iso_name=.*|iso_name="hashiru"|' \
  -e 's|^iso_publisher=.*|iso_publisher="Hashiru <https://github.com/whleucka/hashiru>"|' \
  -e 's|^iso_application=.*|iso_application="Hashiru Live Installer"|' \
  "${PROFILE}/profiledef.sh"

echo "==> Marking installer scripts executable in the squashfs"
sed -i '/^file_permissions=(/a\  ["/root/stage0.sh"]="0:0:755"' "${PROFILE}/profiledef.sh"

echo "==> Building ISO (mkarchiso)"
mkarchiso -v -w "${WORK}/mkarchiso" -o "${OUT}" "${PROFILE}"

echo "==> Done. ISO written to ${OUT}/"
ls -1 "${OUT}"/*.iso 2>/dev/null || true
