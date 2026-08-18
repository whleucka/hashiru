#!/usr/bin/env bash
# 60-herdr.sh — Install the herdr binary
#
# Hashiru owns herdr: it is the multiplexer the terminal launches, five scripts
# in stow/hyprland/.config/hypr/scripts drive it (herdr-flip, -nav, -route,
# -split-run, -swap), and its config is a Hashiru stow package placed by
# 45-config.sh. Only the binary is installed here — this stage is where
# third-party user binaries land.
#
# This stage used to clone and stow a personal dotfiles repo. It no longer does,
# and Hashiru no longer knows what dotfiles are: everything it stows lives in
# stow/ and is placed by 45-config.sh. The dividing line is now simply whether a
# thing is needed on a machine Hashiru did not build — an editor config is, a
# shell prompt and a file manager theme are not.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

script_start "60-herdr.sh"

# Install herdr (terminal workspace manager; replaces tmux/TPM). There is no
# AUR package, so use the official installer — it downloads the right binary for
# the platform and drops it on PATH at ~/.local/bin/herdr. Runs as the invoking
# user (not root) so it lands in this home; skip if already present. No plugin
# bootstrap or systemd unit is needed; herdr is the multiplexer, launched
# directly by the terminal.
readonly HERDR_BIN="${HOME}/.local/bin/herdr"
if command -v herdr &>/dev/null || [[ -x "${HERDR_BIN}" ]]; then
    log_info "herdr already installed"
else
    log_info "Installing herdr"
    if curl -fsSL https://herdr.dev/install.sh | sh; then
        log_success "herdr installed"
    else
        log_warn "herdr install failed (retry: curl -fsSL https://herdr.dev/install.sh | sh)"
    fi
fi

script_end "60-herdr.sh"
