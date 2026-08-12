#!/usr/bin/env bash
# Hashiru common library — shared functions for all installation scripts

set -euo pipefail

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Paths
readonly HASHIRU_DATA_DIR="${HOME}/.local/share/hashiru"
readonly HASHIRU_LOG="${HASHIRU_DATA_DIR}/install.log"
# End-of-run warnings digest. install.sh truncates it at run start; warnings
# and errors are appended only while it exists, so ad-hoc sourcing of this
# library can't resurrect a stale digest.
readonly HASHIRU_REPORT="${HASHIRU_DATA_DIR}/report.txt"
HASHIRU_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly HASHIRU_ROOT

# Unattended mode: set HASHIRU_UNATTENDED=1 to skip interactive prompts and
# auto-reboot at the end. Used by the live-ISO first-boot bootstrap; defaults
# to interactive. Exported so every stage script inherits it.
export HASHIRU_UNATTENDED="${HASHIRU_UNATTENDED:-0}"

# Per-machine overrides, sourced before the defaults below so anything it sets
# wins over them. Deliberately gitignored rather than tracked: `hashiru update`
# refuses to run on a dirty checkout, so a tracked config file would make every
# customised machine un-updatable on its first edit. See hashiru.conf.example
# for the `: "${VAR=value}"` idiom, which leaves environment overrides working.
if [[ -f "${HASHIRU_ROOT}/hashiru.conf" ]]; then
    # shellcheck source=/dev/null
    source "${HASHIRU_ROOT}/hashiru.conf"
fi

# Personal dotfiles: the repo 60-dotfiles.sh clones, and where it lands. This is
# the one place Hashiru knows about anyone's personal config — the shipped
# default is the author's, and everything downstream (the stage, doctor) treats
# it as optional. Set it to the empty string to opt out of dotfiles entirely;
# Hashiru's own config lives in stow/ and does not depend on it.
#
# `${VAR-default}` without the colon, so an explicit empty value means "none"
# rather than falling back to the default.
export HASHIRU_DOTFILES_REPO="${HASHIRU_DOTFILES_REPO-https://github.com/whleucka/dotfiles.git}"
export HASHIRU_DOTFILES_DIR="${HASHIRU_DOTFILES_DIR:-${HOME}/.dotfiles}"

# Ensure log directory exists
mkdir -p "${HASHIRU_DATA_DIR}"

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------

_log() {
    local level="$1"
    local color="$2"
    local message="$3"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    # Console output (colored)
    echo -e "${color}[${level}]${NC} ${message}"

    # File output (no colors)
    echo "[${timestamp}] [${level}] ${message}" >> "${HASHIRU_LOG}"

    # Warnings/errors also feed the end-of-run digest (printed by install.sh
    # and shown once on first login), tagged with the stage they came from.
    if [[ ("${level}" == "WARN" || "${level}" == "ERROR") && -f "${HASHIRU_REPORT}" ]]; then
        echo "[${HASHIRU_STAGE:-install}] ${message}" >> "${HASHIRU_REPORT}"
    fi
}

log_info() {
    _log "INFO" "${BLUE}" "$1"
}

log_success() {
    _log "OK" "${GREEN}" "$1"
}

log_warn() {
    _log "WARN" "${YELLOW}" "$1"
}

log_error() {
    _log "ERROR" "${RED}" "$1"
}

# -----------------------------------------------------------------------------
# Error handling
# -----------------------------------------------------------------------------

_error_handler() {
    local exit_code=$?
    local line_number=$1
    log_error "Script failed at line ${line_number} with exit code ${exit_code}"
    exit "${exit_code}"
}

trap '_error_handler ${LINENO}' ERR

# -----------------------------------------------------------------------------
# Idempotency helpers
# -----------------------------------------------------------------------------

is_pkg_installed() {
    pacman -Qi "$1" &>/dev/null
}

