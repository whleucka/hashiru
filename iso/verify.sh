#!/usr/bin/env bash
# verify.sh — check a built Hashiru ISO before anyone installs from it.
#
#   ./iso/verify.sh [path/to.iso] [expected-commit]
#
# Defaults to the newest ISO in iso/out/ and to this checkout's HEAD. Read-only,
# needs no root, and takes seconds — it reads the image rather than booting it.
#
# A full install test needs KVM and a display, so it stays manual: test-qemu.sh.
# CI can't do it (no /dev/kvm on hosted runners, and software emulation would
# take hours), which is exactly why these checks exist — they catch the failures
# that have actually been plausible here, without booting anything.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# GitHub refuses a release asset over 2 GiB. The ISO is the release, so busting
# this means CI can build an image it cannot publish.
readonly ASSET_LIMIT=$(( 2 * 1024 * 1024 * 1024 ))

ISO="${1:-}"
if [[ -z "${ISO}" ]]; then
    # shellcheck disable=SC2012  # our ISO names have no spaces
    ISO="$(ls -t "${HERE}"/out/*.iso 2>/dev/null | head -1 || true)"
    [[ -n "${ISO}" ]] || { echo "!! no ISO in ${HERE}/out/ — run build.sh first"; exit 1; }
fi
[[ -f "${ISO}" ]] || { echo "!! not a file: ${ISO}"; exit 1; }

EXPECTED_REF="${2:-$(git -C "${HERE}/.." rev-parse HEAD 2>/dev/null || true)}"

FAIL=0
ok()  { echo "  ✔ $*"; }
bad() { echo "  ✘ $*"; FAIL=1; }

echo "==> Verifying ${ISO##*/}"

# --- size ---------------------------------------------------------------------
bytes="$(stat -c%s "${ISO}")"
gib="$(awk -v b="${bytes}" 'BEGIN{printf "%.2f", b/1073741824}')"
if (( bytes == 0 )); then
    bad "ISO is empty"
elif (( bytes > ASSET_LIMIT )); then
    bad "${gib} GiB exceeds GitHub's 2.00 GiB release-asset limit — cannot be published"
else
    head="$(awk -v b="${bytes}" -v l="${ASSET_LIMIT}" 'BEGIN{printf "%.2f", (l-b)/1073741824}')"
    ok "size ${gib} GiB (${head} GiB under the 2 GiB asset limit)"
fi

# --- unpack just the two files worth checking ---------------------------------
# The installer config and stage0 live in the squashfs, not on the ISO9660
# surface, so both layers have to come apart. Only these paths are extracted;
# unpacking a 1 GiB rootfs to read two files would be silly.
TMP="$(mktemp -d)"
# unsquashfs recreates root-owned dirs; chmod them back so cleanup can't fail.
trap 'chmod -R u+rwX "${TMP}" 2>/dev/null || true; rm -rf "${TMP}"' EXIT

if ! bsdtar -xOf "${ISO}" arch/x86_64/airootfs.sfs > "${TMP}/airootfs.sfs" 2>/dev/null \
    || [[ ! -s "${TMP}/airootfs.sfs" ]]; then
    bad "no arch/x86_64/airootfs.sfs inside the ISO — image is not a usable archiso"
    exit 1
fi
ok "squashfs extracted from the ISO9660 image"

CFG="root/archinstall/user_config.json"
if ! unsquashfs -q -n -d "${TMP}/x" "${TMP}/airootfs.sfs" "${CFG}" root/stage0.sh >/dev/null 2>&1; then
    bad "could not read ${CFG} / root/stage0.sh out of the squashfs"
    exit 1
fi

# --- the commit pin -----------------------------------------------------------
# This is the check that matters. build.sh substitutes __HASHIRU_REF__ with the
# commit being built, and the installed system does `git reset --hard` to it. A
# stale or unsubstituted pin means the ISO installs different code than the one
# it claims to be — the failure mode of building before tagging.
if grep -q '__HASHIRU_REF__' "${TMP}/x/${CFG}"; then
    bad "__HASHIRU_REF__ was never substituted — the ISO would install whatever main is"
else
    pin="$(grep -o 'reset --hard [0-9a-f]\{7,40\}' "${TMP}/x/${CFG}" | awk '{print $3}' | head -1)"
    if [[ -z "${pin}" ]]; then
        bad "no commit pin found in ${CFG}"
    elif [[ -z "${EXPECTED_REF}" ]]; then
        ok "pinned to ${pin:0:12} (nothing to compare against)"
    elif [[ "${pin}" == "${EXPECTED_REF}" ]]; then
        ok "pinned to ${pin:0:12}, matching the expected commit"
    else
        bad "pinned to ${pin:0:12} but expected ${EXPECTED_REF:0:12} — built from the wrong tree"
    fi
fi

# --- stage0 has to be executable in the squashfs ------------------------------
# profiledef.sh sets this via file_permissions; if that sed ever stops matching,
# the live ISO boots to a shell that can't run the installer.
mode="$(stat -c '%a' "${TMP}/x/root/stage0.sh" 2>/dev/null || echo "")"
if [[ "${mode}" == "755" ]]; then
    ok "root/stage0.sh is mode 755"
else
    bad "root/stage0.sh is mode ${mode:-missing}, expected 755 — the installer would not run"
fi

echo
if (( FAIL )); then
    echo "verify: FAILED"
    exit 1
fi
echo "verify: ok"
