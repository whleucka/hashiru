#!/usr/bin/env bash
# 30-desktop.sh — Wayland stack, PipeWire audio, desktop utilities

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

script_start "30-desktop.sh"

# Install Wayland/desktop packages
install_packages "wayland.txt"

# Install fonts
install_packages "fonts.txt"

# Enable PipeWire (user services)
# Note: These start automatically on login, but we enable them explicitly
log_info "Enabling PipeWire audio services"
systemctl --user enable --now pipewire.socket || true
systemctl --user enable --now pipewire-pulse.socket || true
systemctl --user enable --now wireplumber.service || true

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

script_end "30-desktop.sh"