is_service_enabled() {
    local service="$1"
    local user_flag="${2:-}"

    if [[ "${user_flag}" == "--user" ]]; then
        systemctl --user is-enabled "${service}" &>/dev/null
    else
        systemctl is-enabled "${service}" &>/dev/null
    fi
}

is_service_active() {
    local service="$1"
    local user_flag="${2:-}"

    if [[ "${user_flag}" == "--user" ]]; then
        systemctl --user is-active "${service}" &>/dev/null
    else
        systemctl is-active "${service}" &>/dev/null
    fi
}

# True if any directory between $HOME and this path is a symlink.
#
# Stow folds a package into the shallowest symlink it can, so a file can be
# "real" only by way of a linked ancestor: ~/.config/bat is a link into a stow
# package, which makes ~/.config/bat/config a regular file that nonetheless
# belongs to stow. Anything reached that way disappears when the ancestor link
# is removed, so it is never a genuine conflict — testing the leaf alone reports
# every file of every correctly-stowed package as a collision.
has_symlinked_ancestor() {
    local p
    p="$(dirname "$1")"
    while [[ "${p}" != "${HOME}" && "${p}" != "/" ]]; do
        [[ -L "${p}" ]] && return 0
        p="$(dirname "${p}")"
    done
    return 1
}

# Echo every path a stow package wants to own that is blocked by a real file.
# One "<target>|<source>" pair per line. Directories are fine (stow descends
# into them), as are files behind a symlinked ancestor (see above).
stow_conflicts() {
    local pkgdir="${1%/}/"
    local src rel target
    while IFS= read -r -d '' src; do
        rel="${src#"${pkgdir}"}"
        target="${HOME}/${rel}"
        [[ -e "${target}" && ! -L "${target}" && ! -d "${target}" ]] || continue
        has_symlinked_ancestor "${target}" && continue
        printf '%s|%s\n' "${target}" "${src}"
    done < <(find "${pkgdir}" -type f -print0)
}

