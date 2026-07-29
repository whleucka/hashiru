#!/usr/bin/env bash
# 60-dotfiles.sh — Clone and stow user dotfiles

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

script_start "60-dotfiles.sh"

readonly DOTFILES_REPO="https://github.com/whleucka/dotfiles.git"
readonly DOTFILES_DIR="${HOME}/.dotfiles"

# Ensure stow is installed
if ! command -v stow &>/dev/null; then
    log_info "Installing GNU Stow"
    sudo pacman -S --needed --noconfirm stow
fi

# Clone dotfiles repository
if [[ -d "${DOTFILES_DIR}" ]]; then
    log_info "Dotfiles directory already exists, pulling latest"
    git -C "${DOTFILES_DIR}" pull --ff-only || log_warn "Could not pull dotfiles (may have local changes)"
else
    log_info "Cloning dotfiles repository"
    git clone "${DOTFILES_REPO}" "${DOTFILES_DIR}"
    log_success "Dotfiles cloned to ${DOTFILES_DIR}"
fi

# useradd seeds /etc/skel copies into every new home, and stow refuses to
# replace a real file with a symlink — so on a fresh install the bash package
# always fails to stow. Drop them only if still byte-identical to skel (a
# pristine copy carries no user data); anything modified is left for stow to
# warn about. The -L guard skips already-stowed symlinks on re-runs.
for f in .bashrc .bash_profile .bash_logout; do
    if [[ -f "${HOME}/${f}" && ! -L "${HOME}/${f}" ]] && cmp -s "${HOME}/${f}" "/etc/skel/${f}"; then
        rm "${HOME}/${f}"
        log_info "Removed pristine skel file blocking stow: ~/${f}"
    fi
done

# Stow all directories
cd "${DOTFILES_DIR}" || { log_error "Failed to cd into ${DOTFILES_DIR}"; exit 1; }

log_info "Stowing dotfiles to ${HOME}"
for dir in */; do
    dir="${dir%/}" # Remove trailing slash
    # Skip hidden directories and common non-stow items
    [[ "${dir}" == .* ]] && continue
    [[ "${dir}" == "README"* ]] && continue
    [[ "${dir}" == "LICENSE"* ]] && continue
    [[ "${dir}" == "omarchy" ]] && continue

    log_info "Stowing: ${dir}"
    stow --restow --target="${HOME}" "${dir}" || log_warn "Failed to stow ${dir}"
done

log_success "Dotfiles stowed successfully"

# Rebuild bat cache for custom themes
if command -v bat &>/dev/null; then
    log_info "Rebuilding bat cache for custom themes"
    bat cache --build
    log_success "bat cache rebuilt"
fi

# Install herdr (terminal workspace manager; replaces tmux/TPM). There is no
# AUR package, so use the official installer — it downloads the right binary for
# the platform and drops it on PATH at ~/.local/bin/herdr. Runs as the invoking
# user (not root) so it lands in this home; skip if already present. herdr's own
# config comes from the stowed dotfiles, so no plugin bootstrap or systemd unit
# is needed — herdr is the multiplexer, launched directly by the terminal.
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

script_end "60-dotfiles.sh"
