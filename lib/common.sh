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
# Live progress state, as one "stage|total|name|label|start_epoch" line.
#
# A file rather than exported variables because progress crosses process
# boundaries in both directions: install.sh sets the stage, a *child* stage sets
# the label, and the ticker that animates the clock is a third process. Exports
# only travel parent-to-child, so they cannot carry a label back out of a stage.
readonly HASHIRU_PROGRESS="${HASHIRU_DATA_DIR}/progress"
HASHIRU_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly HASHIRU_ROOT

# Per-machine overrides, sourced before the defaults below so anything it sets
# wins over them. Deliberately gitignored rather than tracked: `hashiru update`
# refuses to run on a dirty checkout, so a tracked config file would make every
# customised machine un-updatable on its first edit. See hashiru.conf.example
# for the `: "${VAR=value}"` idiom, which leaves environment overrides working.
#
# ~/.config/hashiru/ is also where per-machine *config* overrides live (hypr
# modules, kitty snippets, waybar CSS) — see docs/internals.md. Same reasoning:
# outside the repo means outside anything `hashiru update` can revert.
#
# This must stay ABOVE the defaults: the `: "${VAR=value}"` idiom only assigns
# when the variable is unset, so defaulting anything first would make the
# corresponding hashiru.conf line a silent no-op.
#
# Canonical location first. Because these files use `: "${VAR=value}"`, the
# first file to set a variable wins — so ~/.config wins over the legacy in-repo
# copy when both exist. The in-repo path stays supported: machines predating the
# move still have one, and silently ignoring it would change their behaviour.
HASHIRU_CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/hashiru"
readonly HASHIRU_CONFIG_DIR

for _conf in "${HASHIRU_CONFIG_DIR}/hashiru.conf" "${HASHIRU_ROOT}/hashiru.conf"; do
    if [[ -f "${_conf}" ]]; then
        # shellcheck source=/dev/null
        source "${_conf}"
    fi
done
unset _conf

# Unattended mode: set HASHIRU_UNATTENDED=1 to skip interactive prompts and
# auto-reboot at the end. Used by the live-ISO first-boot bootstrap; defaults
# to interactive. Exported so every stage script inherits it.
export HASHIRU_UNATTENDED="${HASHIRU_UNATTENDED:-0}"

# Quiet mode: keep child-process output (pacman transactions, makepkg builds,
# git clones) off the console and in the log, behind a single progress line.
#
# Defaults to whatever HASHIRU_UNATTENDED is, which is the whole point: on the
# ISO's first boot the flood is the entire problem and nobody is reading it,
# while a manual `./install.sh 45` stays verbose because that output is what
# gets debugged against. Force either way from hashiru.conf or the environment.
export HASHIRU_QUIET="${HASHIRU_QUIET:-${HASHIRU_UNATTENDED}}"

# Answer every prompt with yes. install.sh sets this from --no-confirm and owns
# its value; the default here is only so a stage run on its own doesn't trip
# `set -u`. Deliberately not a hashiru.conf knob — its partner --no-reboot isn't
# one either, so a machine that turned it on in config would have no way to
# turn the auto-reboot back off in config. HASHIRU_UNATTENDED is the setting for
# "never ask me anything on this machine".
#
# Nothing in scripts/ prompts today — every pacman and yay call already passes
# --noconfirm — but a stage that grows a prompt should read this rather than
# invent a flag of its own.
export HASHIRU_ASSUME_YES="${HASHIRU_ASSUME_YES:-0}"

# Skip the synchronous mirror ranking in stage 10 (--no-reflector). Worth
# setting in hashiru.conf on a machine whose mirrors are already fine: the
# ranking is an argument about first install, and reflector.timer has been
# keeping the list fresh weekly ever since.
export HASHIRU_NO_REFLECTOR="${HASHIRU_NO_REFLECTOR:-0}"

