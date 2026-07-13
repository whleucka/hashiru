#!/usr/bin/env bash
# Hashiru — Arch + Hyprland bootstrap orchestrator
# Usage: ./install.sh [stage ...]
#   (no args)   run all stages in sequence
#   30          run only stage 30
#   30+         run stage 30 and everything after it (resume a failed run)
#   30 35       run the listed stages
#   --from 30   same as 30+
#   --list      show available stages and exit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# Get all scripts in numeric order
mapfile -t SCRIPTS < <(find "${SCRIPT_DIR}/scripts" -maxdepth 1 -name '*.sh' -type f | sort)

if [[ ${#SCRIPTS[@]} -eq 0 ]]; then
    log_error "No scripts found in ${SCRIPT_DIR}/scripts/"
    exit 1
fi

# --list answers before the network check so it works offline and instantly.
if [[ "${1:-}" == "--list" ]]; then
    echo "Available stages:"
    for script in "${SCRIPTS[@]}"; do
        echo "  ${script##*/}"
    done
    exit 0
fi

# Parse stage selectors up front so a typo fails fast, before any requires.
# Selectors: N (exact stage), N+ (stage N and everything after), --from N.
FULL_RUN=1
if [[ $# -gt 0 ]]; then
    FULL_RUN=0
    SELECTORS=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from)
                [[ $# -ge 2 ]] || { log_error "--from needs a stage number"; exit 1; }
                SELECTORS+=("$2+"); shift 2 ;;
            --from=*)
                SELECTORS+=("${1#--from=}+"); shift ;;
            *)
                SELECTORS+=("$1"); shift ;;
        esac
    done

    FILTERED=()
    for script in "${SCRIPTS[@]}"; do
        basename="${script##*/}"
        stage_num="${basename%%[-_.]*}"
        for sel in "${SELECTORS[@]}"; do
            if [[ "${sel}" == *+ ]]; then
                from="${sel%+}"
                if [[ "${from}" =~ ^[0-9]+$ && "${stage_num}" =~ ^[0-9]+$ ]] \
                    && (( 10#${stage_num} >= 10#${from} )); then
                    FILTERED+=("${script}")
                    break
                fi
            elif [[ "${basename}" == "${sel}-"* || "${basename}" == "${sel}.sh" ]]; then
                FILTERED+=("${script}")
                break
            fi
        done
    done

    if [[ ${#FILTERED[@]} -eq 0 ]]; then
        log_error "No stages matching '${SELECTORS[*]}' found — see ./install.sh --list"
        exit 1
    fi

    SCRIPTS=("${FILTERED[@]}")
fi

require_arch
require_user
require_network

# Manual runs use sudo inside nearly every stage; the default timestamp expires
# after ~5 minutes of no prompting, silently pausing a long install on a hidden
# password prompt (often mid-AUR-build, 10 minutes in). Take the timestamp once
# up front and refresh it in the background until this script exits. Unattended
# firstboot runs have NOPASSWD sudo, so none of this is needed there.
if [[ "${HASHIRU_UNATTENDED}" != "1" ]]; then
    log_info "Caching sudo credentials for the whole run"
    sudo -v
    # stdio detached: an inherited stdout would hold any pipe reading this
    # script's output open for up to 60s (the in-flight sleep) after we exit.
    ( while true; do sleep 60; sudo -n true || exit; kill -0 "$$" || exit; done ) >/dev/null 2>&1 &
    SUDO_KEEPALIVE_PID=$!
    trap 'kill "${SUDO_KEEPALIVE_PID}" 2>/dev/null' EXIT
fi

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
        log_error "Fix the issue, then resume from here: ./install.sh ${script_name%%[-_.]*}+"
        log_error "(or re-run just this stage: ./install.sh ${script_name%%[-_.]*})"
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

# Stamp the system with the commit that bootstrapped it (full runs only — a
# single re-run stage doesn't represent the whole bootstrap). Answers "which
# Hashiru is this machine actually running?" months later: cat /etc/hashiru-release
if [[ "${FULL_RUN}" -eq 1 ]]; then
    HASHIRU_COMMIT="$(git -C "${SCRIPT_DIR}" rev-parse HEAD 2>/dev/null || echo unknown)"
    printf 'HASHIRU_COMMIT=%s\nHASHIRU_INSTALL_DATE=%s\n' \
        "${HASHIRU_COMMIT}" "$(date -Is)" | sudo tee /etc/hashiru-release > /dev/null
    log_info "Stamped /etc/hashiru-release (${HASHIRU_COMMIT:0:12})"
fi
