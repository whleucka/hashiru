#!/usr/bin/env bash
# Hashiru — Arch + Hyprland bootstrap orchestrator
# Usage: ./install.sh [stage ...]
#   (no args)   run all stages in sequence
#   30          run only stage 30
#   30+         run stage 30 and everything after it (resume a failed run)
#   30 35       run the listed stages
#   --from 30   same as 30+
#   --list      show available stages and exit
# Flags:
#   --no-confirm  answer every prompt with yes (implies rebooting at the end)
#   --no-reboot   never reboot, and don't ask — wins over --no-confirm

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# Get all stages in numeric order. Only numerically-prefixed scripts are
# stages; anything else in scripts/ is a helper and must never be swept into a
# full run.
mapfile -t SCRIPTS < <(find "${SCRIPT_DIR}/scripts" -maxdepth 1 -name '[0-9][0-9]-*.sh' -type f | sort)

if [[ ${#SCRIPTS[@]} -eq 0 ]]; then
    log_error "No scripts found in ${SCRIPT_DIR}/scripts/"
    exit 1
fi

# The last stage, before any selector filtering narrows SCRIPTS. Used at the
# bottom to decide whether the run finished the bootstrap and should offer a
# reboot — by position rather than by name, so renaming or adding a final stage
# doesn't quietly stop the prompt from appearing.
FINAL_STAGE="${SCRIPTS[-1]##*/}"

# --list answers before the network check so it works offline and instantly.
if [[ "${1:-}" == "--list" ]]; then
    echo "Available stages:"
    for script in "${SCRIPTS[@]}"; do
        echo "  ${script##*/}"
    done
    exit 0
fi

# Parse arguments up front so a typo fails fast, before any requires.
# Selectors: N (exact stage), N+ (stage N and everything after), --from N.
# Flags: --no-confirm answers every prompt yes, --no-reboot never reboots.
#
# Flags are peeled out of the argument list here rather than left among the
# selectors, because a bare `./install.sh --no-confirm` is still a *full* run —
# leaving it in would set FULL_RUN=0 and then fail with "no stages matching
# '--no-confirm'". For the same reason unrecognised flags are rejected by name
# instead of falling through to the selector matcher, which could only ever
# report them as a missing stage.
FULL_RUN=1
ASSUME_YES=0
NO_REBOOT=0
SELECTORS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-confirm|--noconfirm)
            ASSUME_YES=1; shift ;;
        --no-reboot|--noreboot)
            NO_REBOOT=1; shift ;;
        --from)
            [[ $# -ge 2 ]] || { log_error "--from needs a stage number"; exit 1; }
            SELECTORS+=("$2+"); shift 2 ;;
        --from=*)
            SELECTORS+=("${1#--from=}+"); shift ;;
        -*)
            log_error "Unknown flag: $1"
            log_error "Flags: --no-confirm, --no-reboot, --from N, --list"
            exit 1 ;;
        *)
            SELECTORS+=("$1"); shift ;;
    esac
done

# Exported so stages inherit the answer. Nothing in scripts/ prompts today —
# every pacman and yay call already passes --noconfirm — but a stage that grows
# a prompt should read this rather than invent a second flag for it.
export HASHIRU_ASSUME_YES="${ASSUME_YES}"

