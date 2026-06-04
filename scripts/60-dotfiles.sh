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

# Install TPM (tmux plugin manager) and plugins
# XDG location: tmux.conf lives in ~/.config/tmux, so TPM and plugins do too
readonly TPM_DIR="${HOME}/.config/tmux/plugins/tpm"
if [[ ! -d "${TPM_DIR}" ]]; then
    log_info "Installing tmux plugin manager (TPM)"
    git clone https://github.com/tmux-plugins/tpm "${TPM_DIR}"
    log_success "TPM installed"
else
    log_info "TPM already installed"
fi

# Install tmux plugins (resurrect, continuum)
if [[ -x "${TPM_DIR}/bin/install_plugins" ]]; then
    log_info "Installing tmux plugins"
    "${TPM_DIR}/bin/install_plugins"
    log_success "tmux plugins installed"
fi

# Install tmux systemd user service (stow can't merge into existing systemd dir)
readonly TMUX_SERVICE_SRC="${DOTFILES_DIR}/tmux/.config/systemd/user/tmux.service"
readonly TMUX_SERVICE_DST="${HOME}/.config/systemd/user/tmux.service"
if [[ -f "${TMUX_SERVICE_SRC}" ]] && [[ ! -f "${TMUX_SERVICE_DST}" ]]; then
    log_info "Installing tmux systemd user service"
    ensure_dir "${HOME}/.config/systemd/user"
    ln -sf "${TMUX_SERVICE_SRC}" "${TMUX_SERVICE_DST}"
    systemctl --user daemon-reload
    systemctl --user enable tmux.service
    log_success "tmux service enabled (starts on login)"
fi

script_end "60-dotfiles.sh"
