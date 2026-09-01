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
# then leaves alone — see docs/internals.md, "Machine-local overrides".
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
# symlink into this repo, and anything later dropping a binary there (stage 60's
# herdr installer, cargo, pip --user) would write *inside the git checkout*.
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

# Same reasoning for ~/.config/herdr, for a different reason: nothing else
# installs into it, but herdr itself writes its logs, session state, plugin
# cache and API sockets *into its own config directory*. Folded, every one of
# those lands in this checkout, and the tree is dirty again the moment herdr
# runs. .gitignore had been chasing them one path at a time (*.log,
# session.json, .plugins.lock, plugins/) until a named session invented
# sessions/<name>/ and got committed. Unfolding fixes the class instead of the
# instance; the ignore rules stay as a second line of defence.
herdr_cfg="${HOME}/.config/herdr"
herdr_nofold=1
if [[ -L "${herdr_cfg}" ]] \
    && [[ "$(readlink -f "${herdr_cfg}")" == "${STOW_DIR}"/* ]]; then
    folded="$(readlink -f "${herdr_cfg}")"

    if pgrep -x herdr &>/dev/null; then
        # Never unfold underneath a running server. It bound its API socket
        # through this folded path, and the moment ~/.config/herdr becomes a
        # real directory that path stops resolving to the socket it is
        # listening on — the server keeps running, unreachable, and its open
        # log fd points at an inode no longer linked anywhere. This stage runs
        # unattended during `hashiru update`, quite possibly from a pane inside
        # that very server, so skipping is the only safe default. Staying
        # folded for one more run costs nothing: everything herdr writes there
        # is already in .gitignore.
        herdr_nofold=0
        log_warn "Stow tree-fold at ~/.config/herdr, so herdr writes its runtime state into this checkout"
        log_warn "Unfolding needs herdr stopped: exit every herdr client, then \`herdr server stop\`, then re-run this stage"
    else
        rm "${herdr_cfg}"
        mkdir -p "${herdr_cfg}"
        log_info "Unfolded stow-linked ~/.config/herdr so herdr's runtime state stays out of the checkout"

        # Rescue what herdr already wrote through the old link. This cannot
        # reuse the `ls-files --others --exclude-standard` filter ~/.local/bin
        # uses: herdr's runtime files are precisely the ones .gitignore lists,
        # so --exclude-standard would skip exactly what needs moving. Invert
        # the test instead — anything git does not track is herdr's.
        for leaked in "${folded}"/* "${folded}"/.*; do
            rel="${leaked##*/}"
            [[ "${rel}" == "." || "${rel}" == ".." || "${rel}" == "*" ]] && continue
            [[ -e "${leaked}" ]] || continue
            [[ -n "$(git -C "${folded}" ls-files -- "${rel}" 2>/dev/null)" ]] && continue

            # Sockets are dropped, not carried across. On the layout the ISO
            # installs, /opt and $HOME are separate btrfs subvolumes, so they
            # report different st_dev and rename(2) fails EXDEV; `mv` then
            # falls back to copying, and a copied unix socket is a fresh inode
            # with nothing listening on it — every connect() gets
            # ECONNREFUSED, which reads as "no herdr server is running" even
            # while one is. No server is running here (the guard above), so
            # the next one binds its own.
            if [[ -S "${leaked}" ]]; then
                rm -f "${leaked}"
                continue
            fi

            mv "${leaked}" "${herdr_cfg}/${rel}"
            log_warn "Moved ${rel} out of the checkout into ~/.config/herdr (herdr had written it through the old stow link)"
        done
    fi
fi
if [[ "${herdr_nofold}" == 1 ]]; then
    mkdir -p "${herdr_cfg}"
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

    # --no-folding for `bin`, `claude` and `herdr`, because ~/.local/bin,
    # ~/.claude/skills and ~/.config/herdr are all written into by something
    # other than stow: pipx, npm and third-party install scripts drop binaries
    # in the first, Claude Code writes its own skills into the second, and herdr
    # keeps its logs, session state and sockets in the third. Stow must own the
    # individual links and never the directory, or those writes land in this
    # checkout. The mkdirs above already guarantee that by making the
    # directories exist first; this states the invariant at the call site too,
    # so it holds even if those guards are ever reordered or a directory is
    # missing.
    #
    # herdr is the exception that can be deferred: if the guard above found a
    # running server it left the fold in place, and passing --no-folding here
    # would make stow do the unfold anyway — orphaning that server, and without
    # the rescue that moves its files out first. So it follows the same flag.
    stow_args=(--restow --target="${HOME}")
    if [[ "${dir}" == "bin" || "${dir}" == "claude" ]] \
        || [[ "${dir}" == "herdr" && "${herdr_nofold}" == 1 ]]; then
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
# nobody can find is not a feature. See docs/internals.md for what each accepts.
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
