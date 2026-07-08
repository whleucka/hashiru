#!/usr/bin/env bash
# 20-aur.sh — Bootstrap yay AUR helper, install AUR packages

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

script_start "20-aur.sh"

# Bootstrap yay if not installed
if ! command -v yay &>/dev/null; then
    log_info "Installing yay AUR helper"

    # Ensure base-devel is installed
    sudo pacman -S --needed --noconfirm base-devel git

    # Clone and build yay (EXIT trap cleans up even if the build fails)
    YAY_DIR=$(mktemp -d)
    trap 'rm -rf "${YAY_DIR}"' EXIT
    git clone https://aur.archlinux.org/yay-bin.git "${YAY_DIR}"
    pushd "${YAY_DIR}" > /dev/null
    makepkg -si --noconfirm
    popd > /dev/null

    log_success "yay installed"
else
    log_info "yay already installed"
fi

# Install AUR packages
install_aur_packages "aur.txt"

script_end "20-aur.sh"
