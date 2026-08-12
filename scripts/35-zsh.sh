#!/usr/bin/env bash
# 35-zsh.sh — Oh My Zsh, Powerlevel10k theme, and plugins

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

script_start "35-zsh.sh"

readonly OH_MY_ZSH_DIR="${HOME}/.oh-my-zsh"
readonly CUSTOM_PLUGINS_DIR="${OH_MY_ZSH_DIR}/custom/plugins"
readonly CUSTOM_THEMES_DIR="${OH_MY_ZSH_DIR}/custom/themes"

# Install Oh My Zsh (unattended, won't modify .zshrc since dotfiles handles that)
if [[ ! -d "${OH_MY_ZSH_DIR}" ]]; then
    log_info "Installing Oh My Zsh"
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    log_success "Oh My Zsh installed"
else
    log_info "Oh My Zsh already installed"
fi

# Clear a real ~/.zshrc out of the way so a stow package can take the path —
# either the user's dotfiles (60-dotfiles.sh) or Hashiru's fallback
# (stow/zsh-fallback, see ensure_zshrc in lib/common.sh).
#
# Only omz's own freshly-generated copy is deleted outright, identified by
# comparing against the template it was rendered from. Anything else is a file
# the user wrote, and gets backed up rather than destroyed — this used to `rm`
# unconditionally, which silently ate a hand-written .zshrc on the first run.
# Mirrors the /etc/skel guard in 45-config.sh and 60-dotfiles.sh.
readonly OMZ_TEMPLATE="${OH_MY_ZSH_DIR}/templates/zshrc.zsh-template"
if [[ -f "${HOME}/.zshrc" && ! -L "${HOME}/.zshrc" ]]; then
    if [[ -f "${OMZ_TEMPLATE}" ]] && cmp -s "${HOME}/.zshrc" "${OMZ_TEMPLATE}"; then
        log_info "Removing auto-generated .zshrc (unmodified Oh My Zsh template)"
        rm "${HOME}/.zshrc"
    else
        backup="${HOME}/.zshrc.pre-hashiru"
        [[ -e "${backup}" ]] && backup="${backup}.$(date +%s)"
        mv "${HOME}/.zshrc" "${backup}"
        log_warn "Backed up your existing ~/.zshrc -> ${backup##*/} to make room for a stowed one"
    fi
fi

# Install Powerlevel10k theme
P10K_DIR="${CUSTOM_THEMES_DIR}/powerlevel10k"
if [[ ! -d "${P10K_DIR}" ]]; then
    log_info "Installing Powerlevel10k theme"
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "${P10K_DIR}"
    log_success "Powerlevel10k installed"
else
    log_info "Powerlevel10k already installed"
fi

# Install zsh-autosuggestions plugin
AUTOSUGGESTIONS_DIR="${CUSTOM_PLUGINS_DIR}/zsh-autosuggestions"
if [[ ! -d "${AUTOSUGGESTIONS_DIR}" ]]; then
    log_info "Installing zsh-autosuggestions plugin"
    git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions.git "${AUTOSUGGESTIONS_DIR}"
    log_success "zsh-autosuggestions installed"
else
    log_info "zsh-autosuggestions already installed"
fi

# Install zsh-syntax-highlighting plugin
SYNTAX_HIGHLIGHTING_DIR="${CUSTOM_PLUGINS_DIR}/zsh-syntax-highlighting"
if [[ ! -d "${SYNTAX_HIGHLIGHTING_DIR}" ]]; then
    log_info "Installing zsh-syntax-highlighting plugin"
    git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git "${SYNTAX_HIGHLIGHTING_DIR}"
    log_success "zsh-syntax-highlighting installed"
else
    log_info "zsh-syntax-highlighting already installed"
fi

# Install zsh-256color plugin
ZSH_256COLOR_DIR="${CUSTOM_PLUGINS_DIR}/zsh-256color"
if [[ ! -d "${ZSH_256COLOR_DIR}" ]]; then
    log_info "Installing zsh-256color plugin"
    git clone --depth=1 https://github.com/chrissicool/zsh-256color.git "${ZSH_256COLOR_DIR}"
    log_success "zsh-256color installed"
else
    log_info "zsh-256color already installed"
fi

log_info "Ensure your .zshrc has: ZSH_THEME=\"powerlevel10k/powerlevel10k\""
log_info "Ensure your .zshrc has: plugins=(... zsh-256color zsh-autosuggestions zsh-syntax-highlighting)"

script_end "35-zsh.sh"