# Stow Hashiru's fallback .zshrc when nothing else provides one, and unstow it
# when something does.
#
# 35-zsh.sh installs zsh, Oh My Zsh, Powerlevel10k and three plugins and makes
# zsh the login shell, then clears omz's generated .zshrc on the assumption that
# a dotfiles repo supplies the real one. With dotfiles opted out, nothing does,
# and the machine boots to a bare prompt with all of that installed but unwired.
# Hashiru does not own ~/.zshrc — it only refuses to leave the shell it
# configured without a config.
#
# Called twice per install, deliberately:
#   45-config.sh — so `hashiru update 45` still works as a config-only command.
#   60-dotfiles.sh — after the dotfiles are cloned and stowed, where "does a
#                    .zshrc exist" is an exact answer rather than a guess. This
#                    is what catches a dotfiles repo that ships no zsh package.
# It is idempotent, so running it twice costs a second stow --restow.
ensure_zshrc() {
    local pkg="zsh-fallback"
    local stow_dir="${HASHIRU_ROOT}/stow"
    local zshrc="${HOME}/.zshrc"
    local fallback_src provider candidate zshrc_is_ours=0

    if [[ ! -d "${stow_dir}/${pkg}" ]]; then
        log_warn "No ${pkg} package in ${stow_dir} — cannot guarantee a ~/.zshrc"
        return 0
    fi
    fallback_src="$(readlink -f "${stow_dir}/${pkg}/.zshrc")"

    # Our own stowed link must not count as "someone else provides it", or the
    # fallback would stand down on its own second run.
    if [[ -L "${zshrc}" && "$(readlink -f "${zshrc}" 2>/dev/null)" == "${fallback_src}" ]]; then
        zshrc_is_ours=1
    fi

    provider=""
    if [[ -e "${zshrc}" && "${zshrc_is_ours}" -eq 0 ]]; then
        provider="existing ~/.zshrc"
    elif [[ -d "${HASHIRU_DOTFILES_DIR}" ]]; then
        # Checkout is here, so the question is answerable exactly: does any
        # package in it ship a .zshrc? Tested with a glob and -e rather than
        # `compgen -G`, which returns success with empty output when the
        # directory doesn't exist — it reports a provider that isn't there.
        for candidate in "${HASHIRU_DOTFILES_DIR}"/*/.zshrc; do
            [[ -e "${candidate}" ]] || continue
            provider="dotfiles checkout"
            break
        done
    fi

    # Note what is deliberately NOT a provider: a configured
    # HASHIRU_DOTFILES_REPO that hasn't been cloned yet. Trusting a URL string
    # is how a machine ends up with zsh as its login shell and no .zshrc at all
    # — the repo may not ship one. When 45-config.sh runs before the clone it
    # stows the fallback; the 60-dotfiles.sh call then removes it again if the
    # dotfiles turned out to provide one after all.
    # --dir rather than cd'ing: this runs from two different stages, and neither
    # should have its working directory changed underneath it.
    if [[ -n "${provider}" ]]; then
        if [[ "${zshrc_is_ours}" -eq 1 ]]; then
            log_info "Removing Hashiru's fallback .zshrc — now provided by ${provider}"
            stow -D --dir="${stow_dir}" --target="${HOME}" "${pkg}" \
                || log_warn "Failed to unstow ${pkg}"
        else
            log_info "Skipping ${pkg} — .zshrc provided by ${provider}"
        fi
    else
        log_info "Stowing ${pkg} — nothing else provides ~/.zshrc"
        stow --restow --dir="${stow_dir}" --target="${HOME}" "${pkg}" \
            || log_warn "Failed to stow ${pkg}"
    fi
}

ensure_dir() {
    local dir="$1"
    local sudo_flag="${2:-}"
    if [[ ! -d "${dir}" ]]; then
        if [[ "${sudo_flag}" == "--sudo" ]]; then
            sudo mkdir -p "${dir}"
        else
            mkdir -p "${dir}"
        fi
        log_info "Created directory: ${dir}"
    fi
}

# -----------------------------------------------------------------------------
# Package management
# -----------------------------------------------------------------------------

install_packages() {
    local manifest="$1"
    local manifest_path="${HASHIRU_ROOT}/pacman/${manifest}"

    if [[ ! -f "${manifest_path}" ]]; then
        log_error "Package manifest not found: ${manifest_path}"
        return 1
    fi

    local packages=()
    while IFS= read -r pkg || [[ -n "${pkg}" ]]; do
        # Skip empty lines and comments
        [[ -z "${pkg}" || "${pkg}" =~ ^[[:space:]]*# ]] && continue
        # Skip already installed packages
        if ! is_pkg_installed "${pkg}"; then
            packages+=("${pkg}")
        fi
    done < "${manifest_path}"

    if [[ ${#packages[@]} -eq 0 ]]; then
        log_info "All packages from ${manifest} already installed"
        return 0
    fi

    log_info "Installing ${#packages[@]} packages from ${manifest}"
    sudo pacman -S --needed --noconfirm "${packages[@]}"
    log_success "Installed packages from ${manifest}"
}

install_aur_packages() {
    local manifest="$1"
    local manifest_path="${HASHIRU_ROOT}/pacman/${manifest}"

    if [[ ! -f "${manifest_path}" ]]; then
        log_error "AUR manifest not found: ${manifest_path}"
        return 1
    fi

    if ! command -v yay &>/dev/null; then
        log_error "yay not installed — run 20-aur.sh first"
        return 1
    fi

    local packages=()
    while IFS= read -r pkg || [[ -n "${pkg}" ]]; do
        [[ -z "${pkg}" || "${pkg}" =~ ^[[:space:]]*# ]] && continue
        if ! is_pkg_installed "${pkg}"; then
            packages+=("${pkg}")
        fi
    done < "${manifest_path}"

    if [[ ${#packages[@]} -eq 0 ]]; then
        log_info "All AUR packages from ${manifest} already installed"
        return 0
    fi

    # Install one at a time so a single flaky AUR build (upstream churn, failed
    # source verification, etc.) doesn't abort the whole bootstrap. Failures are
    # collected and reported; the function still returns success so later stages
    # run. Already-installed packages are skipped on a retry by the loop above.
    log_info "Installing ${#packages[@]} AUR packages from ${manifest}"
    local failed=()
    for pkg in "${packages[@]}"; do
        log_info "Installing AUR package: ${pkg}"
        if yay -S --needed --noconfirm "${pkg}"; then
            log_success "Installed: ${pkg}"
        else
            log_warn "Failed to build/install AUR package: ${pkg} — skipping"
            failed+=("${pkg}")
        fi
    done

    if [[ ${#failed[@]} -gt 0 ]]; then
        log_warn "AUR packages from ${manifest} that did NOT install: ${failed[*]}"
        log_warn "Retry later with: yay -S ${failed[*]}"
    fi
    log_success "Finished AUR packages from ${manifest}"
}

# -----------------------------------------------------------------------------
# Service management
# -----------------------------------------------------------------------------

enable_service() {
    local service="$1"
    local user_flag="${2:-}"

    if [[ "${user_flag}" == "--user" ]]; then
        if ! is_service_enabled "${service}" --user; then
            systemctl --user enable "${service}"
            log_info "Enabled user service: ${service}"
        fi
    else
        if ! is_service_enabled "${service}"; then
            sudo systemctl enable "${service}"
            log_info "Enabled system service: ${service}"
        fi
    fi
}

start_service() {
    local service="$1"
    local user_flag="${2:-}"

    if [[ "${user_flag}" == "--user" ]]; then
        if ! is_service_active "${service}" --user; then
            systemctl --user start "${service}"
            log_info "Started user service: ${service}"
        fi
    else
        if ! is_service_active "${service}"; then
            sudo systemctl start "${service}"
            log_info "Started system service: ${service}"
        fi
    fi
}

enable_and_start_service() {
    local service="$1"
    local user_flag="${2:-}"
    enable_service "${service}" "${user_flag}"
    start_service "${service}" "${user_flag}"
}

# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------

require_arch() {
    if [[ ! -f /etc/arch-release ]]; then
        log_error "This script requires Arch Linux"
        exit 1
    fi
}

require_user() {
    if [[ "${EUID}" -eq 0 ]]; then
        log_error "Do not run as root — script will use sudo when needed"
        exit 1
    fi
}

# HTTPS check (ICMP is blocked on some networks), retried for up to a minute:
# on first boot this can run while NetworkManager is still negotiating DHCP,
# and a one-shot failure would postpone the whole bootstrap to the next boot.
require_network() {
    local attempts=12
    for (( i = 1; i <= attempts; i++ )); do
        if curl -fsI --max-time 5 https://archlinux.org &>/dev/null; then
            return 0
        fi
        if (( i == 1 )); then
            log_info "No network yet — waiting up to $(( attempts * 5 ))s..."
        fi
        sleep 5
    done
    log_error "No network connection"
    exit 1
}

# -----------------------------------------------------------------------------
# Formatting
# -----------------------------------------------------------------------------

# Render a number of seconds as "1h 4m 2s" / "9m 42s" / "37s".
fmt_duration() {
    local s="$1"
    if (( s >= 3600 )); then
        printf '%dh %dm %ds' "$(( s / 3600 ))" "$(( s % 3600 / 60 ))" "$(( s % 60 ))"
    elif (( s >= 60 )); then
        printf '%dm %ds' "$(( s / 60 ))" "$(( s % 60 ))"
    else
        printf '%ds' "${s}"
    fi
}

# -----------------------------------------------------------------------------
# Script header
# -----------------------------------------------------------------------------

script_start() {
    local script_name="$1"
    log_info "=========================================="
    log_info "Starting: ${script_name}"
    log_info "=========================================="
}

script_end() {
    local script_name="$1"
    log_success "Completed: ${script_name}"
}
