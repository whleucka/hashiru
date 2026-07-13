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

# Start a fresh warnings digest for this run; log_warn/log_error append to it
# only while the file exists (see lib/common.sh).
: > "${HASHIRU_REPORT}"

# Run scripts
TOTAL=${#SCRIPTS[@]}
STAGE_NAMES=()
STAGE_TIMES=()
RUN_START="$(date +%s)"
STAGE_NUM=0
for script in "${SCRIPTS[@]}"; do
    STAGE_NUM=$(( STAGE_NUM + 1 ))
    script_name="${script##*/}"
    # Tags this stage's warnings in the digest (inherited by the child bash).
    export HASHIRU_STAGE="${script_name}"
    log_info "[${STAGE_NUM}/${TOTAL}] Running: ${script_name}"

    STAGE_START="$(date +%s)"
    if ! bash "${script}"; then
        log_error "Script failed: ${script_name}"
        log_error "Fix the issue and re-run: ./install.sh ${script_name%%[-_.]*}"
        log_error "Full log: ${HASHIRU_LOG}"
        exit 1
    fi
    STAGE_ELAPSED=$(( $(date +%s) - STAGE_START ))
    STAGE_NAMES+=("${script_name}")
    STAGE_TIMES+=("${STAGE_ELAPSED}")

    log_success "[${STAGE_NUM}/${TOTAL}] Completed: ${script_name} ($(fmt_duration "${STAGE_ELAPSED}"))"
done
unset HASHIRU_STAGE

RUN_ELAPSED=$(( $(date +%s) - RUN_START ))
log_success "=========================================="
log_success "Hashiru installation complete in $(fmt_duration "${RUN_ELAPSED}")"
log_success "=========================================="
for idx in "${!STAGE_NAMES[@]}"; do
    log_info "$(printf '  %-18s %s' "${STAGE_NAMES[${idx}]}" "$(fmt_duration "${STAGE_TIMES[${idx}]}")")"
done

if [[ -s "${HASHIRU_REPORT}" ]]; then
    # Move the report aside while printing it: log_warn appends to the report
    # whenever the file exists, so reading and logging the same file would feed
    # itself forever. The move closes that gate; restore afterwards so the
    # first-login notice still finds the digest.
    REPORT_SNAPSHOT="${HASHIRU_REPORT}.print"
    mv "${HASHIRU_REPORT}" "${REPORT_SNAPSHOT}"
    log_warn "Completed with warnings:"
    while IFS= read -r line; do
        log_warn "  ${line}"
    done < "${REPORT_SNAPSHOT}"
    log_warn "Full log: ${HASHIRU_LOG}"
    mv "${REPORT_SNAPSHOT}" "${HASHIRU_REPORT}"
    # Show the digest once more on the first interactive login — after an
    # unattended first-boot install this is the only way the user ever sees it.
    sudo install -Dm644 "${SCRIPT_DIR}/config/profile.d/hashiru-report.sh" \
        /etc/profile.d/hashiru-report.sh
else
    rm -f "${HASHIRU_REPORT}"
fi
