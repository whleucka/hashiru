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

# Install tmux systemd user service. Stow places the unit symlink itself when
# ~/.config/systemd/user already exists, so the link may or may not be ours —
# either way, a merely *linked* unit does not start at login: it must also be
# enabled. Do the two steps independently so stow winning the link race can't
# skip the enable (that exact bug left the unit dead on a real machine).
readonly TMUX_SERVICE_SRC="${DOTFILES_DIR}/tmux/.config/systemd/user/tmux.service"
readonly TMUX_SERVICE_DST="${HOME}/.config/systemd/user/tmux.service"
if [[ -f "${TMUX_SERVICE_SRC}" ]]; then
    if [[ ! -f "${TMUX_SERVICE_DST}" ]]; then
        log_info "Installing tmux systemd user service"
        ensure_dir "${HOME}/.config/systemd/user"
        ln -sf "${TMUX_SERVICE_SRC}" "${TMUX_SERVICE_DST}"
    fi
    systemctl --user daemon-reload
    if ! is_service_enabled tmux.service --user; then
        systemctl --user enable tmux.service
        log_success "tmux service enabled (starts on login)"
    fi
fi

script_end "60-dotfiles.sh"
