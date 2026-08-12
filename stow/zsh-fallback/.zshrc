# Hashiru fallback .zshrc
#
# This is the safety net, not a config to grow. Hashiru installs zsh, Oh My Zsh,
# Powerlevel10k and three plugins (35-zsh.sh) and sets zsh as the login shell —
# without a .zshrc all of that sits on disk doing nothing, and you get a bare
# prompt. This wires it together and stops there.
#
# It is stowed ONLY when nothing else provides ~/.zshrc (see 45-config.sh). The
# moment a dotfiles repo supplies one, Hashiru unstows this and gets out of the
# way — so if you have dotfiles, editing this file will do nothing for you.

# --- Powerlevel10k instant prompt --------------------------------------------
# Must stay near the top: p10k requires it before anything that writes to the
# terminal. `quiet` suppresses the warning that console output triggers.
typeset -g POWERLEVEL9K_INSTANT_PROMPT=quiet
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
    source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# --- Path ---------------------------------------------------------------------
# herdr and other user binaries land in ~/.local/bin (60-dotfiles.sh).
[[ ":$PATH:" != *":$HOME/.local/bin:"* ]] && export PATH="$HOME/.local/bin:$PATH"

# --- Oh My Zsh ----------------------------------------------------------------
# Guarded: a broken .zshrc on the login shell is how you end up with no working
# terminal, so an incomplete omz install must degrade to a plain shell.
export ZSH="${HOME}/.oh-my-zsh"
if [[ -d "${ZSH}" ]]; then
    [[ -d "${ZSH}/custom/themes/powerlevel10k" ]] && ZSH_THEME="powerlevel10k/powerlevel10k"

    # Only the plugins 35-zsh.sh actually installs, plus git (bundled with omz).
    plugins=(git)
    for _p in zsh-256color zsh-autosuggestions zsh-syntax-highlighting; do
        [[ -d "${ZSH}/custom/plugins/${_p}" ]] && plugins+=("${_p}")
    done
    unset _p

    source "${ZSH}/oh-my-zsh.sh"
fi

# --- History ------------------------------------------------------------------
HISTFILE="${HOME}/.zsh_history"
HISTSIZE=10000
SAVEHIST=10000
setopt hist_ignore_dups     # don't record a line identical to the one before
setopt hist_ignore_space    # a leading space keeps a command out of history
setopt share_history        # history is shared across concurrent shells

# --- Prompt config ------------------------------------------------------------
# p10k writes ~/.p10k.zsh the first time it runs its wizard. Absent on a fresh
# install: p10k prompts to configure itself on first interactive shell, which is
# the intended experience, not an error.
[[ -f "${HOME}/.p10k.zsh" ]] && source "${HOME}/.p10k.zsh"

# --- Local overrides ----------------------------------------------------------
# Somewhere to put machine-specific settings that isn't this file — this one is
# replaced wholesale by `hashiru update`.
[[ -f "${HOME}/.zshrc.local" ]] && source "${HOME}/.zshrc.local"
