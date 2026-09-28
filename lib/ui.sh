#!/usr/bin/env bash
# shellcheck shell=bash
# Hashiru UI library — the one banner, palette and set of prompt helpers shared
# by every screen of the install: the ISO's stage0, the first-boot tty1 screen,
# and install.sh.
#
# Standalone on purpose. The ISO has no checkout to source lib/common.sh from
# (build.sh copies just this file to /root/lib/ui.sh), so nothing here may
# depend on it. It also sets no shell options: callers run under
# `set -euo pipefail` and this has to behave there without imposing it anywhere
# else.
#
# Drawing goes to HASHIRU_UI_FD (default 2), never to stdout: stdout is where
# the prompt helpers return values, so `name="$(ui_input Name)"` works. install.sh
# points it at fd 3, the console descriptor that survives quiet mode — stderr
# there can be the log, and the log must never see an escape sequence.

# Sourced twice when common.sh pulls it in and a caller sourced it too.
[[ -n "${_HASHIRU_UI_LOADED:-}" ]] && return 0
_HASHIRU_UI_LOADED=1

# -----------------------------------------------------------------------------
# Palette — Tokyo Night, the desktop theme
# -----------------------------------------------------------------------------
#
# Source of truth is stow/kitty/.config/kitty/tokyonight.conf; the installer
# reuses it so the first thing a new machine shows already looks like the
# desktop it is about to become. Each role carries its hex value (24-bit
# terminals) and the ANSI-16 code for the matching slot (everything else — and
# on a Linux VT, ui_console_palette makes those slots the hex values anyway).

_UI_HEX_ACCENT='7aa2f7'    _UI_ANSI_ACCENT=34
_UI_HEX_SUCCESS='73daca'   _UI_ANSI_SUCCESS=32
_UI_HEX_WARN='e0af68'      _UI_ANSI_WARN=33
_UI_HEX_ERROR='f7768e'     _UI_ANSI_ERROR=31
_UI_HEX_MUTED='414868'     _UI_ANSI_MUTED=90
_UI_HEX_TEXT='c0caf5'      _UI_ANSI_TEXT=97
_UI_HEX_HIGHLIGHT='bb9af7' _UI_ANSI_HIGHLIGHT=35

# The console slot each role lives in, for gum on non-24-bit terminals: gum
# takes a slot number, and on a VT that slot has been reprogrammed to the hex.
_UI_SLOT_ACCENT=4 _UI_SLOT_SUCCESS=2 _UI_SLOT_WARN=3 _UI_SLOT_ERROR=1
_UI_SLOT_MUTED=8 _UI_SLOT_TEXT=15 _UI_SLOT_HIGHLIGHT=5

# The 16 console slots, 0-15. Differs from kitty's color0-15 in two places,
# because a VT has no separate background/foreground: slot 0 *is* the
# background and slot 7 the default text, so they take kitty's `background`
# and `foreground` rather than its color0 and color7.
_UI_VT_PALETTE=(
    1a1b26 f7768e 73daca e0af68 7aa2f7 bb9af7 7dcfff a9b1d6
    414868 f7768e 73daca e0af68 7aa2f7 bb9af7 7dcfff c0caf5
)

# Escape strings for the current UI fd, filled in by _ui_init. Empty strings
# mean "no colour", which is what every helper degrades to. Some are only read
# by callers (the progress line, stage0), hence SC2034.
# shellcheck disable=SC2034
UI_ACCENT='' UI_SUCCESS='' UI_WARN='' UI_ERROR='' UI_MUTED='' UI_TEXT=''
UI_HIGHLIGHT='' UI_BOLD='' UI_RESET=''
# none | vt | truecolor | ansi — exposed for callers that care (the progress line).
UI_DEPTH='none'
# The same roles as gum colour arguments ("#7aa2f7" or a slot number).
_UI_GC_ACCENT='' _UI_GC_SUCCESS='' _UI_GC_WARN='' _UI_GC_ERROR=''
_UI_GC_MUTED='' _UI_GC_TEXT='' _UI_GC_HIGHLIGHT=''

# The fd the escapes above were computed for. Colour depth is a property of
# where output lands, and install.sh re-points HASHIRU_UI_FD after sourcing
# this, so the answer is cached per fd rather than once at source time.
_UI_INIT_FD=''

# -----------------------------------------------------------------------------
# Output target and colour depth
# -----------------------------------------------------------------------------

