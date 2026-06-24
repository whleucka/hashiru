#!/usr/bin/env bash
# Hashiru — Arch + Hyprland bootstrap orchestrator
# Usage: ./install.sh [script_number]
#   No args: run all scripts in sequence
#   With arg: run only that script (e.g., ./install.sh 30)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_arch
require_user
require_network

log_info "=========================================="
log_info " "
log_info "     ▓░ ░ ▓▒▀▓ ▓█▀▀ ▓░ ░ ▓░ ▓█▀▓ ▓█ ░"
log_info "     ▒▓▀▒ ▒░▄▒ ▀▀▒▓ ▒▓▀▒ ▒▒ ▒▓▄▀ ▒▓ ▒"
log_info "     ░  ▓ ░  ░ ▄▄░▒ ░  ▓ ░▓ ░▒ ▒ ░▒▄▓"
log_info " "
log_info "        Arch + Hyprland Bootstrap"
log_info "        Created by: Will Hleucka "
log_info " "
log_info "=========================================="

# Get all scripts in numeric order
mapfile -t SCRIPTS < <(find "${SCRIPT_DIR}/scripts" -maxdepth 1 -name '*.sh' -type f | sort)

if [[ ${#SCRIPTS[@]} -eq 0 ]]; then
    log_error "No scripts found in ${SCRIPT_DIR}/scripts/"
    exit 1
fi

# If argument provided, filter to just that script
if [[ $# -gt 0 ]]; then
    TARGET="$1"
    FILTERED=()
    for script in "${SCRIPTS[@]}"; do
        basename="${script##*/}"
        if [[ "${basename}" == "${TARGET}-"* || "${basename}" == "${TARGET}.sh" ]]; then
            FILTERED+=("${script}")
        fi
    done

    if [[ ${#FILTERED[@]} -eq 0 ]]; then
        log_error "No script matching '${TARGET}' found"
        exit 1
    fi

    SCRIPTS=("${FILTERED[@]}")
fi

# Run scripts
for script in "${SCRIPTS[@]}"; do
    script_name="${script##*/}"
    log_info "Running: ${script_name}"

    if ! bash "${script}"; then
        log_error "Script failed: ${script_name}"
        log_error "Fix the issue and re-run: ./install.sh ${script_name%%[-_.]*}"
        exit 1
    fi

    log_success "Completed: ${script_name}"
done

log_success "=========================================="
log_success "Hashiru installation complete!"
log_success "=========================================="
