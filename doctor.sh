#!/usr/bin/env bash
# doctor.sh — Hashiru health check: is this machine still shaped like Hashiru?
#
# Read-only, safe to run anytime: ./doctor.sh
# Exit code: 0 if no failures (warnings allowed), 1 otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

PASS=0
WARN=0
FAIL=0

ok()      { echo -e "  ${GREEN}✔${NC} $*"; PASS=$(( PASS + 1 )); }
meh()     { echo -e "  ${YELLOW}●${NC} $*"; WARN=$(( WARN + 1 )); }
bad()     { echo -e "  ${RED}✘${NC} $*"; FAIL=$(( FAIL + 1 )); }
# Not checked, and not a problem — this machine opted out. Uncounted on purpose:
# a skip is neither a pass to be proud of nor a warning to act on.
skip()    { echo -e "  ${BLUE}·${NC} $*"; }
section() { echo; echo -e "${BLUE}:: $*${NC}"; }

# --- Install provenance -------------------------------------------------------

section "Install"

if [[ -f /etc/hashiru-release ]]; then
    # shellcheck source=/dev/null
    source /etc/hashiru-release
    ok "hashiru-release: ${HASHIRU_COMMIT:0:12} (installed ${HASHIRU_INSTALL_DATE%%T*})"
else
    meh "/etc/hashiru-release missing (installed before stamping existed — re-run ./install.sh to stamp)"
fi

ok "repo: ${HASHIRU_ROOT}"

# The repo is permanent now — stow links resolve into it — so a checkout that
# can't pull is a machine that can't be updated.
if [[ -d "${HASHIRU_ROOT}/.git" ]]; then
    if [[ -n "$(git -C "${HASHIRU_ROOT}" status --porcelain 2>/dev/null)" ]]; then
        meh "repo has uncommitted changes ('hashiru update' will refuse until they're committed or stashed)"
    else
        ok "repo clean"
    fi
    # No fetch: doctor is read-only and must work offline, so this compares
    # against whatever the last fetch left behind.
    if upstream="$(git -C "${HASHIRU_ROOT}" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)"; then
        behind="$(git -C "${HASHIRU_ROOT}" rev-list --count "HEAD..${upstream}" 2>/dev/null || echo 0)"
        if [[ "${behind}" -eq 0 ]]; then
            ok "up to date with ${upstream} (as of last fetch)"
        else
            meh "${behind} commit(s) behind ${upstream} — run 'hashiru update'"
        fi
    else
        meh "no upstream branch — 'hashiru update' cannot pull (detached HEAD?)"
    fi
else
    bad "${HASHIRU_ROOT} is not a git checkout — 'hashiru update' will not work"
fi

if command -v hashiru &>/dev/null; then
    ok "hashiru CLI on PATH"
else
    meh "hashiru CLI not on PATH (45-config.sh links /usr/local/bin/hashiru)"
fi

for report in "${HASHIRU_REPORT}" "${HASHIRU_REPORT%.txt}.last.txt"; do
    if [[ -s "${report}" ]]; then
        meh "install finished with warnings — see ${report}"
    fi
done

# --- Packages ------------------------------------------------------------------

section "Packages"

