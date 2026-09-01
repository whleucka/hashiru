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

echo "==> Cleaning previous build artifacts (profile, mkarchiso work, old ISOs)"
# mkarchiso can choke on a leftover work dir or a pre-existing output ISO and
# bail early — wipe the build scratch and any old ISO so every build is fresh.
# (The QEMU test disk lives at ${WORK}/test-disk.qcow2 and is left untouched.)
rm -rf "${PROFILE}" "${WORK}/mkarchiso"
rm -f "${OUT}"/*.iso
mkdir -p "${PROFILE}" "${OUT}"
cp -a "${RELENG}/." "${PROFILE}/"

echo "==> Overlaying Hashiru airootfs"
cp -a "${HERE}/overlay/airootfs/." "${PROFILE}/airootfs/"
mkdir -p "${PROFILE}/airootfs/root/archinstall"
cp -a "${HERE}/archinstall/." "${PROFILE}/airootfs/root/archinstall/"

echo "==> Pinning installer to the ISO's commit"
# The target system clones the repo from GitHub at install time; pin that
# clone to the commit this ISO was built from so the ISO and the code that
# bootstraps the machine can't drift apart. Falls back to 'main' when
# building from a non-git checkout (e.g. a release tarball).
#
# The pin is `reset --hard`, not `checkout --detach`: /opt/hashiru is permanent
# on the installed system and `hashiru update` fast-forwards it, which needs a
# branch with an upstream. Resetting keeps main checked out and tracking
# origin/main while still starting the machine at this exact commit.
# CI passes this explicitly. That is not just convenience: actions/checkout
# falls back to a source tarball when git is missing from the image, leaving no
# .git for rev-parse to read — and the `|| echo main` below would then quietly
# produce an *unpinned* ISO that installs whatever main happens to be. An
# explicit ref removes that failure mode; iso/verify.sh asserts the result.
HASHIRU_REF="${HASHIRU_REF:-$(git -C "${HERE}/.." rev-parse HEAD 2>/dev/null || echo main)}"
if [[ -n "$(git -C "${HERE}/.." status --porcelain 2>/dev/null)" ]]; then
  echo "    WARNING: working tree is dirty — uncommitted changes will NOT be"
  echo "    in the installed system (it checks out ${HASHIRU_REF})."
fi

# A local commit is not enough. The pin is resolved on the *target* machine,
# which clones from GitHub and then resets to this ref — so a ref that exists
# only in this checkout produces an ISO whose install dies at `reset --hard`
# on an unknown object, ten minutes into archinstall. Cheaper to say so now.
#
# Skipped when the ref isn't a sha this checkout knows about (CI passes one
# explicitly, and a tarball build has no .git to ask).
if git -C "${HERE}/.." cat-file -e "${HASHIRU_REF}^{commit}" 2>/dev/null; then
  if ! git -C "${HERE}/.." branch -r --contains "${HASHIRU_REF}" 2>/dev/null | grep -q .; then
    echo "    WARNING: ${HASHIRU_REF:0:12} is on no remote branch — push it first."
    echo "    The installed system clones from GitHub and resets to this ref;"
    echo "    an unpushed commit will fail the install, not this build."
  fi
fi

echo "    ref: ${HASHIRU_REF}"
sed -i "s|__HASHIRU_REF__|${HASHIRU_REF}|g" \
  "${PROFILE}/airootfs/root/archinstall/user_config.json"

echo "==> Dropping packages releng lists that the repos no longer carry"
# pacstrap resolves the list as one transaction, so a single package that has
# been dropped from the repos since this archiso release fails the whole build.
# See overlay/packages.x86_64.drop for what is on the list and why.
while read -r pkg || [[ -n "${pkg}" ]]; do
  pkg="${pkg%%#*}"
  pkg="${pkg//[[:space:]]/}"
  [[ -z "${pkg}" ]] && continue
  if grep -qxF "${pkg}" "${PROFILE}/packages.x86_64"; then
    # grep -vxF, not sed: package names carry regex metacharacters (memtest86+),
    # and a whole-line fixed-string match cannot catch a substring by accident.
    filtered="$(mktemp)"
    grep -vxF "${pkg}" "${PROFILE}/packages.x86_64" > "${filtered}"
    mv "${filtered}" "${PROFILE}/packages.x86_64"
    echo "    dropped: ${pkg}"
  else
    echo "    NOTE: ${pkg} is no longer in releng's list — delete that line from"
    echo "          overlay/packages.x86_64.drop; upstream has caught up."
  fi
done < "${HERE}/overlay/packages.x86_64.drop"

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

# mkarchiso ran as root, so everything under out/ and work/ is root-owned.
# Hand it back to the user who invoked sudo so ./test-qemu.sh works without
# sudo (it reads out/*.iso and writes the qcow2 + OVMF vars under work/).
if [[ -n "${SUDO_USER:-}" ]]; then
  echo "==> Restoring ownership of build artifacts to ${SUDO_USER}"
  chown -R "${SUDO_USER}:$(id -gn "${SUDO_USER}")" "${OUT}" "${WORK}"
fi

# Fail loudly if no ISO was produced (ls errors on no match → set -e aborts).
echo "==> Done. ISO written to:"
ls -la "${OUT}"/*.iso
