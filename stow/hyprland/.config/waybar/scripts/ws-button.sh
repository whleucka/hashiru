#!/bin/bash
# Emits Waybar JSON for a single workspace button.
# Usage: ws-button.sh <workspace-number> [mode]
#   mode = "always" (default) -> always shown
#   mode = "auto"             -> hidden (empty output) unless active or occupied
# class is "active" when focused, "occupied" when it has windows, else "empty".
#
# State comes from the cache written by ws-listener.sh (event-driven, cheap).
# If the cache is missing (listener not running), fall back to a live hyprctl
# query so the bar still works.

ws="$1"
mode="${2:-always}"

CACHE="${XDG_RUNTIME_DIR:-/tmp}/waybar-ws.state"

active=""
occupied=""

if [ -r "$CACHE" ]; then
    # Pure-builtin read: no subprocess per button.
    while read -r key val; do
        case "$key" in
            active) active="$val" ;;
            occupied) occupied="$val" ;;
        esac
    done <"$CACHE"
else
    # Live fallback (listener down / first run before seed).
    active=$(hyprctl activeworkspace -j | jq -r '.id')
    occupied=$(hyprctl workspaces -j | jq -r '.[] | select(.windows > 0 and .id > 0) | .id' | tr '\n' ' ')
fi

if [ "$active" = "$ws" ]; then
    class="active"
elif [[ " $occupied " == *" $ws "* ]]; then
    class="occupied"
else
    class="empty"
fi

# Auto mode: collapse the button (empty text => Waybar hides it) when nothing's there.
if [ "$mode" = "auto" ] && [ "$class" = "empty" ]; then
    printf '{"text": "", "class": "empty", "tooltip": ""}\n'
    exit 0
fi

# Display label: workspace 10 shows as "0".
label="$ws"
[ "$ws" -eq 10 ] && label="0"

printf '{"text": "%s", "class": "%s", "tooltip": "Workspace %s"}\n' "$label" "$class" "$ws"
