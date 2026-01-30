#!/usr/bin/env bash
# 40-hyprland.sh — Hyprland environment setup

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

script_start "40-hyprland.sh"

# Hyprland packages installed via wayland.txt
# Configuration comes from dotfiles (60-dotfiles.sh)

# Create Screenshots directory for grim
ensure_dir "${HOME}/Pictures/Screenshots"

# Verify config exists (should be stowed from dotfiles)
HYPR_CONFIG_DIR="${HOME}/.config/hypr"
if [[ -f "${HYPR_CONFIG_DIR}/hyprland.conf" ]]; then
    log_success "Hyprland configuration found"
else
    log_warn "No Hyprland config found — ensure dotfiles are stowed (60-dotfiles.sh)"
fi

script_end "40-hyprland.sh"
