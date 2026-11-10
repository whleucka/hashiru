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
#
# What Hashiru owns, it owns completely: there is no layering *inside* stow/.
# The seam is one level out, in ~/.config/hashiru/, which this stage creates and
# then leaves alone — see https://hashiru.williamhleucka.com/docs/configuration.html.
# hashiru: offline
#
# Declares that this stage touches no network, so install.sh skips its up-front
# connectivity check when every selected stage is marked. Unmarked is the safe
# default — a new stage that fetches something still gets the check.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

script_start "45-config.sh"

readonly STOW_DIR="${HASHIRU_ROOT}/stow"

if [[ ! -d "${STOW_DIR}" ]]; then
    log_error "Stow directory not found: ${STOW_DIR}"
    exit 1
fi

# The only thing in this stage that reaches the network, and only on a machine
# that has never installed stow — which is why the stage is still marked
# offline, and asks here instead.
if ! command -v stow &>/dev/null; then
    log_info "Installing GNU Stow"
    require_network
    sudo pacman -S --needed --noconfirm stow
fi

# useradd seeds /etc/skel into every new home and stow refuses to replace a
# real file with a symlink, so a pristine skel copy would block a package on
# every fresh install. Drop them only while still byte-identical to skel (a
# pristine copy carries no user data); anything modified is left alone for
# stow to warn about.
for f in .zprofile .bash_profile .bashrc; do
    if [[ -f "${HOME}/${f}" && ! -L "${HOME}/${f}" ]] && cmp -s "${HOME}/${f}" "/etc/skel/${f}"; then
        rm "${HOME}/${f}"
        log_info "Removed pristine skel file blocking stow: ~/${f}"
    fi
done

