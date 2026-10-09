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
# The wordmark, shared by the banner and the splash. Every glyph is in the
# Linux console font (CP437 block elements), so it renders on a bare VT.
readonly _UI_LOGO=(
    '▓░ ░ ▓▒▀▓ ▓█▀▀ ▓░ ░ ▓░ ▓█▀▓ ▓█ ░'
    '▒▓▀▒ ▒░▄▒ ▀▀▒▓ ▒▓▀▒ ▒▒ ▒▓▄▀ ▒▓ ▒'
    '░  ▓ ░  ░ ▄▄░▒ ░  ▓ ░▓ ░▒ ▒ ░▒▄▓'
)

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
    local nl=$'\n'
    local line out="${UI_MUTED}${_UI_RULE}${UI_RESET}${nl}"
    for line in "${_UI_LOGO[@]}"; do
        out+="${UI_ACCENT}$(_ui_centre "${line}")${UI_RESET}${nl}"
    done
    out+="${UI_TEXT}${UI_BOLD}$(_ui_centre "${subtitle}")${UI_RESET}${nl}"
    out+="${UI_MUTED}$(_ui_centre 'Created by: Will Hleucka')${UI_RESET}${nl}"
    out+="${UI_MUTED}${_UI_RULE}${UI_RESET}${nl}"
    _ui_out "${out}"
}

# -----------------------------------------------------------------------------
# Splash
# -----------------------------------------------------------------------------
#
# ui_splash <subtitle> [hint] — the first screen of the ISO installer. The logo,
# subtitle and hint sit in the middle of the screen while a band of light
# sweeps across the logo; Enter moves on.
#
# The animation is a background loop that only ever writes, and the foreground
# only ever reads, so the two cannot fight over a keypress. Lessons from
# Omarchy's first boot, which does the same with ttfx:
#   - repaint by absolute cursor position, never DEC save/restore: a late
#     console resize (the KMS handoff) moves or resets a saved cursor, and the
#     logo ends up smeared across the screen;
#   - re-measure the console and repaint everything when it changes size;
#   - stop the animator by PID, and guard kill/wait so a caller's `set -e`
#     never trips on the signal it just sent;
#   - indexed colours only (slots 4 -> 6 -> 2): the framebuffer console turns
#     24-bit colour to mud, and on a VT ui_console_palette has made those slots
#     Tokyo Night anyway.

readonly _UI_SPLASH_FPS_DELAY=0.05   # ~20 frames a second
readonly _UI_SPLASH_BAND=4           # columns of light in the sweep
readonly _UI_SPLASH_REST=13          # frames the logo rests between sweeps
# The logo's resting colour, as a console slot rather than UI_ACCENT: on a
# 24-bit terminal UI_ACCENT is the exact hex, and the band beside it would be a
# slot, so a terminal with its own theme would show two different blues.
readonly _UI_SPLASH_BASE=$'\033[34m'