# fd 3 is "the console", wherever that was when the run started.
#
# Quiet mode redirects each stage's stdout and stderr into the log, which would
# otherwise take the log lines with it — so console output gets a descriptor of
# its own, opened once and inherited by every child.
#
# The guard is load-bearing. common.sh is sourced by every stage, and a stage's
# bash inherits fd 3 from install.sh; without it, a stage whose stdout is the
# log file would re-point fd 3 at the log and silence the console for the rest
# of the run.
if [[ ! -e /proc/self/fd/3 ]]; then
    exec 3>&1
fi

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

    # Console output (colored), on fd 3 rather than stdout — see above.
    if _progress_active; then
        # The bar owns the last console line. INFO and OK are already in the log
        # and are what the bar's own label describes, so only warnings and
        # errors earn a line of their own: clear the bar, print, redraw beneath.
        if [[ "${level}" == "WARN" || "${level}" == "ERROR" ]]; then
            printf '\r\033[K' >&3
            echo -e "${color}[${level}]${NC} ${message}" >&3
            progress_render
        fi
    else
        echo -e "${color}[${level}]${NC} ${message}" >&3
    fi

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
    # One transaction for the whole manifest, so there is no honest per-package
    # fraction to show — breaking it into per-package calls to animate a bar
    # would be slower and would take dependency resolution down with it.
    progress_set "${manifest} — ${#packages[@]} packages"
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

    # Batch first, then isolate.
    #
    # The serial loop below is what makes a flaky AUR build survivable — one
    # package failing on upstream churn or a bad source checksum must not abort
    # the whole bootstrap. But paying it unconditionally costs a separate
    # dependency resolution and a separate --removemake cycle for every package,
    # over largely the same build dependencies: seven of each on a stock
    # aur.txt. One batched call collapses that to one in the common case where
    # everything builds, and the loop still runs, unchanged, the moment anything
    # doesn't. Nothing about the isolation property is given up — it is just no
    # longer paid for when there is nothing to isolate.
    #
    # --removemake drops build-only dependencies once the package is built.
    # Beyond keeping the system lean, this avoids a real conflict: a Rust AUR
    # package (sherlock-confetti) makedepends on `rust`, while dev.txt installs
    # `rustup` — and rustup declares `Conflicts With: rust`. Leaving the build
    # dep behind therefore broke stage 99 with "conflicting packages" on every
    # fresh install. Build deps are not part of the machine's definition, so
    # they should not outlive the build that needed them. Batching keeps that
    # true and removes them once rather than once per package.
    log_info "Installing ${#packages[@]} AUR packages from ${manifest}"
    progress_set "AUR — ${#packages[@]} packages"
    if yay -S --needed --noconfirm --removemake "${packages[@]}"; then
        log_success "Finished AUR packages from ${manifest}"
        return 0
    fi
    log_warn "Batched AUR install failed — retrying one at a time to find out which"

    # Already-installed packages are skipped cheaply by --needed on the retry,
    # so anything the batch did manage to land is not rebuilt here.
    local failed=()
    local idx=0
    for pkg in "${packages[@]}"; do
        idx=$(( idx + 1 ))
        progress_set "AUR ${idx}/${#packages[@]} — ${pkg}"
        log_info "Installing AUR package: ${pkg}"
        if yay -S --needed --noconfirm --removemake "${pkg}"; then
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
# Progress display
# -----------------------------------------------------------------------------
#
# One console line, redrawn in place, with the full output kept in the log.
#
# Only ever active in quiet mode on a real terminal. Everywhere else — a pipe, a
# redirect, CI, any non-quiet run — this degrades to the ordinary log_info
# stream, so nothing ever writes escape sequences into a file.
#
# Granularity is deliberately limited to what is actually known. Stage count is
# real, and so is the AUR loop's package index. A pacman transaction's internal
# progress is not, so install_packages contributes a label and no fraction:
# smoothing the bar out of guessed stage weights would only be a nicer lie.

# State shared by the readers below. Declared here so `set -u` holds even if
# nothing has populated them yet.
_p_num=0 _p_total=0 _p_name='' _p_label='' _p_start=0

