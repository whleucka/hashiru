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