# Directories that third-party installers write into must be real, not stow
# tree-folds. When a package's directory doesn't exist in $HOME, stow links the
# directory itself rather than its contents — so ~/.local/bin would become a
# symlink into this repo, and anything later dropping a binary there (cargo, pip
# --user, third-party install scripts) would write *inside the git checkout*.
# That leaves the tree permanently dirty, which makes `hashiru update` refuse to
# run. Pre-creating the directory forces stow to link the files individually and
# leaves the directory itself writable by everyone else.
#
# Also unfolds a directory an earlier run already turned into a link, so this is
# a fix on existing machines and not just on fresh installs.
if [[ -L "${HOME}/.local/bin" ]] \
    && [[ "$(readlink -f "${HOME}/.local/bin")" == "${STOW_DIR}"/* ]]; then
    folded="$(readlink -f "${HOME}/.local/bin")"
    rm "${HOME}/.local/bin"
    mkdir -p "${HOME}/.local/bin"
    log_info "Unfolded stow-linked ~/.local/bin so installers can write into it"

    # Rescue anything an installer already wrote *through* the old link into the
    # checkout. Without this the file is simply re-stowed on the next line and
    # the tree stays dirty, so `hashiru update` would keep refusing to run.
    # Untracked-only: never relocate a file that legitimately belongs to Hashiru.
    while IFS= read -r leaked; do
        [[ -n "${leaked}" ]] || continue
        mv "${folded}/${leaked}" "${HOME}/.local/bin/${leaked}"
        log_warn "Moved ${leaked} out of the checkout into ~/.local/bin (an installer had written it through the old stow link)"
    done < <(git -C "${folded}" ls-files --others --exclude-standard . 2>/dev/null)
fi
mkdir -p "${HOME}/.local/bin"

# Same reasoning for ~/.claude/skills: Claude Code writes skills, plugins and
# state under ~/.claude, so the directory that holds them must be real. If stow
# folded it, a skill added later would be written into this checkout and leave
# the tree dirty. ~/.claude itself is created too, because it does not exist on
# a machine that has never run Claude Code.
mkdir -p "${HOME}/.claude/skills"

# And ~/.config/snappy-switcher: a theme of your own goes in its themes/, and
# snappy-install-config copies the stock ones there. Folded, both would land in
# this checkout.
mkdir -p "${HOME}/.config/snappy-switcher"

# herdr was a Hashiru stow package until it was dropped in favour of kitty's
# own tabs and splits. Removing a package from stow/ does not unstow it: the
# links it placed stay behind in $HOME, now pointing at files that no longer
# exist. Clear the ones that point into this checkout and nothing else —
# herdr's own runtime state in ~/.config/herdr is the user's, as is herdr
# itself if they keep using it.
# Compared canonically on both sides: the checkout may be reached through a
# symlink (HASHIRU_ROOT keeps whatever path it was run by), while readlink -m
# always resolves to the real one.
herdr_cfg="${HOME}/.config/herdr"
herdr_pkg="$(readlink -m "${STOW_DIR}")/herdr/"
if [[ -L "${herdr_cfg}" && "$(readlink -m "${herdr_cfg}")" == "${herdr_pkg}"* ]]; then
    rm "${herdr_cfg}"
    log_info "Removed stale stow link ~/.config/herdr (herdr is no longer part of Hashiru)"
elif [[ -d "${herdr_cfg}" ]]; then
    while IFS= read -r -d '' link; do
        [[ "$(readlink -m "${link}")" == "${herdr_pkg}"* ]] || continue
        rm "${link}"
        log_info "Removed stale stow link ${link/#${HOME}/\~} (herdr is no longer part of Hashiru)"
    done < <(find "${herdr_cfg}" -type l -print0)
    rmdir "${herdr_cfg}/scripts" 2>/dev/null || true
fi

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

    # --no-folding for `bin` and `claude`, because ~/.local/bin and
    # ~/.claude/skills are both written into by something other than stow:
    # pipx, npm and third-party install scripts drop binaries in the first, and
    # Claude Code writes its own skills into the second. Stow must own the
    # individual links and never the directory, or those writes land in this
    # checkout. The mkdirs above already guarantee that by making the
    # directories exist first; this states the invariant at the call site too,
    # so it holds even if those guards are ever reordered or a directory is
    # missing.
    stow_args=(--restow --target="${HOME}")
    if [[ "${dir}" == "bin" || "${dir}" == "claude" ]]; then
        stow_args+=(--no-folding)
    fi

    log_info "Stowing: ${dir}"
    if stow "${stow_args[@]}" "${dir}"; then
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

# Directories the desktop expects to exist. grim writes screenshots here and
# will not create the path itself, so the keybind silently does nothing without
# it. This was stage 40, which existed solely to run this one line — a stage
# number is permanent, and this did not warrant one.
ensure_dir "${HOME}/Pictures/Screenshots"

# -----------------------------------------------------------------------------
# Machine-local override tree
# -----------------------------------------------------------------------------
# Everything stowed above belongs to Hashiru and is restowed on every update, so
# anything specific to *this* machine has to live outside the repo.
# ~/.config/hashiru is that place: this stage creates the directories and then
# never touches what is in them.
#
# Created empty rather than left to the user, because an override mechanism
# nobody can find is not a feature. What each accepts is on the site, under
# configuration: https://hashiru.williamhleucka.com/docs/configuration.html
for _dir in hypr kitty waybar; do
    ensure_dir "${HASHIRU_CONFIG_DIR}/${_dir}"
done
unset _dir

# waybar's style.css imports this one unconditionally, and GTK logs a CSS error
# for an @import that resolves to nothing — so the file must exist even while
# empty. Created once; never overwritten, or an update would eat the contents.
if [[ ! -e "${HASHIRU_CONFIG_DIR}/waybar/style.css" ]]; then
    # Every line is a recognisable CSS comment so doctor's "is this file empty?"
    # test (which allows /*, *, // and blanks) reports it as unused rather than
    # as an override the user chose.
    printf '%s\n' \
        "/* Machine-local waybar styling. Cascades over the shipped style.css." \
        " * Nothing in Hashiru ever overwrites this file. */" \
        > "${HASHIRU_CONFIG_DIR}/waybar/style.css"
    log_info "Created empty waybar override: ${HASHIRU_CONFIG_DIR}/waybar/style.css"
fi

# kitty.conf starts every kitty in this session (startup_session). Without it
# the first tab sits outside any session, tab_bar_filter hides nothing, and
# CTRL+SHIFT+\ has nowhere to switch back to — so ship a minimal one: a single
# tab, a shell in ~. Same rule as above: created once, never overwritten, since
# saving the session (CTRL+SHIFT+W) writes the user's own layout into it.
ensure_dir "${HASHIRU_CONFIG_DIR}/kitty/sessions"
if [[ ! -e "${HASHIRU_CONFIG_DIR}/kitty/sessions/home.kitty-session" ]]; then
    printf '%s\n' \
        "# kitty's startup session (startup_session in kitty.conf): one tab, a" \
        "# shell in ~. Created once by Hashiru; nothing overwrites it. Save a" \
        "# layout over it with CTRL+SHIFT+W from inside the session." \
        "" \
        "new_tab" \
        "layout splits" \
        "cd ~" \
        "launch" \
        > "${HASHIRU_CONFIG_DIR}/kitty/sessions/home.kitty-session"
    log_info "Created default kitty session: ${HASHIRU_CONFIG_DIR}/kitty/sessions/home.kitty-session"
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