# Quiet mode, a console that can be redrawn, and a run actually in progress.
#
# That last condition is what keeps this scoped to installs. The state file only
# exists between progress_init and progress_done, so `hashiru update`, `hashiru
# status` and doctor keep their ordinary output even on a machine whose
# hashiru.conf sets HASHIRU_QUIET=1 — otherwise setting that once would silence
# every command in the suite.
_progress_active() {
    [[ "${HASHIRU_QUIET}" == "1" && -t 3 && -f "${HASHIRU_PROGRESS}" ]]
}

# Console width via TIOCGWINSZ on the console descriptor, not tput: tty1 on
# first boot frequently has no TERM for tput to look up, and stdout there is the
# log file rather than a terminal at all.
_console_cols() {
    local size cols
    if size="$(stty size <&3 2>/dev/null)"; then
        cols="${size##* }"
        if [[ "${cols}" =~ ^[0-9]+$ ]] && (( cols >= 40 )); then
            printf '%s' "${cols}"
            return 0
        fi
    fi
    printf '80'
}

# Write the state file through a rename so a reader never catches a half-written
# line: the ticker polls this file once a second while stages are rewriting it.
_progress_write() {
    local tmp="${HASHIRU_PROGRESS}.$$"
    printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" > "${tmp}"
    mv -f "${tmp}" "${HASHIRU_PROGRESS}"
}

_progress_read() {
    [[ -f "${HASHIRU_PROGRESS}" ]] || return 1
    IFS='|' read -r _p_num _p_total _p_name _p_label _p_start < "${HASHIRU_PROGRESS}" || return 1
    return 0
}

# Start a run of <total> stages. install.sh owns this.
progress_init() {
    _progress_write 0 "$1" '' '' "$(date +%s)"
}

# Enter stage <num>, named <name>. install.sh owns this too.
progress_stage() {
    _progress_read || return 0
    _progress_write "$1" "${_p_total}" "$2" '' "${_p_start}"
    progress_render
}

# Describe what the current stage is doing. Called from inside stages, which are
# child processes — hence the state file rather than an exported variable.
progress_set() {
    _progress_read || return 0
    _progress_write "${_p_num}" "${_p_total}" "${_p_name}" "$1" "${_p_start}"
    progress_render
}

progress_render() {
    _progress_active || return 0
    _progress_read || return 0
    [[ "${_p_total}" =~ ^[0-9]+$ ]] && (( _p_total > 0 )) || return 0
    [[ "${_p_num}" =~ ^[0-9]+$ ]] || return 0

    # Credit finished stages only. Sitting at 0% through stage 1 of 9 is
    # accurate; the elapsed clock is what shows the run is still alive.
    local finished=$(( _p_num > 0 ? _p_num - 1 : 0 ))
    local pct=$(( finished * 100 / _p_total ))

    local width=20 filled i bar=''
    filled=$(( finished * width / _p_total ))
    for (( i = 0; i < width; i++ )); do
        if (( i < filled )); then bar+='▓'; else bar+='░'; fi
    done

    local elapsed=0
    if [[ "${_p_start}" =~ ^[0-9]+$ ]]; then
        elapsed=$(( $(date +%s) - _p_start ))
    fi

    # Built uncoloured so its width is its length: the truncation below has to
    # count columns, and escape sequences would make that arithmetic wrong.
    local head
    head="$(printf '[%s/%s] %s %3d%%  %s  ' \
        "${_p_num}" "${_p_total}" "${bar}" "${pct}" "$(fmt_duration "${elapsed}")")"

    # Truncate to the console width so the carriage return keeps landing on the
    # same row — a line that wraps leaves the previous one behind as debris.
    local cols room
    cols="$(_console_cols)"
    room=$(( cols - ${#head} - 1 ))
    (( room > 0 )) || room=0
    printf '\r\033[K%s%s' "${head}" "${_p_label:0:room}" >&3
}

progress_clear() {
    _progress_active || return 0
    printf '\r\033[K' >&3
}

progress_done() {
    progress_clear
    rm -f "${HASHIRU_PROGRESS}"
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
