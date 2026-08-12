#!/usr/bin/env bash
# 40-hyprland.sh — Hyprland environment setup

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

script_start "40-hyprland.sh"

# Hyprland packages are installed via wayland.txt (30-desktop.sh).
# Hyprland's configuration is a Hashiru-owned stow package and lands in the
# next stage — this one only prepares the directories it expects to exist.

# Create Screenshots directory for grim
ensure_dir "${HOME}/Pictures/Screenshots"

log_info "Hyprland config is stowed from stow/hyprland by 45-config.sh"

script_end "40-hyprland.sh"
