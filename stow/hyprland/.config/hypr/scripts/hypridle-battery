#!/usr/bin/env bash
# Keep hypridle running with the config for the current power source:
# hypridle-battery.conf on battery, hypridle-ac.conf on AC.
#
# hypridle always runs. It used to be stopped on AC, and it is also what locks
# the screen before sleep, so a lid closed on AC resumed straight to the desktop.
# A machine with no AC supply (a desktop) counts as AC.
#
# A machine's own timeouts go in ~/.config/hashiru/hypr/hypridle-{ac,battery}.conf,
# which replace the stowed file for that power source (like monitors.lua does).
# `hypridle-battery reload` restarts hypridle on the right file and exits, for
# after editing one; the running watcher carries on undisturbed.

AC_PATH="/sys/class/power_supply/AC/online"
CONF_DIR="${HOME}/.config/hypr"
OVERRIDE_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/hashiru/hypr"
mode=""

# conf_for MODE: the override if there's a readable one, else Hashiru's.
conf_for() {
    local override="${OVERRIDE_DIR}/hypridle-$1.conf"
    if [[ -r "${override}" ]]; then
        echo "${override}"
    else
        echo "${CONF_DIR}/hypridle-$1.conf"
    fi
}

run_idle() {
    [[ "$1" == "${mode}" ]] && pidof hypridle > /dev/null && return
    # -x: without it the pattern also matches this script's own process name.
    pkill -x hypridle 2>/dev/null
    while pidof hypridle > /dev/null; do sleep 0.1; done
    hypridle -c "$(conf_for "$1")" &
    disown
    mode="$1"
}

update() {
    if [[ -r "${AC_PATH}" && "$(cat "${AC_PATH}")" == "0" ]]; then
        run_idle battery
    else
        run_idle ac
    fi
}

# Restart on the current file and leave the watcher be: its "already running
# in this mode" check still holds, so it doesn't start a second one. Output
# goes nowhere: hypridle outlives this, and holding the caller's stdout open
# would leave anything reading it (hashiru-tui) waiting until hypridle exits.
if [[ "${1:-}" == "reload" ]]; then
    exec > /dev/null 2>&1
    update
    exit 0
fi

# Set initial state
update

# Monitor for power supply changes
upower --monitor | while read -r line; do
    if [[ "$line" == *"AC"* || "$line" == *"line-power"* || "$line" == *"on-battery"* ]]; then
        sleep 1
        update
    fi
done
