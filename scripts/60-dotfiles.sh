#!/usr/bin/env bash
# 60-dotfiles.sh — Clone and stow user dotfiles, install herdr
#
# The dotfiles half is optional (see HASHIRU_DOTFILES_REPO in lib/common.sh).
# The herdr install at the bottom is not: Hashiru owns herdr — it is the
# multiplexer the terminal launches, and its config is a Hashiru stow package.
# It lives here only because this is where third-party user binaries land.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

script_start "60-dotfiles.sh"

# Which dotfiles, and where. Both come from lib/common.sh so they can be
# overridden per machine (hashiru.conf or the environment); an empty repo means
# this machine doesn't use dotfiles at all. Nothing Hashiru owns depends on
# them — its own config is stowed from stow/ by 45-config.sh.
readonly DOTFILES_REPO="${HASHIRU_DOTFILES_REPO}"
readonly DOTFILES_DIR="${HASHIRU_DOTFILES_DIR}"

# Packages Hashiru owns and stows itself in 45-config.sh. They were removed
# from the dotfiles repo when config moved into Hashiru, but a checkout on a
# machine that predates the move still carries them — skipping by name stops
# those from re-stowing over Hashiru's copies. Safe to keep indefinitely: a
# name listed here that no longer exists in the dotfiles repo costs nothing.
readonly HASHIRU_OWNED=(
    hyprland kitty thunar yazi bpytop chromium bat fzf ripgrep herdr
)

# Clone only when a repo is configured. An existing checkout is still stowed
# either way — someone who cloned their dotfiles by hand, or set no repo at all,
# gets them stowed without Hashiru needing to know where they came from.
if [[ -d "${DOTFILES_DIR}" ]]; then
    if [[ -n "${DOTFILES_REPO}" ]]; then
        # An existing checkout always wins over the configured URL, so say so when
        # they disagree: pointing HASHIRU_DOTFILES_REPO at a new repo while an old
        # checkout is in place pulls the old one forever and never clones the new.
        existing_origin="$(git -C "${DOTFILES_DIR}" remote get-url origin 2>/dev/null || true)"
        if [[ -n "${existing_origin}" && "${existing_origin}" != "${DOTFILES_REPO}" ]]; then
            log_warn "${DOTFILES_DIR} tracks ${existing_origin}, not the configured ${DOTFILES_REPO}"
            log_warn "Pulling the existing checkout. Move it aside to clone the configured repo instead."
        fi
        log_info "Dotfiles directory already exists, pulling latest"
        git -C "${DOTFILES_DIR}" pull --ff-only || log_warn "Could not pull dotfiles (local changes, no upstream, or diverged history)"
    else
        log_info "Using existing dotfiles at ${DOTFILES_DIR} (no repo configured — not pulling)"
    fi
elif [[ -n "${DOTFILES_REPO}" ]]; then
    log_info "Cloning dotfiles repository"
    # Guarded, unlike the rest of this stage's git calls used to be. Dotfiles are
    # not load-bearing — Hashiru's own config is already stowed by 45-config.sh —
    # but an unguarded clone dies under `set -e`, and install.sh aborts the whole
    # run on any stage failure. On the ISO path that means firstboot never
    # completes and retries every boot, so a typo'd URL or a rate-limited GitHub
    # would loop forever.
    #
    # The two env vars cover the two ways a clone can block forever with no tty
    # to answer it. GIT_TERMINAL_PROMPT=0 handles HTTPS credential prompts;
    # BatchMode=yes handles ssh's own prompts, which git's variable does not —
    # an unknown host key or an encrypted key passphrase. Note that an SSH repo
    # therefore needs its host key in known_hosts before firstboot; without it
    # the clone fails fast (warned, install continues) rather than auto-accepting
    # an unverified key.
    if GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="ssh -o BatchMode=yes" \
        git clone "${DOTFILES_REPO}" "${DOTFILES_DIR}"; then
        log_success "Dotfiles cloned to ${DOTFILES_DIR}"
    else
        log_warn "Could not clone ${DOTFILES_REPO} — continuing without dotfiles"
        log_warn "Hashiru's own config is unaffected (45-config.sh). Retry with: hashiru update 60"
        # git cleans up a failed clone, but be explicit — a partial directory here
        # would send the stow block below into a half-cloned tree.
        [[ -d "${DOTFILES_DIR}" ]] && rm -rf "${DOTFILES_DIR}"
    fi
else
    log_info "No dotfiles repo configured (HASHIRU_DOTFILES_REPO is empty) — skipping"
fi

# Reconcile the fallback .zshrc now — after the clone, but BEFORE stowing the
# dotfiles below.
#
# 45-config.sh already ran this, but back then the checkout didn't exist, so
# "does anything provide ~/.zshrc" could only be guessed and it stowed the
# fallback. The order here matters and is not interchangeable: this call removes
# that fallback when the dotfiles do ship a .zshrc, freeing the path for the stow
# loop. Running it *after* the loop instead means the fallback symlink is still
# in place when stow tries to claim ~/.zshrc, so the zsh package fails with
# "existing target is not owned by stow" — and then this call unstows the
# fallback anyway, leaving the machine with no .zshrc at all.
#
# When the dotfiles ship no .zshrc (or the clone failed), it keeps the fallback,
# which is what stops zsh being the login shell with nothing configuring it.
ensure_zshrc

if [[ -d "${DOTFILES_DIR}" ]]; then
    # Ensure stow is installed
    if ! command -v stow &>/dev/null; then
        log_info "Installing GNU Stow"
        sudo pacman -S --needed --noconfirm stow
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
        # Skip hidden directories. (No README/LICENSE guard: this loop iterates
        # */ — directories only — so those never appear.)
        [[ "${dir}" == .* ]] && continue

        skip=0
        for owned in "${HASHIRU_OWNED[@]}"; do
            if [[ "${dir}" == "${owned}" ]]; then
                log_info "Skipping ${dir} — owned by Hashiru (stow/${dir}, see 45-config.sh)"
                skip=1
                break
            fi
        done
        [[ "${skip}" -eq 1 ]] && continue

        log_info "Stowing: ${dir}"
        stow --restow --target="${HOME}" "${dir}" || log_warn "Failed to stow ${dir}"
    done

    log_success "Dotfiles stowed successfully"
fi

# Install herdr (terminal workspace manager; replaces tmux/TPM). There is no
# AUR package, so use the official installer — it downloads the right binary for
# the platform and drops it on PATH at ~/.local/bin/herdr. Runs as the invoking
# user (not root) so it lands in this home; skip if already present. Only the
# binary is installed here — herdr's config is a Hashiru-owned stow package
# (45-config.sh). No plugin bootstrap or systemd unit is needed; herdr is the
# multiplexer, launched directly by the terminal.
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
