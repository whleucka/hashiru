#!/usr/bin/env bash
# 30-desktop.sh — Wayland stack, PipeWire audio, desktop utilities

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

script_start "30-desktop.sh"

# Create XDG user directories (Documents, Downloads, Pictures, etc.)
log_info "Creating XDG user directories"
xdg-user-dirs-update

# Install Wayland/desktop packages
install_packages "wayland.txt"

# Install terminal utilities
install_packages "terminal.txt"

# Install fonts
install_packages "fonts.txt"

# Enable PipeWire (user services)
# Note: These start automatically on login, but we enable them explicitly
log_info "Enabling PipeWire audio services"
enable_and_start_service "pipewire.socket" --user
enable_and_start_service "pipewire-pulse.socket" --user
enable_and_start_service "wireplumber.service" --user

# Session environment (environment.d/10-hashiru.conf) is stowed by 45-config.sh
# from stow/hyprland/ — it is config, so it lives with the rest of the config
# and updates with a `hashiru update` like everything else.

# Set default shell to zsh
if [[ "${SHELL}" != */zsh ]]; then
    log_info "Changing default shell to zsh"
    # Use sudo so this never prompts for the user's password via PAM — works
    # both interactively and under the unattended first-boot bootstrap.
    sudo chsh -s /usr/bin/zsh "${USER}"
    log_success "Default shell changed to zsh (effective on next login)"
else
    log_info "Shell already set to zsh"
fi

# Set up TTY1 auto-login, but only when / is on LUKS: then the disk passphrase
# at boot is the login. On a plain disk it would hand the desktop to anyone who
# powers the machine on. hyprlock still guards suspend and idle either way.
AUTOLOGIN_DIR="/etc/systemd/system/getty@tty1.service.d"
if ! lsblk -nso TYPE "$(findmnt -nvo SOURCE /)" 2>/dev/null | grep -qx crypt; then
    if [[ -f "${AUTOLOGIN_DIR}/autologin.conf" ]]; then
        sudo rm -f "${AUTOLOGIN_DIR}/autologin.conf"
        log_warn "Root is not on LUKS: removed TTY1 auto-login (log in on tty1 from next boot)"
    else
        log_info "Root is not on LUKS: skipping TTY1 auto-login"
    fi
elif [[ ! -f "${AUTOLOGIN_DIR}/autologin.conf" ]]; then
    log_info "Configuring TTY1 auto-login for ${USER}"
    sudo mkdir -p "${AUTOLOGIN_DIR}"
    sudo tee "${AUTOLOGIN_DIR}/autologin.conf" > /dev/null << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --noclear --autologin ${USER} %I \$TERM
EOF
    log_success "TTY1 auto-login configured"
else
    log_info "TTY1 auto-login already configured"
fi

# Hyprland's TTY1 auto-start lives in stow/hyprland/.zprofile and is stowed by
# 45-config.sh. It used to be appended here, which left ownership of .zprofile
# ambiguous between this script and the user's dotfiles; Hashiru owns the
# desktop hand-off, so it owns that file.

script_end "30-desktop.sh"
