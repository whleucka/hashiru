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
HASHIRU_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly HASHIRU_ROOT

# Unattended mode: set HASHIRU_UNATTENDED=1 to skip interactive prompts and
# auto-reboot at the end. Used by the live-ISO first-boot bootstrap; defaults
# to interactive. Exported so every stage script inherits it.
export HASHIRU_UNATTENDED="${HASHIRU_UNATTENDED:-0}"

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
