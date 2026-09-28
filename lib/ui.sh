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

    if [[ -n "${NO_COLOR:-}" || ! -t "${fd}" || "${TERM:-}" == "dumb" ]]; then
        UI_DEPTH='none'
    elif _ui_fd_is_vt "${fd}"; then
        UI_DEPTH='vt'
    elif [[ "${COLORTERM:-}" == "truecolor" || "${COLORTERM:-}" == "24bit" ]]; then
        UI_DEPTH='truecolor'
    else
        UI_DEPTH='ansi'
    fi

    if [[ "${UI_DEPTH}" == 'none' ]]; then
        # shellcheck disable=SC2034  # read by callers, see above
        UI_ACCENT='' UI_SUCCESS='' UI_WARN='' UI_ERROR='' UI_MUTED='' \
            UI_TEXT='' UI_HIGHLIGHT='' UI_BOLD='' UI_RESET=''
        return 0
    fi

    UI_BOLD=$'\033[1m'
    UI_RESET=$'\033[0m'
    local role hex ansi
    for role in ACCENT SUCCESS WARN ERROR MUTED TEXT HIGHLIGHT; do
        hex="_UI_HEX_${role}"
        ansi="_UI_ANSI_${role}"
        hex="${!hex}"
        if [[ "${UI_DEPTH}" == 'truecolor' ]]; then
            printf -v "UI_${role}" '\033[38;2;%d;%d;%dm' \
                "0x${hex:0:2}" "0x${hex:2:2}" "0x${hex:4:2}"
        else
            printf -v "UI_${role}" '\033[%sm' "${!ansi}"
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