if [[ ${#SELECTORS[@]} -gt 0 ]]; then
    FULL_RUN=0

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

# Check connectivity once up front, but only when a selected stage actually
# needs it. A stage opts out with `# hashiru: offline` in its header; unmarked
# stages are assumed to need the network, so a new stage is fail-safe.
#
# This is for `./install.sh 45` — restowing config, and the common case per the
# README — which had no reason to sit through an HTTPS probe that can wait a
# full minute before giving up.
NEEDS_NETWORK=0
for script in "${SCRIPTS[@]}"; do
    if ! grep -qx '# hashiru: offline' "${script}"; then
        NEEDS_NETWORK=1
        break
    fi
done
if [[ "${NEEDS_NETWORK}" -eq 1 ]]; then
    require_network
else
    log_info "Selected stages need no network — skipping connectivity check"
fi

# Two background helpers want tearing down at exit — the sudo keepalive below
# and the progress ticker further down — so they share one trap. A second
# `trap ... EXIT` would silently replace the first rather than add to it.
SUDO_KEEPALIVE_PID=""
PROGRESS_TICKER_PID=""
_cleanup() {
    [[ -n "${SUDO_KEEPALIVE_PID}" ]] && kill "${SUDO_KEEPALIVE_PID}" 2>/dev/null
    [[ -n "${PROGRESS_TICKER_PID}" ]] && kill "${PROGRESS_TICKER_PID}" 2>/dev/null
    # A run killed with Ctrl-C would otherwise leave the state file behind, and
    # a stale one makes _progress_active true for every later command on a
    # machine whose hashiru.conf sets HASHIRU_QUIET=1.
    rm -f "${HASHIRU_PROGRESS}"
    return 0
}
trap _cleanup EXIT

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
fi

# Run scripts
TOTAL=${#SCRIPTS[@]}

# Initialise progress state BEFORE the banner, not after. log_info stops
# reaching the console once a run is in progress, and that is exactly what keeps
# this banner out of a quiet run: on first boot the firstboot wrapper has
# already drawn a better version of it — cleared screen, instructions, where the
# log lives — and a second copy just scrolls that off the top.
#
# The banner still reaches the log either way, where it separates one run from
# the next.
progress_init "${TOTAL}"

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

# Animate the elapsed clock, so a four-minute cargo build doesn't read as a hung
# machine. It re-reads the state file rather than inheriting variables, which is
# why the label keeps up with stages that set it from a child process.
#
# Same shape as the sudo keepalive above, including the detached stdio and for
# the same reason — except fd 3, which is the console it draws on.
if _progress_active; then
    ( while true; do sleep 1; progress_render; done ) >/dev/null 2>&1 &
    PROGRESS_TICKER_PID=$!
fi

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
    progress_stage "${STAGE_NUM}" "${script_name}"

    STAGE_START="$(date +%s)"
    # In quiet mode the stage's own output goes to the log and the console keeps
    # the progress line; log_info and friends still reach the console on fd 3.
    STAGE_OK=1
    if [[ "${HASHIRU_QUIET}" == "1" ]]; then
        bash "${script}" >> "${HASHIRU_LOG}" 2>&1 || STAGE_OK=0
    else
        bash "${script}" || STAGE_OK=0
    fi
    if [[ "${STAGE_OK}" -eq 0 ]]; then
        progress_clear
        # Quiet mode swallowed the output that explains this, so hand back the
        # tail of it. Without this a failed unattended install shows a progress
        # bar and nothing else, which is strictly worse than the flood.
        if [[ "${HASHIRU_QUIET}" == "1" && -s "${HASHIRU_LOG}" ]]; then
            echo "--- last 40 lines of ${HASHIRU_LOG} ---" >&3
            tail -n 40 "${HASHIRU_LOG}" >&3
            echo "--- end of log tail ---" >&3
        fi
        rm -f "${HASHIRU_PROGRESS}"
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

# Every stage has run, so there is no child output left to hide. Stop the
# ticker, wipe the progress line, and leave quiet mode — the summary, the
# warnings digest and the reboot prompt below are the whole point of the run
# and print exactly as they always have.
if [[ -n "${PROGRESS_TICKER_PID}" ]]; then
    kill "${PROGRESS_TICKER_PID}" 2>/dev/null || true
    PROGRESS_TICKER_PID=""
fi
progress_done
HASHIRU_QUIET=0

RUN_ELAPSED=$(( $(date +%s) - RUN_START ))

# Say it in the headline, not three lines further down. An unattended run that
# finished with AUR packages missing should not read the same as a clean one —
# install_aur_packages demotes build failures to warnings on purpose, and the
# digest below is the only record that they happened.
WARN_COUNT=0
if [[ -s "${HASHIRU_REPORT}" ]]; then
    WARN_COUNT="$(wc -l < "${HASHIRU_REPORT}")"
fi

log_success "=========================================="
if (( WARN_COUNT > 0 )); then
    log_success "Hashiru installation complete in $(fmt_duration "${RUN_ELAPSED}") — ${WARN_COUNT} warning(s)"
else
    log_success "Hashiru installation complete in $(fmt_duration "${RUN_ELAPSED}")"
fi
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
    # A tag reads; twelve hex characters do not. `v1.7.1-3-gd89829e` says which
    # release this machine is on and how far past it — the commit is still
    # recorded beside it. The ISO clones with full history, so the tags needed
    # for this are present; anything else degrades to "unknown".
    HASHIRU_VERSION="$(git -C "${SCRIPT_DIR}" describe --tags 2>/dev/null || echo unknown)"
    printf 'HASHIRU_VERSION=%s\nHASHIRU_COMMIT=%s\nHASHIRU_INSTALL_DATE=%s\n' \
        "${HASHIRU_VERSION}" "${HASHIRU_COMMIT}" "$(date -Is)" | sudo tee /etc/hashiru-release > /dev/null
    log_info "Stamped /etc/hashiru-release (${HASHIRU_VERSION})"
fi

# Reboot last, after the stamp above — stage 99 used to do this itself, which
# meant a full interactive install rebooted before it could record its own
# commit. Unattended runs never prompt: hashiru-firstboot reboots after it
# disables its unit, and a reboot from in here would race that disable into a
# boot loop.
if [[ "${HASHIRU_UNATTENDED}" == "1" ]]; then
    log_info "Unattended mode — firstboot will reboot"
elif [[ " ${STAGE_NAMES[*]} " == *" ${FINAL_STAGE} "* ]]; then
    log_info "Reboot to start Hyprland."
    # --no-reboot is checked before --no-confirm on purpose. "Answer yes to
    # everything" and "never reboot" only look contradictory: the useful
    # combination is both at once — a fully unattended run that leaves the
    # machine up — so the narrower, non-destructive flag has to win.
    if [[ "${NO_REBOOT}" -eq 1 ]]; then
        log_info "--no-reboot — run 'sudo reboot' when ready"
    elif [[ "${ASSUME_YES}" -eq 1 ]]; then
        log_info "--no-confirm — rebooting..."
        sudo reboot
    elif [[ -t 0 ]]; then
        read -rp "Reboot now? [y/N] " response
        if [[ "${response}" =~ ^[Yy]$ ]]; then
            log_info "Rebooting..."
            sudo reboot
        fi
    else
        log_info "Non-interactive session — run 'sudo reboot' when ready"
    fi
fi
