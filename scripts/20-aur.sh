#!/usr/bin/env bash
# 20-aur.sh — Bootstrap paru AUR helper, install AUR packages

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

script_start "20-aur.sh"

# Bootstrap paru if not installed
if ! command -v paru &>/dev/null; then
    log_info "Installing paru AUR helper"

    # Ensure base-devel is installed
    sudo pacman -S --needed --noconfirm base-devel git

    # Clone and build paru
    PARU_DIR=$(mktemp -d)
    git clone https://aur.archlinux.org/paru-bin.git "${PARU_DIR}"
    pushd "${PARU_DIR}" > /dev/null
    makepkg -si --noconfirm
    popd > /dev/null
    rm -rf "${PARU_DIR}"

    log_success "paru installed"
else
    log_info "paru already installed"
fi

# Install AUR packages
install_aur_packages "aur.txt"

script_end "20-aur.sh"
