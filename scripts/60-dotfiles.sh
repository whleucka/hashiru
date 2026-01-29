#!/usr/bin/env bash
# 60-dotfiles.sh — Clone and stow dotfiles

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

script_start "60-dotfiles.sh"

# Configuration — adjust these for your setup
DOTFILES_REPO="${DOTFILES_REPO:-}"
DOTFILES_DIR="${HOME}/.dotfiles"

if [[ -z "${DOTFILES_REPO}" ]]; then
    log_warn "DOTFILES_REPO not set — skipping dotfiles setup"
    log_info "To use dotfiles, run: DOTFILES_REPO=https://github.com/user/dotfiles ./install.sh 60"
    script_end "60-dotfiles.sh"
    exit 0
fi

# Clone dotfiles if not present
if [[ ! -d "${DOTFILES_DIR}" ]]; then
    log_info "Cloning dotfiles from ${DOTFILES_REPO}"
    git clone "${DOTFILES_REPO}" "${DOTFILES_DIR}"
    log_success "Dotfiles cloned to ${DOTFILES_DIR}"
else
    log_info "Dotfiles directory already exists, pulling latest"
    git -C "${DOTFILES_DIR}" pull --ff-only || log_warn "Could not pull dotfiles (maybe local changes?)"
fi

# Stow all directories
cd "${DOTFILES_DIR}"

# Find all directories that look like stow packages (not hidden, not special)
STOW_PACKAGES=()
for dir in */; do
    dir="${dir%/}"
    # Skip hidden dirs and common non-stow dirs
    [[ "${dir}" == .* ]] && continue
    [[ "${dir}" == "README"* ]] && continue
    STOW_PACKAGES+=("${dir}")
done

if [[ ${#STOW_PACKAGES[@]} -eq 0 ]]; then
    log_warn "No stow packages found in ${DOTFILES_DIR}"
else
    log_info "Stowing packages: ${STOW_PACKAGES[*]}"

    for pkg in "${STOW_PACKAGES[@]}"; do
        log_info "Stowing: ${pkg}"
        # --restow handles both new and existing links
        # --no-folding prevents stow from creating parent directory links
        if ! stow --restow --no-folding --target="${HOME}" "${pkg}"; then
            log_error "Failed to stow ${pkg} — resolve conflicts manually"
            exit 1
        fi
    done

    log_success "All dotfiles stowed"
fi

script_end "60-dotfiles.sh"
