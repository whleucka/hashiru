#!/usr/bin/env bash
# 40-hyprland.sh — Hyprland environment setup

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

script_start "40-hyprland.sh"

# Hyprland packages installed via wayland.txt
# Configuration comes from dotfiles (60-dotfiles.sh)

# Create Screenshots directory for grim
ensure_dir "${HOME}/Pictures/Screenshots"

# Note: Hyprland configuration comes from dotfiles (60-dotfiles.sh)
# Config will be stowed in a later stage
log_info "Hyprland config will be provided by dotfiles (60-dotfiles.sh)"

script_end "40-hyprland.sh"
