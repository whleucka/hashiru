#!/usr/bin/env bash
# 99-reboot.sh — Dev/app packages, user groups, verification, and reboot prompt

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

script_start "99-reboot.sh"

log_info "Running final verification checks..."

# Install dev and app packages
install_packages "dev.txt"
install_packages "apps.txt"

# Ensure a default Rust toolchain is set up. The rustup package alone installs
# no toolchain, so cargo is unusable until a default is chosen. Needed because
# blink.cmp (neovim) builds its Rust fuzzy-matching library from source on first
# launch.
if command -v rustup &>/dev/null; then
    if ! rustup show active-toolchain &>/dev/null; then
        log_info "Setting up Rust toolchain"
        rustup default stable
    fi
fi

# Add user to necessary groups
GROUPS_TO_ADD=(docker video input)
for grp in "${GROUPS_TO_ADD[@]}"; do
    if getent group "${grp}" &>/dev/null; then
        if ! id -nG "${USER}" | tr ' ' '\n' | grep -qx "${grp}"; then
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
log_success "Hashiru stages complete!"
log_success "=========================================="
echo ""
log_info "Reboot to start Hyprland"
echo ""

# This stage deliberately does NOT reboot. install.sh writes
# /etc/hashiru-release *after* the stage loop, so rebooting from in here takes
# the machine down before the stamp is written — a full interactive install
# could never record which commit built it. The reboot prompt lives at the end
# of install.sh instead, after the stamp.
#
# Unattended runs never reboot here either: the hashiru-firstboot wrapper
# reboots *after* it disables its own unit, and rebooting from inside the
# bootstrap races that disable — the machine goes down before the unit is torn
# down, so it re-runs on every boot (reboot loop).

script_end "99-reboot.sh"
