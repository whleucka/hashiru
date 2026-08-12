#!/usr/bin/env bash
# migrate-desktop-config.sh — one-time move of desktop/tool config ownership
# from the personal dotfiles repo to Hashiru.
#
# Not a stage: this runs once per machine that was installed before config
# moved into Hashiru. Fresh installs get the new layout from 45-config.sh and
# never need this.
#
# What it does: unstows the Hashiru-owned packages from ~/.dotfiles, stows the
# copies in this repo, and verifies every link now resolves here. It does NOT
# touch the dotfiles repo's contents — deleting the migrated packages from
# there is a git operation on your repo, and it prints the command for you.
#
#   ./scripts/migrate-desktop-config.sh [--dry-run]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

script_start "migrate-desktop-config.sh"

readonly DOTFILES_DIR="${HOME}/.dotfiles"
readonly STOW_DIR="${HASHIRU_ROOT}/stow"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

run() {
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log_info "[dry-run] $*"
    else
        "$@"
    fi
}

# --- Preflight ----------------------------------------------------------------

# Unstowing removes ~/.config/hypr, ~/.config/waybar and friends for the few
# seconds before the new links land. Doing that under the compositor reading
# those very paths is how you end up with a half-configured session and no
# terminal to fix it from. Run from a TTY with Hyprland stopped.
# --dry-run changes nothing, so it is allowed (and useful) inside a session.
if pgrep -x Hyprland &>/dev/null; then
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log_warn "Hyprland is running — fine for --dry-run, but the real run must happen from a TTY."
    else
        log_error "Hyprland is running — this migration removes its config directory mid-flight."
        log_error "Log out to a TTY (Ctrl+Alt+F2), then run this again."
        exit 1
    fi
fi

if [[ ! -d "${DOTFILES_DIR}" ]]; then
    log_error "Dotfiles repo not found at ${DOTFILES_DIR} — nothing to migrate from"
    exit 1
fi

if [[ ! -d "${STOW_DIR}" ]]; then
    log_error "Hashiru stow tree not found at ${STOW_DIR}"
    exit 1
fi

command -v stow &>/dev/null || { log_error "GNU Stow is not installed"; exit 1; }

# A dirty dotfiles tree means uncommitted edits to config that is about to be
# unstowed — those edits are only recoverable from the dotfiles repo, so make
# the user deal with them before anything moves.
if [[ -n "$(git -C "${DOTFILES_DIR}" status --porcelain 2>/dev/null)" ]]; then
    log_error "${DOTFILES_DIR} has uncommitted changes — commit or stash them first."
    log_error "They may be edits to the very config this migrates."
    exit 1
fi

# Only migrate packages that actually exist on both sides.
PACKAGES=()
for dir in "${STOW_DIR}"/*/; do
    pkg="${dir%/}"
    pkg="${pkg##*/}"
    if [[ -d "${DOTFILES_DIR}/${pkg}" ]]; then
        PACKAGES+=("${pkg}")
    else
        log_info "Skipping ${pkg} — not present in ${DOTFILES_DIR} (nothing to unstow)"
    fi
done

