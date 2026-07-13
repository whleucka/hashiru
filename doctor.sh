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

# --- Dotfiles ------------------------------------------------------------------

section "Dotfiles"

if [[ -d "${HOME}/.dotfiles" ]]; then
    ok "dotfiles present at ${HOME}/.dotfiles"
    if [[ -L "${HOME}/.zshrc" ]]; then
        ok ".zshrc is stowed (symlink)"
    else
        bad ".zshrc is not a symlink — stow conflict? (60-dotfiles.sh)"
    fi
else
    bad "dotfiles missing at ${HOME}/.dotfiles (60-dotfiles.sh)"
fi

if [[ -d "${HOME}/.config/tmux/plugins/tpm" ]]; then
    ok "TPM installed"
else
    bad "TPM missing (60-dotfiles.sh)"
fi

if is_service_enabled tmux.service --user; then
    ok "tmux.service: enabled (user)"
else
    meh "tmux.service: not enabled (user)"
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