# Animate only when there is something to animate on: colour, a real terminal
# that reports a size wide enough for the logo, and nobody asking for less
# motion (HASHIRU_NO_ANIM=1, environment only, like HASHIRU_NO_GUM).
_ui_splash_animated() {
    [[ "${UI_DEPTH}" != 'none' && "${HASHIRU_NO_ANIM:-0}" != "1" ]] || return 1
    local size rows cols
    size="$(stty size 2>/dev/null < /dev/tty)" || return 1
    read -r rows cols <<< "${size}"
    [[ "${rows}" =~ ^[0-9]+$ && "${cols}" =~ ^[0-9]+$ ]] || return 1
    (( cols >= ${#_UI_LOGO[0]} + 4 && rows >= 10 ))
}

# Where everything goes for the current console size, into _UI_SP_* globals.
# The block is logo (3) + gap + subtitle + byline + gap + hint = 8 rows.
_ui_splash_geometry() {
    local size
    size="$(stty size 2>/dev/null < /dev/tty)" || size='24 80'
    read -r _UI_SP_ROWS _UI_SP_COLS <<< "${size}"
    _UI_SP_TOP=$(( (_UI_SP_ROWS - 8) / 2 + 1 ))
    (( _UI_SP_TOP >= 1 )) || _UI_SP_TOP=1
    _UI_SP_LEFT=$(( (_UI_SP_COLS - ${#_UI_LOGO[0]}) / 2 + 1 ))
    (( _UI_SP_LEFT >= 1 )) || _UI_SP_LEFT=1
}

# Column where <text> starts when centred on the current console.
_ui_splash_col() {
    local col=$(( (_UI_SP_COLS - ${#1}) / 2 + 1 ))
    (( col >= 1 )) || col=1
    printf '%s' "${col}"
}

# Paint the whole splash from scratch: clear, then every line at an absolute
# position. Called once up front and again after any resize.
_ui_splash_full() {
    local subtitle="$1" hint="$2" byline='Created by: Will Hleucka' i out
    _ui_splash_geometry
    out=$'\033[?25l\033[H\033[2J'
    for i in 0 1 2; do
        out+=$'\033['"$(( _UI_SP_TOP + i ));${_UI_SP_LEFT}H${_UI_SPLASH_BASE}${_UI_LOGO[${i}]}${UI_RESET}"
    done
    out+=$'\033['"$(( _UI_SP_TOP + 4 ));$(_ui_splash_col "${subtitle}")H${UI_TEXT}${UI_BOLD}${subtitle}${UI_RESET}"
    out+=$'\033['"$(( _UI_SP_TOP + 5 ));$(_ui_splash_col "${byline}")H${UI_MUTED}${byline}${UI_RESET}"
    out+=$'\033['"$(( _UI_SP_TOP + 7 ));$(_ui_splash_col "${hint}")H${UI_MUTED}${hint}${UI_RESET}"
    _ui_out "${out}"
}

# One frame of the sweep: repaint the three logo rows with the band's leading
# edge at column <pos> (0-based; the band trails behind it). Positions past the
# end of the logo leave it plain accent, which is also the resting frame.
_ui_splash_frame() {
    local pos="$1" i line width head band tail start c out=''
    local -a shades=($'\033[36m' $'\033[36m' $'\033[32m' $'\033[1;32m')
    for i in 0 1 2; do
        line="${_UI_LOGO[${i}]}"
        width=${#line}
        start=$(( pos - _UI_SPLASH_BAND + 1 ))
        out+=$'\033['"$(( _UI_SP_TOP + i ));${_UI_SP_LEFT}H"
        if (( pos < 0 || start >= width )); then
            out+="${_UI_SPLASH_BASE}${line}${UI_RESET}"
            continue
        fi
        head="${line:0:$(( start > 0 ? start : 0 ))}"
        band=''
        for (( c = start; c <= pos; c++ )); do
            (( c >= 0 && c < width )) || continue
            band+="${shades[$(( c - start ))]}${line:c:1}"
        done
        tail="${line:$(( pos + 1 ))}"
        out+="${_UI_SPLASH_BASE}${head}${band}${UI_RESET}${_UI_SPLASH_BASE}${tail}${UI_RESET}"
    done
    _ui_out "${out}"
}

# The animator. Runs in the background, reads nothing, and exits on its own if
# the shell that started it goes away (a SIGKILL skips every trap).
_ui_splash_animate() {
    local subtitle="$1" hint="$2" parent="$3" frame=0 pos size last_size
    local width=${#_UI_LOGO[0]}
    local period=$(( width + _UI_SPLASH_BAND + _UI_SPLASH_REST ))
    trap 'exit 0' TERM
    last_size="$(stty size 2>/dev/null < /dev/tty)"
    while kill -0 "${parent}" 2>/dev/null; do
        # Re-measure every few frames: a stty fork per frame is wasted work,
        # and a quarter of a second is well inside how long a resize takes.
        if (( frame % 5 == 0 )); then
            size="$(stty size 2>/dev/null < /dev/tty)"
            if [[ "${size}" != "${last_size}" ]]; then
                last_size="${size}"
                _ui_splash_full "${subtitle}" "${hint}"
            fi
        fi
        pos=$(( frame % period ))
        # Draw the sweep, then one plain frame to settle; rest frames draw
        # nothing at all.
        if (( pos <= width + _UI_SPLASH_BAND - 1 )); then
            _ui_splash_frame "${pos}"
        fi
        frame=$(( frame + 1 ))
        sleep "${_UI_SPLASH_FPS_DELAY}"
    done
}

_UI_SPLASH_PID=''

# Stop the animator and give the screen back: kill, reap, clear, cursor on.
# Safe to call twice and when nothing is running.
_ui_splash_stop() {
    if [[ -n "${_UI_SPLASH_PID}" ]]; then
        kill "${_UI_SPLASH_PID}" 2>/dev/null || true
        wait "${_UI_SPLASH_PID}" 2>/dev/null || true
        _UI_SPLASH_PID=''
    fi
    _ui_out $'\033[0m\033[H\033[2J\033[?25h'
}

ui_splash() {
    _ui_init
    local subtitle="${1:-Arch + Hyprland bootstrap}"
    local hint="${2:-Press Enter to begin}"
    local src _
    src="$(_ui_in)"
    # Character counts here assume a UTF-8 locale: the logo is multibyte, and
    # in the C locale ${#line} would count bytes and misplace everything.
    local LC_ALL=C.UTF-8

    if ! _ui_splash_animated; then
        ui_banner "${subtitle}"
        _ui_out $'\n'"${UI_MUTED}$(_ui_centre "${hint}")${UI_RESET}"$'\n'
        IFS= read -rs _ < "${src}" || true
        return 0
    fi

    # Ctrl-C must not leave a hidden cursor or an orphan painting the screen.
    # The caller's traps are put back afterwards.
    local old_int old_term
    old_int="$(trap -p INT)"
    old_term="$(trap -p TERM)"
    trap '_ui_splash_stop; exit 130' INT
    trap '_ui_splash_stop; exit 143' TERM

    _ui_splash_full "${subtitle}" "${hint}"
    _ui_splash_animate "${subtitle}" "${hint}" "$$" < /dev/null &
    _UI_SPLASH_PID=$!

    IFS= read -rs _ < "${src}" || true
    _ui_splash_stop

    eval "${old_int:-trap - INT}"
    eval "${old_term:-trap - TERM}"
    return 0
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

# Columns available on the terminal, for layout decisions. 80 when there is no
# terminal to ask, which is also the width a pipe or a log is read at.
_ui_cols() {
    local size cols=80
    if size="$(stty size 2>/dev/null < /dev/tty)"; then
        cols="${size##* }"
        [[ "${cols}" =~ ^[0-9]+$ ]] && (( cols > 0 )) || cols=80
    fi
    printf '%s' "${cols}"
}

# ui_rail <current> <name>... — where the installer is, as tabs along the top:
#   • Network ─ • Keyboard ─ ▌Account ─ ○ Machine ─ ○ Disk ─ ○ Review
# Done steps in green, the current one in bold accent, the rest muted.
# <current> is 1-based. Below 80 columns, or if the rail wouldn't fit, it falls
# back to ui_section's single line, which says the same thing in less room.
#
# On a terminal it starts a new page: clear, then the rail on the first row, so
# each step reads as its own screen instead of stacking under the last one's
# answers (the review card is where those all come back together). Anywhere
# else — a pipe, a log — it only prints, and never wipes anything.
ui_rail() {
    _ui_init
    local LC_ALL=C.UTF-8
    local current="$1"
    shift
    local total=$# i name plain='' out='' sep=' ─ ' cols
    for (( i = 1; i <= total; i++ )); do
        name="${!i}"
        (( i > 1 )) && plain+="${sep}" && out+="${UI_MUTED}${sep}${UI_RESET}"
        if (( i < current )); then
            plain+="• ${name}"
            out+="${UI_SUCCESS}• ${name}${UI_RESET}"
        elif (( i == current )); then
            plain+="▌${name}"
            out+="${UI_ACCENT}${UI_BOLD}▌${name}${UI_RESET}"
        else
            plain+="○ ${name}"
            out+="${UI_MUTED}○ ${name}${UI_RESET}"
        fi
    done
    [[ -t "${_UI_FD}" ]] && _ui_out $'\033[H\033[2J'
    cols="$(_ui_cols)"
    if (( cols < 80 || ${#plain} + 2 > cols )); then
        local cur="${!current:-}"
        ui_section "${current}" "${total}" "${cur}"
        return 0
    fi
    _ui_out $'\n'" ${out}"$'\n\n'
}

# ui_card <title> <label> <value> [<label> <value>]... — a framed block of
# answers, labels aligned, for the review screen:
#   ┌─ Review ─────────────────────────┐
#   │ Username   will                  │
#   │ Disk       /dev/nvme0n1  512G    │
#   └──────────────────────────────────┘
# Values print verbatim. One too long for the terminal is cut short with "..."
# (ASCII on purpose: "…" is not in the Linux console font). Box glyphs are the
# square CP437 ones; the rounded corners are not in that font either.
ui_card() {
    _ui_init
    local LC_ALL=C.UTF-8
    local title="$1"
    shift
    local -a labels=() values=()
    while (( $# >= 2 )); do
        labels+=("$1")
        values+=("$2")
        shift 2
    done

    local i lw=0 vw=0 cols inner
    for i in "${!labels[@]}"; do
        (( ${#labels[${i}]} > lw )) && lw=${#labels[${i}]}
        (( ${#values[${i}]} > vw )) && vw=${#values[${i}]}
    done
    # Inner width: " label   value " — and at least wide enough for the title.
    inner=$(( 1 + lw + 3 + vw + 1 ))
    (( inner >= ${#title} + 4 )) || inner=$(( ${#title} + 4 ))
    # At most 72 wide, and never into the terminal's last column: some
    # terminals wrap as soon as that column is written, doubling every line.
    local max
    cols="$(_ui_cols)"
    max=$(( cols - 1 < 72 ? cols - 1 : 72 ))
    if (( inner + 2 > max )); then
        inner=$(( max - 2 ))
        vw=$(( inner - lw - 5 ))
        (( vw >= 4 )) || vw=4
    fi

    local rule='' nl=$'\n' out value pad lpad
    printf -v rule '%*s' "$(( inner - ${#title} - 3 ))" ''
    rule="${rule// /─}"
    out="${UI_MUTED}┌─${UI_RESET} ${UI_TEXT}${UI_BOLD}${title}${UI_RESET} ${UI_MUTED}${rule}┐${UI_RESET}${nl}"
    for i in "${!labels[@]}"; do
        value="${values[${i}]}"
        if (( ${#value} > vw )); then
            value="${value:0:$(( vw - 3 ))}..."
        fi
        # Padding by character count, not printf's %-*s: printf pads bytes, and
        # a multibyte label or value would push the right border out of line.
        printf -v pad '%*s' "$(( inner - 1 - lw - 3 - ${#value} - 1 ))" ''
        printf -v lpad '%*s' "$(( lw - ${#labels[${i}]} ))" ''
        out+="${UI_MUTED}│${UI_RESET} ${UI_MUTED}${labels[${i}]}${lpad}${UI_RESET}   "
        out+="${UI_TEXT}${value}${UI_RESET}${pad} ${UI_MUTED}│${UI_RESET}${nl}"
    done
    printf -v rule '%*s' "${inner}" ''
    rule="${rule// /─}"
    out+="${UI_MUTED}└${rule}┘${UI_RESET}${nl}"
    _ui_out "${out}"
}

# One-liners. The glyphs are the ones stage0 and firstboot already used, so
# they still read correctly with colour off.
ui_note()    { _ui_init; _ui_out "${UI_ACCENT}==>${UI_RESET} $*"$'\n'; }
ui_success() { _ui_init; _ui_out "${UI_SUCCESS}==>${UI_RESET} $*"$'\n'; }
ui_warn()    { _ui_init; _ui_out "${UI_WARN}!!${UI_RESET} $*"$'\n'; }
ui_error()   { _ui_init; _ui_out "${UI_ERROR}!!${UI_RESET} $*"$'\n'; }

# _ui_safe_line <line> <max> — one log line made safe to draw, cut to at most
# <max> characters with "...". A line rewritten with CR (pacman's progress bars)
# keeps only what a terminal would have ended up showing: the text after the
# last CR. Tabs become spaces, and every other control character — ESC above
# all, but also backspace, and the C1 set, which a VT can take for CSI — shows
# as caret notation, the way `cat -v` would. A log can carry a program's colour
# codes, and the failure screen must show them as text rather than obey them.
# Result in _UI_SAFE, to save a subshell per line.
_UI_SAFE=''
_ui_safe_line() {
    local LC_ALL=C.UTF-8
    local line="${1%$'\r'}" max="$2" c i out=''
    local -i n
    line="${line##*$'\r'}"
    line="${line//$'\t'/    }"
    # Escaping only ever lengthens, so nothing past max + 1 can survive the cut.
    line="${line:0:$(( max + 1 ))}"
    if [[ "${line}" == *[[:cntrl:]]* ]]; then
        for (( i = 0; i < ${#line}; i++ )); do
            c="${line:i:1}"
            if [[ "${c}" != [[:cntrl:]] ]]; then
                out+="${c}"
                continue
            fi
            printf -v n '%d' "'${c}"
            if (( n == 127 )); then
                out+='^?'
            elif (( n < 32 )); then
                printf -v c '\\x%02x' $(( n + 64 ))
                printf -v c '^%b' "${c}"
                out+="${c}"
            else
                printf -v c '\\x%02x' $(( n - 64 ))
                printf -v c 'M-^%b' "${c}"
                out+="${c}"
            fi
        done
        line="${out}"
    fi
    (( ${#line} > max )) && line="${line:0:$(( max - 3 ))}..."
    _UI_SAFE="${line}"
}

# ui_failure <title> <log> [lines] [note...] — the one failure block, shared by
# stage0, first boot and install.sh so every failure reads the same:
#   !! <title>
#      <note>
#      <note>
#
#   Last 30 lines of /var/log/whatever.log:
#     <log line>
#     ...
# The log is drawn muted and made safe line by line (see _ui_safe_line); a line
# too long for the terminal is cut short with "...", since the full text is in
# the file the block names. A missing or empty log says "(no log yet)", and
# lines=0 leaves the tail out (for a caller whose output is already on screen).
# Menus stay with the caller: this only draws.
ui_failure() {
    _ui_init
    local LC_ALL=C.UTF-8
    local title="$1" log="$2" lines="${3:-30}"
    shift 2
    (( $# )) && shift
    [[ "${lines}" =~ ^[0-9]+$ ]] || lines=30

    local nl=$'\n' out note cols max line
    out="${nl}${UI_ERROR}${UI_BOLD}!!${UI_RESET} ${UI_TEXT}${UI_BOLD}${title}${UI_RESET}${nl}"
    for note in "$@"; do
        out+="   ${note}${nl}"
    done
    if (( lines == 0 )); then
        _ui_out "${out}"
        return 0
    fi
    out+="${nl}"

    local -a tail=()
    if [[ -s "${log}" && -r "${log}" ]]; then
        mapfile -t tail < <(tail -n "${lines}" -- "${log}" 2>/dev/null)
    fi
    if (( ${#tail[@]} == 0 )); then
        out+="${UI_MUTED}(no log yet: ${log})${UI_RESET}${nl}"
        _ui_out "${out}"
        return 0
    fi

    # Indented two, and never into the last column (see ui_card).
    cols="$(_ui_cols)"
    max=$(( cols - 3 ))
    (( max >= 20 )) || max=20
    out+="${UI_MUTED}Last ${#tail[@]} lines of ${log}:${UI_RESET}${nl}"
    for line in "${tail[@]}"; do
        _ui_safe_line "${line}" "${max}"
        out+="  ${UI_MUTED}${_UI_SAFE}${UI_RESET}${nl}"
    done
    _ui_out "${out}"
}

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
    size="$(stty size 2>/dev/null < /dev/tty)" || return 1
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
