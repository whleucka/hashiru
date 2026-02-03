#!/usr/bin/env bash
# 99-reboot.sh — Final verification and reboot prompt

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

script_start "99-reboot.sh"

log_info "Running final verification checks..."

# Install dev and app packages
install_packages "dev.txt"
install_packages "apps.txt"

# Install cargo packages (tree-sitter-cli v0.26+ required for neovim-nightly)
if command -v rustup &>/dev/null; then
    log_info "Setting up Rust toolchain"
    rustup default stable
    log_info "Installing cargo packages"
    cargo install tree-sitter-cli
    log_success "Cargo packages installed"
fi

# Add user to necessary groups
GROUPS_TO_ADD=(docker video input)
for grp in "${GROUPS_TO_ADD[@]}"; do
    if getent group "${grp}" &>/dev/null; then
        if ! groups "${USER}" | grep -q "\b${grp}\b"; then
            sudo usermod -aG "${grp}" "${USER}"
            log_info "Added ${USER} to group: ${grp}"
        fi
    fi
done

# Enable docker service
if is_pkg_installed "docker"; then
    enable_service "docker.socket"
fi

# Verification checks
log_info "Verification results:"

echo ""
echo "=== Hyprland ==="
if command -v Hyprland &>/dev/null; then
    Hyprland --version 2>/dev/null | head -1 || echo "Hyprland installed"
else
    log_warn "Hyprland not found"
fi

echo ""
echo "=== PipeWire ==="
if systemctl --user is-active pipewire &>/dev/null; then
    echo "PipeWire: active"
else
    echo "PipeWire: not running (will start on login)"
fi

echo ""
echo "=== Snapper ==="
if command -v snapper &>/dev/null; then
    snapper -c root list 2>/dev/null | head -5 || echo "Snapper configured"
else
    log_warn "Snapper not configured"
fi

echo ""
echo "=== Environment ==="
echo "EDITOR: ${EDITOR:-not set}"
echo "TERMINAL: ${TERMINAL:-not set}"
echo "SHELL: ${SHELL}"

echo ""
log_success "=========================================="
log_success "Hashiru installation complete!"
log_success "=========================================="
echo ""
log_info "Please reboot to start Hyprland"
log_info "After reboot, select Hyprland from your display manager or run 'Hyprland' from TTY"
echo ""

# Don't auto-reboot, let user decide
read -rp "Reboot now? [y/N] " response
if [[ "${response}" =~ ^[Yy]$ ]]; then
    log_info "Rebooting..."
    sudo reboot
fi

script_end "99-reboot.sh"
