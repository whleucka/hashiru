#!/usr/bin/env bash
# 40-hyprland.sh — Hyprland configuration

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

script_start "40-hyprland.sh"

# Hyprland packages already installed via wayland.txt
# This script sets up the configuration

HYPR_CONFIG_DIR="${HOME}/.config/hypr"
ensure_dir "${HYPR_CONFIG_DIR}"

# Create Screenshots directory for grim
ensure_dir "${HOME}/Pictures/Screenshots"

# Copy Hyprland config if we have one and user doesn't
if [[ -d "${SCRIPT_DIR}/hypr" ]] && [[ ! -f "${HYPR_CONFIG_DIR}/hyprland.conf" ]]; then
    log_info "Installing Hyprland configuration"
    cp -r "${SCRIPT_DIR}/hypr/"* "${HYPR_CONFIG_DIR}/"
    log_success "Hyprland configuration installed"
elif [[ -f "${HYPR_CONFIG_DIR}/hyprland.conf" ]]; then
    log_info "Hyprland configuration already exists, skipping"
else
    log_warn "No Hyprland config in repo and none exists — you'll need to configure manually"
fi

# Ensure hypridle and hyprlock configs exist
if [[ ! -f "${HYPR_CONFIG_DIR}/hypridle.conf" ]]; then
    log_info "Creating default hypridle configuration"
    cat > "${HYPR_CONFIG_DIR}/hypridle.conf" << 'EOF'
general {
    lock_cmd = pidof hyprlock || hyprlock
    before_sleep_cmd = loginctl lock-session
    after_sleep_cmd = hyprctl dispatch dpms on
}

listener {
    timeout = 300
    on-timeout = brightnessctl -s set 10
    on-resume = brightnessctl -r
}

listener {
    timeout = 600
    on-timeout = loginctl lock-session
}

listener {
    timeout = 660
    on-timeout = hyprctl dispatch dpms off
    on-resume = hyprctl dispatch dpms on
}

listener {
    timeout = 1800
    on-timeout = systemctl suspend
}
EOF
fi

if [[ ! -f "${HYPR_CONFIG_DIR}/hyprlock.conf" ]]; then
    log_info "Creating default hyprlock configuration"
    cat > "${HYPR_CONFIG_DIR}/hyprlock.conf" << 'EOF'
background {
    monitor =
    path = screenshot
    blur_passes = 3
    blur_size = 8
}

input-field {
    monitor =
    size = 200, 50
    outline_thickness = 3
    dots_size = 0.33
    dots_spacing = 0.15
    dots_center = false
    outer_color = rgb(151515)
    inner_color = rgb(200, 200, 200)
    font_color = rgb(10, 10, 10)
    fade_on_empty = true
    placeholder_text = <i>Password...</i>
    hide_input = false
    position = 0, -20
    halign = center
    valign = center
}
EOF
fi

script_end "40-hyprland.sh"