# The fd to draw on, into _UI_FD, falling back to stderr when the configured one
# isn't open — a helper called from a context that never opened fd 3 should
# still show up somewhere rather than die with "Bad file descriptor". Sets a
# variable instead of printing so callers don't pay a subshell per line.
_UI_FD=2
_ui_fd() {
    _UI_FD="${HASHIRU_UI_FD:-2}"
    if [[ ! "${_UI_FD}" =~ ^[0-9]+$ ]] || ! { true >&"${_UI_FD}"; } 2>/dev/null; then
        _UI_FD=2
    fi
}

# A Linux virtual console, judged by where the fd actually points rather than by
# TERM: the first-boot unit runs with no TERM at all, and that is exactly the
# screen this matters for.
_ui_fd_is_vt() {
    local target
    target="$(readlink "/proc/self/fd/$1" 2>/dev/null)" || return 1
    [[ "${target}" =~ ^/dev/tty[0-9]+$ ]]
}

# Work out colour depth for the current UI fd and fill in UI_*. Cheap to call
# from every helper: once the fd is known it is a comparison and no forks.
_ui_init() {
    _ui_fd
    [[ "${_UI_FD}" == "${_UI_INIT_FD}" ]] && return 0
    _UI_INIT_FD="${_UI_FD}"
    local fd="${_UI_FD}"

    # A VT is checked before TERM on purpose: where the fd points is the
    # ground truth, and the first-boot unit's TERM can be unset or "dumb"
    # while it draws on a console that renders colour perfectly well.
    if [[ -n "${NO_COLOR:-}" || ! -t "${fd}" ]]; then
        UI_DEPTH='none'
    elif _ui_fd_is_vt "${fd}"; then
        UI_DEPTH='vt'
    elif [[ "${TERM:-dumb}" == "dumb" ]]; then
        UI_DEPTH='none'
    elif [[ "${COLORTERM:-}" == "truecolor" || "${COLORTERM:-}" == "24bit" ]]; then
        UI_DEPTH='truecolor'
    else
        UI_DEPTH='ansi'
    fi

    if [[ "${UI_DEPTH}" == 'none' ]]; then
        # shellcheck disable=SC2034  # read by callers, see above
        UI_ACCENT='' UI_SUCCESS='' UI_WARN='' UI_ERROR='' UI_MUTED='' \
            UI_TEXT='' UI_HIGHLIGHT='' UI_BOLD='' UI_RESET=''
        _UI_GC_ACCENT='' _UI_GC_SUCCESS='' _UI_GC_WARN='' _UI_GC_ERROR='' \
            _UI_GC_MUTED='' _UI_GC_TEXT='' _UI_GC_HIGHLIGHT=''
        return 0
    fi

    UI_BOLD=$'\033[1m'
    UI_RESET=$'\033[0m'
    local role hex ansi slot
    for role in ACCENT SUCCESS WARN ERROR MUTED TEXT HIGHLIGHT; do
        hex="_UI_HEX_${role}"
        ansi="_UI_ANSI_${role}"
        slot="_UI_SLOT_${role}"
        hex="${!hex}"
        if [[ "${UI_DEPTH}" == 'truecolor' ]]; then
            printf -v "UI_${role}" '\033[38;2;%d;%d;%dm' \
                "0x${hex:0:2}" "0x${hex:2:2}" "0x${hex:4:2}"
            printf -v "_UI_GC_${role}" '#%s' "${hex}"
        else
            printf -v "UI_${role}" '\033[%sm' "${!ansi}"
            printf -v "_UI_GC_${role}" '%s' "${!slot}"
        fi
    done
}

# Print to the UI fd, verbatim. Every helper's drawing goes through here. %s,
# not %b: messages carry user input and paths, and a backslash in one must not
# turn into an escape.
_ui_out() {
    printf '%s' "$*" >&"${_UI_FD}"
}

# -----------------------------------------------------------------------------
# Static output
# -----------------------------------------------------------------------------

# Load Tokyo Night into the Linux console's 16 colour slots, so the ANSI-16
# codes above render as the real theme on the ISO and on first-boot tty1. A
# no-op anywhere else: the escape means nothing to a terminal emulator, and some
# print it.
ui_console_palette() {
    _ui_init
    [[ "${UI_DEPTH}" == 'vt' ]] || return 0
    local i part seq=''
    for i in "${!_UI_VT_PALETTE[@]}"; do
        printf -v part '\033]P%X%s' "${i}" "${_UI_VT_PALETTE[${i}]}"
        seq+="${part}"
    done
    _ui_out "${seq}"
    return 0
}

