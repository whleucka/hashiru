#!/usr/bin/env bash
# 10-base.sh — Core packages, microcode, firmware

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

script_start "10-base.sh"

# Update system first
log_info "Updating system packages"
sudo pacman -Syu --noconfirm

# Install base packages
install_packages "base.txt"

# Enable services
enable_and_start_service "NetworkManager"
enable_and_start_service "bluetooth"
enable_service "fstrim.timer"

# Power management: TLP for ThinkPads
# Mask power-profiles-daemon to prevent conflicts if installed as dependency
sudo systemctl mask power-profiles-daemon &>/dev/null || true
enable_and_start_service "tlp"

# Enable reflector timer for weekly mirrorlist updates
enable_service "reflector.timer"

# Set up pacman hooks directory
ensure_dir "/etc/pacman.d/hooks"

# Install system configs
if [[ -f "${SCRIPT_DIR}/config/sysctl.d/99-hashiru.conf" ]]; then
    log_info "Installing sysctl configuration"
    sudo cp "${SCRIPT_DIR}/config/sysctl.d/99-hashiru.conf" /etc/sysctl.d/
    sudo sysctl --system > /dev/null
fi

if [[ -f "${SCRIPT_DIR}/config/udev/99-hashiru.rules" ]]; then
    log_info "Installing udev rules"
    sudo cp "${SCRIPT_DIR}/config/udev/99-hashiru.rules" /etc/udev/rules.d/
    sudo udevadm control --reload-rules
    sudo udevadm trigger
fi

script_end "10-base.sh"
