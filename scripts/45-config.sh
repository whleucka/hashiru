#!/usr/bin/env bash
# 45-config.sh — Stow Hashiru's own user config into $HOME
#
# Everything under stow/ is a GNU Stow package owned by Hashiru: the desktop
# (Hyprland, waybar, mako, ...), the config for every tool Hashiru installs,
# and the shell — prompt, aliases, functions, helper scripts.
#
# The test for what belongs here is whether you would want it on a machine
# Hashiru did not build. A shell prompt, a file manager theme and a terminal
# colour scheme all fail that test: they describe *this* machine, so Hashiru
# owns them outright and there is nothing to layer or negotiate. An editor
# config passes it, which is why nvim and vim are the only things left in a
# personal dotfiles repo — and Hashiru neither clones nor stows that repo.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

script_start "45-config.sh"

readonly STOW_DIR="${HASHIRU_ROOT}/stow"

if [[ ! -d "${STOW_DIR}" ]]; then
    log_error "Stow directory not found: ${STOW_DIR}"
    exit 1
fi

if ! command -v stow &>/dev/null; then
    log_info "Installing GNU Stow"
    sudo pacman -S --needed --noconfirm stow
fi

# useradd seeds /etc/skel into every new home and stow refuses to replace a
# real file with a symlink, so a pristine skel copy would block a package on
# every fresh install. Drop them only while still byte-identical to skel (a
# pristine copy carries no user data); anything modified is left alone for
# stow to warn about.
for f in .zprofile .bash_profile; do
    if [[ -f "${HOME}/${f}" && ! -L "${HOME}/${f}" ]] && cmp -s "${HOME}/${f}" "/etc/skel/${f}"; then
        rm "${HOME}/${f}"
        log_info "Removed pristine skel file blocking stow: ~/${f}"
    fi
done

# Clear real files sitting where stowed config needs to go. These come from
# older installs where the stage scripts wrote config directly — ~/.zprofile and
# ~/.config/environment.d/10-hashiru.conf were both plain files written by an
# earlier 30-desktop.sh, and stow refuses to replace a real file with a symlink.
#
# This resolves them rather than asking: the stage runs unattended on first
# boot, where aborting would fail the whole bootstrap over a file whose content
# Hashiru now owns anyway. Nothing is discarded unless it is byte-identical to
# the copy replacing it.
for pkgdir in "${STOW_DIR}"/*/; do
    while IFS='|' read -r target src; do
        [[ -n "${target}" ]] || continue
        if cmp -s "${target}" "${src}"; then
            rm "${target}"
            log_info "Removed redundant file blocking stow (identical to ours): ${target/#${HOME}/\~}"
        else
            backup="${target}.pre-hashiru"
            [[ -e "${backup}" ]] && backup="${target}.pre-hashiru.$(date +%s)"
            mv "${target}" "${backup}"
            log_warn "Backed up ${target/#${HOME}/\~} -> ${backup##*/} (Hashiru now owns this file)"
        fi
    done < <(stow_conflicts "${pkgdir}")
done

cd "${STOW_DIR}" || { log_error "Failed to cd into ${STOW_DIR}"; exit 1; }

log_info "Stowing Hashiru config from ${STOW_DIR} to ${HOME}"
stowed=0
failed=()
for dir in */; do
    dir="${dir%/}"
    [[ "${dir}" == .* ]] && continue

    log_info "Stowing: ${dir}"
    if stow --restow --target="${HOME}" "${dir}"; then
        stowed=$(( stowed + 1 ))
    else
        # Almost always a pre-existing real file, or a symlink pointing
        # somewhere else — commonly a package from an older setup that still
        # claims this path. Resolve it by hand, then re-run.
        log_warn "Failed to stow ${dir} — resolve the conflict, then: cd ${STOW_DIR} && stow --restow --target=${HOME} ${dir}"
        failed+=("${dir}")
    fi
done

if [[ ${#failed[@]} -gt 0 ]]; then
    log_warn "Config packages that did NOT stow: ${failed[*]}"
fi
log_success "Stowed ${stowed} config packages"

# bat only reads custom themes from its cache, and the themes arrive with the
# bat package stowed just above — so the rebuild belongs here, not with the
# user's dotfiles.
if command -v bat &>/dev/null; then
    log_info "Rebuilding bat cache for custom themes"
    bat cache --build
    log_success "bat cache rebuilt"
fi

# Put the management CLI on PATH. The ISO does this too, but a manual install
# never runs install-firstboot.sh — and `hashiru update` is how a machine stays
# current, so it should exist on every install regardless of how it got here.
if [[ -x "${HASHIRU_ROOT}/bin/hashiru" ]]; then
    sudo ln -sfn "${HASHIRU_ROOT}/bin/hashiru" /usr/local/bin/hashiru
    log_info "Linked /usr/local/bin/hashiru -> ${HASHIRU_ROOT}/bin/hashiru"
fi

# The stow links and the CLI symlink both point at wherever this checkout lives,
# so moving it later breaks the desktop. /opt/hashiru is the canonical home
# (what the ISO installs to); anywhere else works but is worth saying out loud
# once. Deliberately does NOT relocate itself — moving the tree out from under a
# running install is a far worse failure than a checkout in an odd place.
if [[ "${HASHIRU_ROOT}" != "/opt/hashiru" ]]; then
    log_info "Hashiru lives at ${HASHIRU_ROOT} (canonical location is /opt/hashiru)."
    log_info "Config symlinks now resolve there — re-run this stage if you move it."
fi

script_end "45-config.sh"