readonly _UI_RULE='──────────────────────────────────────────────────'
readonly _UI_WIDTH=50

# Centre <text> in the banner's width. ${#} counts characters, not bytes, in a
# UTF-8 locale, which the logo's block glyphs need.
_ui_centre() {
    local text="$1" pad
    pad=$(( (_UI_WIDTH - ${#text}) / 2 ))
    (( pad > 0 )) || pad=0
    printf '%*s%s' "${pad}" '' "${text}"
}

# The one Hashiru banner. <subtitle> says which screen this is ("Live
# installer", "First boot", "Arch + Hyprland bootstrap").
ui_banner() {
    _ui_init
    local subtitle="${1:-Arch + Hyprland bootstrap}"
    local logo=(
        '▓░ ░ ▓▒▀▓ ▓█▀▀ ▓░ ░ ▓░ ▓█▀▓ ▓█ ░'
        '▒▓▀▒ ▒░▄▒ ▀▀▒▓ ▒▓▀▒ ▒▒ ▒▓▄▀ ▒▓ ▒'
        '░  ▓ ░  ░ ▄▄░▒ ░  ▓ ░▓ ░▒ ▒ ░▒▄▓'
    )
    local nl=$'\n'
    local line out="${UI_MUTED}${_UI_RULE}${UI_RESET}${nl}"
    for line in "${logo[@]}"; do
        out+="${UI_ACCENT}$(_ui_centre "${line}")${UI_RESET}${nl}"
    done
    out+="${UI_TEXT}${UI_BOLD}$(_ui_centre "${subtitle}")${UI_RESET}${nl}"
    out+="${UI_MUTED}$(_ui_centre 'Created by: Will Hleucka')${UI_RESET}${nl}"
    out+="${UI_MUTED}${_UI_RULE}${UI_RESET}${nl}"
    _ui_out "${out}"
}

# A muted horizontal rule, the banner's width. Frames a summary.
ui_rule() {
    _ui_init
    _ui_out "${UI_MUTED}${_UI_RULE}${UI_RESET}"$'\n'
}

# `▌ Step n/total · title` — marks where one group of questions starts.
ui_section() {
    _ui_init
    _ui_out $'\n'"${UI_ACCENT}▌${UI_RESET} ${UI_MUTED}Step $1/$2 ·${UI_RESET} ${UI_TEXT}${UI_BOLD}$3${UI_RESET}"$'\n\n'
}

# One-liners. The glyphs are the ones stage0 and firstboot already used, so
# they still read correctly with colour off.
ui_note()    { _ui_init; _ui_out "${UI_ACCENT}==>${UI_RESET} $*"$'\n'; }
ui_success() { _ui_init; _ui_out "${UI_SUCCESS}==>${UI_RESET} $*"$'\n'; }
ui_warn()    { _ui_init; _ui_out "${UI_WARN}!!${UI_RESET} $*"$'\n'; }
ui_error()   { _ui_init; _ui_out "${UI_ERROR}!!${UI_RESET} $*"$'\n'; }

# -----------------------------------------------------------------------------
# Prompts
# -----------------------------------------------------------------------------
#
# Every helper returns its value on stdout and draws on the UI fd, so
# `x="$(ui_input Name)"` works, and keys come from /dev/tty rather than stdin —
# ui_filter's list arrives on stdin, and a caller may have stdin redirected.
#
# Each has a gum path and a plain `read` path that return the same values for
# the same answers. Validation stays with the caller: helpers collect.
#
# Ctrl-C aborts rather than answering. The plain path gets that for free (the
# SIGINT kills the script); gum catches it in raw mode and exits 130, which is
# turned back into an abort here.

# Can gum run here? Installed, not switched off, a real terminal to draw on and
# read keys from, and a terminal that reports a size — gum 2.0.2 panics with
# "makeslice: len out of range" on a 0x0 pty, which is what a serial console or
# a size-less pty looks like.
ui_gum() {
    [[ "${HASHIRU_NO_GUM:-0}" != "1" ]] || return 1
    command -v gum >/dev/null 2>&1 || return 1
    [[ -n "${TERM:-}" && "${TERM}" != "dumb" ]] || return 1
    _ui_init
    [[ -t "${_UI_FD}" ]] || return 1
    local size
    size="$(stty size < /dev/tty 2>/dev/null)" || return 1
    [[ "${size}" =~ ^[1-9][0-9]*\ [1-9][0-9]*$ ]]
}

# Where the plain path reads answers from: the terminal when there is one, else
# stdin (so a scripted `printf 'x\n' | ...` test still works).
_ui_in() {
    if { : < /dev/tty; } 2>/dev/null; then
        printf '/dev/tty'
    else
        printf '/dev/stdin'
    fi
}

# gum clears its widget on exit, so without this an answered question leaves no
# trace on screen. Echo it back the way the plain path leaves it: prompt, value.
_ui_answered() {
    _ui_out "${UI_MUTED}$1:${UI_RESET} ${UI_TEXT}$2${UI_RESET}"$'\n'
}

# gum exits 130 on Ctrl-C and 1 on "no"/Esc. Only 130 is an abort.
_ui_gum_status() {
    local rc="$1"
    (( rc == 130 )) && exit 130
    return "${rc}"
}

# ui_input <prompt> [default] — one line of text; empty means the default.
ui_input() {
    _ui_init
    local prompt="$1" default="${2:-}" answer rc=0
    if ui_gum; then
        answer="$(gum input --prompt "${prompt}: " --value "${default}" --placeholder '' \
            --prompt.foreground "${_UI_GC_ACCENT}" --cursor.foreground "${_UI_GC_HIGHLIGHT}" \
            < /dev/tty 2>&"${_UI_FD}")" || rc=$?
        _ui_gum_status "${rc}" || return
        _ui_answered "${prompt}" "${answer:-${default}}"
    else
        if [[ -n "${default}" ]]; then
            _ui_out "${UI_ACCENT}${prompt}${UI_RESET} ${UI_MUTED}[${default}]${UI_RESET}: "
        else
            _ui_out "${UI_ACCENT}${prompt}${UI_RESET}: "
        fi
        IFS= read -r answer < "$(_ui_in)" || return 1
    fi
    printf '%s' "${answer:-${default}}"
}

# ui_password <prompt> — hidden, asked twice. Loops on empty or mismatched
# rather than failing: every caller would otherwise grow the same retry loop.
# The secret only ever travels through stdout, never argv.
ui_password() {
    _ui_init
    local prompt="$1" first second rc
    while true; do
        rc=0
        if ui_gum; then
            first="$(gum input --password --prompt "${prompt}: " --placeholder '' \
                --prompt.foreground "${_UI_GC_ACCENT}" < /dev/tty 2>&"${_UI_FD}")" || rc=$?
            _ui_gum_status "${rc}" || return
            second="$(gum input --password --prompt "Confirm: " --placeholder '' \
                --prompt.foreground "${_UI_GC_ACCENT}" < /dev/tty 2>&"${_UI_FD}")" || rc=$?
            _ui_gum_status "${rc}" || return
        else
            local src
            src="$(_ui_in)"
            _ui_out "${UI_ACCENT}${prompt}${UI_RESET}: "
            IFS= read -rs first < "${src}" || return 1
            _ui_out $'\n'"${UI_ACCENT}Confirm${UI_RESET}: "
            IFS= read -rs second < "${src}" || return 1
            _ui_out $'\n'
        fi
        if [[ -n "${first}" && "${first}" == "${second}" ]]; then
            break
        fi
        ui_error "Empty or mismatched — try again."
    done
    ui_gum && _ui_answered "${prompt}" '••••••••'
    printf '%s' "${first}"
}

# ui_confirm <prompt> [yes|no] — status 0 for yes. Defaults to no.
#
# --no-confirm (HASHIRU_ASSUME_YES) means "answer every prompt yes", so it
# answers yes. An unattended run has nobody to ask and takes the default.
ui_confirm() {
    _ui_init
    local prompt="$1" default="${2:-no}" answer rc=0
    [[ "${HASHIRU_ASSUME_YES:-0}" == "1" ]] && return 0
    if [[ "${HASHIRU_UNATTENDED:-0}" == "1" ]]; then
        [[ "${default}" == "yes" ]] && return 0
        return 1
    fi
    if ui_gum; then
        local def=false
        [[ "${default}" == "yes" ]] && def=true
        gum confirm "${prompt}" --default="${def}" \
            --prompt.foreground "${_UI_GC_TEXT}" \
            --selected.background "${_UI_GC_ACCENT}" \
            < /dev/tty 2>&"${_UI_FD}" || rc=$?
        _ui_gum_status "${rc}" || { _ui_answered "${prompt}" 'No'; return 1; }
        _ui_answered "${prompt}" 'Yes'
        return 0
    fi
    local hint='[y/N]'
    [[ "${default}" == "yes" ]] && hint='[Y/n]'
    _ui_out "${UI_ACCENT}${prompt}${UI_RESET} ${UI_MUTED}${hint}${UI_RESET} "
    IFS= read -r answer < "$(_ui_in)" || return 1
    [[ -n "${answer}" ]] || answer="${default}"
    [[ "${answer,,}" == y* ]] && return 0
    return 1
}

# ui_choose <prompt> <item>... — pick one; echoes the item.
ui_choose() {
    _ui_init
    local prompt="$1"
    shift
    (( $# > 0 )) || return 1
    local answer rc=0
    if ui_gum; then
        answer="$(gum choose --header "${prompt}" \
            --header.foreground "${_UI_GC_ACCENT}" --cursor.foreground "${_UI_GC_HIGHLIGHT}" \
            --selected.foreground "${_UI_GC_HIGHLIGHT}" \
            -- "$@" < /dev/tty 2>&"${_UI_FD}")" || rc=$?
        _ui_gum_status "${rc}" || return
        _ui_answered "${prompt}" "${answer}"
        printf '%s' "${answer}"
        return 0
    fi
    local i src
    src="$(_ui_in)"
    _ui_out "${UI_ACCENT}${prompt}${UI_RESET}"$'\n'
    for (( i = 1; i <= $#; i++ )); do
        _ui_out "  ${UI_MUTED}${i})${UI_RESET} ${!i}"$'\n'
    done
    while true; do
        _ui_out "${UI_ACCENT}Number${UI_RESET} ${UI_MUTED}[1-$#]${UI_RESET}: "
        IFS= read -r answer < "${src}" || return 1
        if [[ "${answer}" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= $# )); then
            printf '%s' "${!answer}"
            return 0
        fi
        ui_error "Pick a number from 1 to $#."
    done
}

# ui_filter <prompt> [default] — pick one line of stdin; echoes it.
#
# gum gets a fuzzy finder with the default moved to the top, so Enter takes it.
# The plain path takes a typed value, which must match a line exactly; a miss
# lists up to ten lines containing what was typed, and asks again.
ui_filter() {
    _ui_init
    local prompt="$1" default="${2:-}" answer rc=0 line
    local -a items=() ordered=()
    mapfile -t items
    (( ${#items[@]} > 0 )) || return 1

    if ui_gum; then
        [[ -n "${default}" ]] && ordered+=("${default}")
        for line in "${items[@]}"; do
            [[ "${line}" == "${default}" ]] || ordered+=("${line}")
        done
        answer="$(printf '%s\n' "${ordered[@]}" | gum filter --header "${prompt}" \
            --placeholder 'Type to filter…' --height 15 \
            --header.foreground "${_UI_GC_ACCENT}" --indicator.foreground "${_UI_GC_HIGHLIGHT}" \
            --match.foreground "${_UI_GC_HIGHLIGHT}" --prompt.foreground "${_UI_GC_ACCENT}" \
            2>&"${_UI_FD}")" || rc=$?
        _ui_gum_status "${rc}" || return
        _ui_answered "${prompt}" "${answer}"
        printf '%s' "${answer}"
        return 0
    fi

    local src matches shown
    src="$(_ui_in)"
    while true; do
        if [[ -n "${default}" ]]; then
            _ui_out "${UI_ACCENT}${prompt}${UI_RESET} ${UI_MUTED}[${default}]${UI_RESET}: "
        else
            _ui_out "${UI_ACCENT}${prompt}${UI_RESET}: "
        fi
        IFS= read -r answer < "${src}" || return 1
        answer="${answer:-${default}}"
        for line in "${items[@]}"; do
            if [[ "${line}" == "${answer}" ]]; then
                printf '%s' "${answer}"
                return 0
            fi
        done
        ui_error "'${answer}' is not one of the choices."
        matches=0 shown=''
        if [[ -n "${answer}" ]]; then
            for line in "${items[@]}"; do
                if [[ "${line,,}" == *"${answer,,}"* ]]; then
                    shown+="  ${line}"$'\n'
                    (( ++matches >= 10 )) && break
                fi
            done
        fi
        (( matches > 0 )) && _ui_out "${UI_MUTED}Did you mean:${UI_RESET}"$'\n'"${shown}"
    done
}