# aur.txt failures are often transient build breakage, so missing AUR packages
# warn instead of fail.
for manifest in base.txt wayland.txt terminal.txt fonts.txt dev.txt apps.txt aur.txt; do
    manifest_path="${HASHIRU_ROOT}/pacman/${manifest}"
    [[ -f "${manifest_path}" ]] || { meh "manifest missing from repo: ${manifest}"; continue; }
    missing=()
    while IFS= read -r pkg || [[ -n "${pkg}" ]]; do
        [[ -z "${pkg}" || "${pkg}" =~ ^[[:space:]]*# ]] && continue
        is_pkg_installed "${pkg}" || missing+=("${pkg}")
    done < "${manifest_path}"
    if [[ ${#missing[@]} -eq 0 ]]; then
        ok "${manifest}: all installed"
    elif [[ "${manifest}" == "aur.txt" ]]; then
        meh "${manifest}: missing ${missing[*]} (retry: yay -S ${missing[*]})"
    else
        bad "${manifest}: missing ${missing[*]}"
    fi
done

if command -v yay &>/dev/null; then
    ok "yay available"
else
    bad "yay not installed (20-aur.sh)"
fi

if grep -q '^\[multilib\]' /etc/pacman.conf; then
    ok "multilib repo enabled"
else
    bad "multilib repo not enabled in /etc/pacman.conf"
fi

# --- System services -----------------------------------------------------------

section "System services"

for svc in NetworkManager bluetooth tlp cronie; do
    if is_service_active "${svc}"; then
        ok "${svc}: active"
    else
        bad "${svc}: not active"
    fi
done

for timer in fstrim.timer reflector.timer snapper-timeline.timer snapper-cleanup.timer; do
    if is_service_enabled "${timer}"; then
        ok "${timer}: enabled"
    else
        # Snapper timers only apply on btrfs roots.
        if [[ "${timer}" == snapper-* && "$(findmnt -n -o FSTYPE /)" != "btrfs" ]]; then
            ok "${timer}: n/a (root is not btrfs)"
        else
            bad "${timer}: not enabled"
        fi
    fi
done

if is_pkg_installed docker; then
    if is_service_enabled docker.socket; then
        ok "docker.socket: enabled"
    else
        bad "docker.socket: not enabled"
    fi
    if id -nG "${USER}" | tr ' ' '\n' | grep -qx docker; then
        ok "user in docker group"
    else
        bad "user not in docker group"
    fi
fi

# --- Desktop -------------------------------------------------------------------

section "Desktop"

if command -v Hyprland &>/dev/null; then
    ok "Hyprland: $(Hyprland --version 2>/dev/null | head -1 || echo installed)"
else
    bad "Hyprland not installed"
fi

for usvc in pipewire.socket pipewire-pulse.socket wireplumber.service; do
    if is_service_active "${usvc}" --user; then
        ok "${usvc}: active (user)"
    else
        meh "${usvc}: not active (starts on login; check systemctl --user status ${usvc})"
    fi
done

if [[ -f "${HOME}/.config/environment.d/10-hashiru.conf" ]]; then
    ok "environment.d config present"
else
    bad "environment.d config missing: ${HOME}/.config/environment.d/10-hashiru.conf (30-desktop.sh)"
fi

# Hashiru's multiplexer, installed by 60-herdr.sh —
# the binary comes from herdr.dev and the config is a Hashiru stow package.
if command -v herdr &>/dev/null || [[ -x "${HOME}/.local/bin/herdr" ]]; then
    ok "herdr installed"
else
    bad "herdr missing (60-herdr.sh)"
fi

# --- Shell ---------------------------------------------------------------------

section "Shell"

login_shell="$(getent passwd "${USER}" | cut -d: -f7)"
if [[ "${login_shell}" == */zsh ]]; then
    ok "login shell: ${login_shell}"
else
    bad "login shell is ${login_shell}, expected zsh"
fi

if [[ -d "${HOME}/.oh-my-zsh" ]]; then
    ok "Oh My Zsh installed"
else
    bad "Oh My Zsh missing"
fi

if [[ -d "${HOME}/.oh-my-zsh/custom/themes/powerlevel10k" ]]; then
    ok "Powerlevel10k installed"
else
    bad "Powerlevel10k missing"
fi

# Hashiru sets zsh as the login shell and installs omz + p10k, so it needs a
# .zshrc to exist — but it does not own the file, and how it got there (stowed,
# hand-written, omz's own) is the user's business. 35-zsh.sh deliberately
# removes omz's generated one on the assumption that something else provides it.
if [[ -e "${HOME}/.zshrc" ]]; then
    ok ".zshrc present"
else
    bad ".zshrc missing — zsh is the login shell but nothing configures it"
fi

# --- Storage -------------------------------------------------------------------

section "Storage"

if swapon --show=NAME --noheadings 2>/dev/null | grep -q zram; then
    ok "zram swap active"
else
    bad "zram swap not active"
fi

if [[ "$(findmnt -n -o FSTYPE /)" == "btrfs" ]]; then
    if [[ -f /etc/snapper/configs/root ]]; then
        ok "snapper root config present"
    else
        bad "root is btrfs but snapper config missing (50-snapper.sh)"
    fi
else
    ok "root is not btrfs — snapper n/a"
fi

# --- Config (Hashiru-owned stow packages) ---------------------------------------

section "Config"

STOW_DIR="${HASHIRU_ROOT}/stow"
if [[ -d "${STOW_DIR}" ]]; then
    # A stow package is "applied" when the paths it provides resolve back into
    # the repo. Test the leaf files, not the package's top-level entries: stow
    # folds a package into the shallowest symlink it can, which is almost never
    # the top level. Every package's top entry is `.config`, and ~/.config is a
    # real directory shared by all of them — checking there reports every
    # correctly-stowed package as missing. ~/.config/bat is the actual link.
    #
    # Resolving both sides means this holds wherever stow chose to fold.
    for pkgdir in "${STOW_DIR}"/*/; do
        pkg="${pkgdir%/}"; pkg="${pkg##*/}"


        applied=0
        stray=0
        while IFS= read -r -d '' src; do
            rel="${src#"${pkgdir}"}"
            link="${HOME}/${rel}"
            if [[ -e "${link}" && "$(readlink -f "${link}" 2>/dev/null)" == "$(readlink -f "${src}")" ]]; then
                applied=$(( applied + 1 ))
            else
                stray=$(( stray + 1 ))
            fi
        done < <(find "${pkgdir}" -type f -print0)

        if [[ "${stray}" -eq 0 && "${applied}" -gt 0 ]]; then
            ok "${pkg}: stowed"
        elif [[ "${applied}" -eq 0 ]]; then
            bad "${pkg}: not stowed (cd ${STOW_DIR} && stow --restow --target=${HOME} ${pkg})"
        else
            meh "${pkg}: partially stowed — ${stray}/$(( applied + stray )) file(s) resolve elsewhere (conflict?)"
        fi
    done
else
    bad "stow tree missing: ${STOW_DIR}"
fi

# Dangling links are the signature of a moved or deleted repo — the failure
# mode this whole layout is meant to make loud rather than mysterious.
#
# Only stow-shaped links count. Apps legitimately leave dangling symlinks in
# ~/.config as runtime state — Chromium and Electron write SingletonLock and
# SingletonCookie as links whose "target" is a hostname-pid string, never a
# real path — and flagging those would make this check permanently red. Stow
# always writes a relative path into the stow directory, so match on that.
#
# Only Hashiru's own links are Hashiru's business. A broken link into a personal
# editor-config repo is that repo's problem to report, not this one's.
#
# Both ~/.config and ~/.local are scanned: the bin package owns ~/.local/bin and
# ~/.local/share/hashiru/assets, so a moved checkout breaks `update-system`,
# `msync`, `usb` and friends without leaving a single bad link under ~/.config.
# ~/.local needs one more level of depth than ~/.config to reach the assets dir.
dangling=()
while IFS= read -r -d '' link; do
    [[ -e "${link}" ]] && continue
    target="$(readlink "${link}")"
    case "${target}" in
        ../*|*hashiru*) dangling+=("${link#"${HOME}"/} -> ${target}") ;;
    esac
done < <( { find "${HOME}/.config" -maxdepth 2 -type l -print0 2>/dev/null
            find "${HOME}/.local"  -maxdepth 3 -type l -print0 2>/dev/null; } )

if [[ ${#dangling[@]} -eq 0 ]]; then
    ok "no dangling config symlinks"
else
    bad "dangling config symlinks: ${dangling[*]}"
fi


# --- Summary -------------------------------------------------------------------

# Plain echo, not log_*: log_error would append into a pending report.txt and
# pollute the first-login warnings digest.
echo
if [[ ${FAIL} -eq 0 ]]; then
    echo -e "${GREEN}doctor: ${PASS} ok, ${WARN} warnings, 0 failures${NC}"
else
    echo -e "${RED}doctor: ${PASS} ok, ${WARN} warnings, ${FAIL} failures${NC}"
    exit 1
fi