if [[ ${#PACKAGES[@]} -eq 0 ]]; then
    log_success "Nothing to migrate — no Hashiru-owned packages left in ${DOTFILES_DIR}"
    exit 0
fi

log_info "Migrating ${#PACKAGES[@]} packages: ${PACKAGES[*]}"

# --- Preflight: real files sitting where stow wants symlinks --------------------

# Config that Hashiru now stows was, on older installs, written as plain files
# by the stage scripts themselves — ~/.zprofile and
# ~/.config/environment.d/10-hashiru.conf both came from an earlier
# 30-desktop.sh. Stow refuses to replace a real file with a symlink, so each
# one aborts a package mid-run. Find them all up front: discovering them one
# crash at a time leaves the desktop unstowed for far longer than necessary.
#
# Only regular files collide. An existing *directory* is fine — stow descends
# into it and links the leaves (which is how ~/.config/environment.d can hold
# both this file and unrelated ones like fcitx.conf).
#
# stow_conflicts (lib/common.sh) does the detection, including skipping files
# reached through a symlinked ancestor — those belong to a stow package already
# and vanish when the unstow step removes the ancestor link.
CONFLICTS=()
for pkg in "${PACKAGES[@]}"; do
    while IFS= read -r line; do
        [[ -n "${line}" ]] && CONFLICTS+=("${line}")
    done < <(stow_conflicts "${STOW_DIR}/${pkg}")
done

if [[ ${#CONFLICTS[@]} -gt 0 ]]; then
    log_error "${#CONFLICTS[@]} real file(s) sit where Hashiru's config needs to go."
    log_error "Stow cannot replace a real file with a symlink. Compare each against"
    log_error "Hashiru's copy, then move it aside and re-run this script."
    log_error ""
    for pair in "${CONFLICTS[@]}"; do
        target="${pair%%|*}"
        src="${pair#*|}"
        if cmp -s "${target}" "${src}"; then
            # Identical content: nothing to preserve, just in stow's way.
            log_error "  ${target/#${HOME}/\~}  (identical to Hashiru's copy — safe to delete)"
            log_error "      rm '${target}'"
        else
            log_error "  ${target/#${HOME}/\~}  (differs from Hashiru's copy)"
            log_error "      diff '${target}' '${src}'"
            log_error "      mv '${target}' '${target}.pre-hashiru'"
        fi
    done
    log_error ""
fi

# Dangling symlinks anywhere in the target tree break stow's ownership analysis,
# and it refuses to act — even on packages that have nothing to do with the
# broken link. ~/.config/tmux surviving the tmux -> herdr switch (599134f) is
# the canonical example: a dead link to a package that no longer exists in the
# dotfiles repo, which blocks an unrelated `stow hyprland`. Cheap to detect, and
# the alternative is an error message that names the wrong package.
DEAD=()
while IFS= read -r -d '' link; do
    [[ -e "${link}" ]] && continue
    target="$(readlink "${link}")"
    case "${target}" in
        ../*|*hashiru*|*.dotfiles*) DEAD+=("${link}") ;;
    esac
done < <(find "${HOME}/.config" -maxdepth 2 -type l -print0 2>/dev/null)

if [[ ${#DEAD[@]} -gt 0 ]]; then
    log_error "${#DEAD[@]} dangling symlink(s) in ~/.config will make stow refuse to act,"
    log_error "including on packages unrelated to the broken link. Remove them, then re-run:"
    log_error ""
    for link in "${DEAD[@]}"; do
        log_error "  ${link/#${HOME}/\~} -> $(readlink "${link}")"
        log_error "      rm '${link}'"
    done
    log_error ""
fi

# Both classes are reported before stopping — fixing one and immediately
# tripping the other is the failure mode this preflight exists to remove.
if [[ ${#CONFLICTS[@]} -gt 0 || ${#DEAD[@]} -gt 0 ]]; then
    log_error "Nothing has been changed — your config is still stowed from ${DOTFILES_DIR}."
    exit 1
fi

# --- Warn about content drift --------------------------------------------------

# The copies in this repo were taken at some point in the past; the dotfiles
# copy may have moved on since. Report the difference rather than silently
# preferring one — Hashiru's copy is what will be live afterwards.
for pkg in "${PACKAGES[@]}"; do
    if ! diff -rq "${DOTFILES_DIR}/${pkg}" "${STOW_DIR}/${pkg}" &>/dev/null; then
        log_warn "${pkg}: dotfiles and Hashiru copies differ — Hashiru's copy wins after migration"
        log_warn "  compare: diff -ru ${DOTFILES_DIR}/${pkg} ${STOW_DIR}/${pkg}"
    fi
done

# --- Unstow from dotfiles ------------------------------------------------------

cd "${DOTFILES_DIR}" || { log_error "Failed to cd into ${DOTFILES_DIR}"; exit 1; }

UNSTOWED=()
for pkg in "${PACKAGES[@]}"; do
    log_info "Unstowing from dotfiles: ${pkg}"
    if run stow -D --target="${HOME}" "${pkg}"; then
        UNSTOWED+=("${pkg}")
    else
        log_error "Failed to unstow ${pkg} from ${DOTFILES_DIR} — stopping before anything else moves"
        log_error "Already unstowed (restore with: cd ${DOTFILES_DIR} && stow --target=${HOME} ${UNSTOWED[*]}): ${UNSTOWED[*]:-none}"
        exit 1
    fi
done

# --- Stow from Hashiru ---------------------------------------------------------

cd "${STOW_DIR}" || { log_error "Failed to cd into ${STOW_DIR}"; exit 1; }

FAILED=()
for pkg in "${PACKAGES[@]}"; do
    log_info "Stowing from Hashiru: ${pkg}"
    run stow --restow --target="${HOME}" "${pkg}" || FAILED+=("${pkg}")
done

if [[ ${#FAILED[@]} -gt 0 ]]; then
    log_error "Failed to stow: ${FAILED[*]}"
    log_error "Your desktop config is currently unstowed. Either resolve the conflicts"
    log_error "(usually a leftover real file in ~/.config) and re-run, or roll back:"
    log_error "  cd ${DOTFILES_DIR} && stow --target=${HOME} ${PACKAGES[*]}"
    exit 1
fi

# --- Verify --------------------------------------------------------------------

if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_success "Dry run complete — nothing was changed"
    exit 0
fi

log_info "Verifying links resolve into ${HASHIRU_ROOT}"
BAD=0
while IFS= read -r -d '' link; do
    target="$(readlink -f "${link}" 2>/dev/null || true)"
    if [[ -z "${target}" || ! -e "${target}" ]]; then
        log_error "dangling link: ${link}"
        BAD=$(( BAD + 1 ))
    elif [[ "${target}" == "${DOTFILES_DIR}"/* ]]; then
        log_error "still points at dotfiles: ${link} -> ${target}"
        BAD=$(( BAD + 1 ))
    fi
done < <(find "${HOME}/.config" -maxdepth 1 -type l -print0)

# Spot-check the one that matters most.
if [[ "$(readlink -f "${HOME}/.config/hypr" 2>/dev/null)" == "${STOW_DIR}"/* ]]; then
    log_success "~/.config/hypr -> ${STOW_DIR}/hyprland/.config/hypr"
else
    log_error "~/.config/hypr does not resolve into ${STOW_DIR}"
    BAD=$(( BAD + 1 ))
fi

if [[ "${BAD}" -gt 0 ]]; then
    log_error "Verification found ${BAD} problem(s) — review before logging back in."
    log_error "Roll back with: cd ${DOTFILES_DIR} && stow --target=${HOME} ${PACKAGES[*]}"
    exit 1
fi

log_success "Migration complete — desktop config now served from ${STOW_DIR}"
log_info ""
log_info "Next: remove the migrated packages from your dotfiles repo, so the two"
log_info "copies can't drift. Nothing here depends on them any more:"
log_info ""
log_info "  cd ${DOTFILES_DIR} && git rm -r ${PACKAGES[*]} && git commit -m 'config moved to hashiru'"
log_info ""
log_info "Then log back in and check the desktop before pushing that commit."

script_end "migrate-desktop-config.sh"
