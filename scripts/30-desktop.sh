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

# Set up environment variables
ensure_dir "${HOME}/.config/environment.d"
ENV_FILE="${HOME}/.config/environment.d/10-hashiru.conf"

if [[ ! -f "${ENV_FILE}" ]]; then
    log_info "Creating environment configuration"
    cat > "${ENV_FILE}" << 'EOF'
# Hashiru environment configuration
EDITOR=nvim
VISUAL=nvim
TERMINAL=kitty
BROWSER=chromium

# Wayland
XDG_SESSION_TYPE=wayland
XDG_CURRENT_DESKTOP=Hyprland

# Qt
QT_QPA_PLATFORM=wayland
QT_WAYLAND_DISABLE_WINDOWDECORATION=1

# GTK
GDK_BACKEND=wayland

# Firefox (native Wayland)
MOZ_ENABLE_WAYLAND=1
EOF
    log_success "Environment configuration created"
else
    log_info "Environment configuration already exists"
fi

# Set default shell to zsh
if [[ "${SHELL}" != */zsh ]]; then
    log_info "Changing default shell to zsh"
    chsh -s /usr/bin/zsh
    log_success "Default shell changed to zsh (effective on next login)"
else
    log_info "Shell already set to zsh"
fi

# Set up TTY1 auto-login
AUTOLOGIN_DIR="/etc/systemd/system/getty@tty1.service.d"
if [[ ! -f "${AUTOLOGIN_DIR}/autologin.conf" ]]; then
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

# Add Hyprland auto-start to zprofile
ZPROFILE="${HOME}/.zprofile"
if ! grep -q "start-hyprland" "${ZPROFILE}" 2>/dev/null; then
    log_info "Adding Hyprland auto-start to .zprofile"
    cat >> "${ZPROFILE}" << 'EOF'

# Auto-start Hyprland on TTY1
if [[ -z "${DISPLAY}" && "${XDG_VTNR}" == 1 ]]; then
    if command -v start-hyprland &>/dev/null; then
        exec start-hyprland
    else
        exec Hyprland
    fi
fi
EOF
    log_success "Hyprland auto-start configured"
else
    log_info "Hyprland auto-start already in .zprofile"
fi

script_end "30-desktop.sh"
