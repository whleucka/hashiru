#!/usr/bin/env bash
# 60-herdr.sh — Install the herdr binary
#
# Hashiru owns herdr: it is the multiplexer the terminal launches, five scripts
# in stow/herdr/.config/herdr/scripts drive it (herdr-relayout, -nav, -route,
# -split-run, -swap), and its config is a Hashiru stow package placed by
# 45-config.sh. This stage installs the binary — it is where third-party user
# binaries land — plus the two things herdr generates for Claude Code (its
# state-reporting hooks and its agent skill) and the Auto Title plugin.
#
# This stage used to clone and stow a personal dotfiles repo. It no longer does,
# and Hashiru no longer knows what dotfiles are: everything it stows lives in
# stow/ and is placed by 45-config.sh. The dividing line is now simply whether a
# thing is needed on a machine Hashiru did not build — an editor config is, a
# shell prompt and a file manager theme are not.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

script_start "60-herdr.sh"

# Install herdr (terminal workspace manager; replaces tmux/TPM). There is no
# AUR package, so use the official installer — it downloads the right binary for
# the platform and drops it on PATH at ~/.local/bin/herdr. Runs as the invoking
# user (not root) so it lands in this home; skip if already present. No plugin
# bootstrap or systemd unit is needed; herdr is the multiplexer, launched
# directly by the terminal.
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

# The rest needs the binary; a failed install above has already warned.
herdr_bin="$(command -v herdr || echo "${HERDR_BIN}")"
if [[ ! -x "${herdr_bin}" ]]; then
    script_end "60-herdr.sh"
    exit 0
fi

# Claude Code integration — hooks in ~/.claude/settings.json that report the
# agent's real state and session to herdr. Without them herdr guesses state by
# scraping the screen, and `resume_agents_on_restore` in config.toml cannot
# resume Claude panes at all, because it needs the session refs the hooks
# report. The installer edits settings.json in place (a real file, not stowed),
# so it is only rerun when status says missing or outdated. Skipped on a machine
# without Claude Code.
if command -v claude &>/dev/null; then
    claude_status="$("${herdr_bin}" integration status 2>/dev/null | grep '^claude:' || true)"
    claude_outdated="$("${herdr_bin}" integration status --outdated-only 2>/dev/null | grep '^claude:' || true)"
    # Status reads "claude: current (vN)" when installed, "claude: not installed
    # (...)" when not; outdated ones are listed by --outdated-only.
    if [[ -n "${claude_status}" && "${claude_status}" != "claude: not installed"* && -z "${claude_outdated}" ]]; then
        log_info "herdr Claude integration already installed"
    elif "${herdr_bin}" integration install claude; then
        log_success "herdr Claude integration installed"
    else
        log_warn "herdr Claude integration failed (retry: herdr integration install claude)"
    fi
fi

# herdr ships an agent skill that teaches Claude to drive panes, tabs and other
# agents through the herdr CLI. It is generated rather than stowed so it always
# matches the installed binary's commands; rewritten only when it changes.
# ~/.claude/skills is a real directory (45-config.sh), so this lands in $HOME,
# not the checkout.
if [[ -d "${HOME}/.claude" ]]; then
    skill_dir="${HOME}/.claude/skills/herdr"
    skill_new="$("${herdr_bin}" --skill 2>/dev/null || true)"
    if [[ -z "${skill_new}" ]]; then
        log_warn "herdr --skill printed nothing; herdr skill not updated"
    elif [[ "$(cat "${skill_dir}/SKILL.md" 2>/dev/null)" == "${skill_new}" ]]; then
        log_info "herdr skill up to date"
    else
        mkdir -p "${skill_dir}"
        printf '%s\n' "${skill_new}" > "${skill_dir}/SKILL.md"
        log_success "herdr skill written to ${skill_dir}"
    fi
fi

# Auto Title: names tabs from what is running in them. herdr installs plugins
# from GitHub into ~/.config/herdr/plugins (a real directory, see 45-config.sh)
# and builds this one with go, which dev.txt only brings in at stage 99, so it
# is installed here first. Installed only when absent: a plugin the user has
# disabled is still listed, and stays disabled.
readonly AUTO_TITLE_ID="herdr.auto-title"
readonly AUTO_TITLE_REPO="kryptamine/herdr-auto-title"
if "${herdr_bin}" plugin list 2>/dev/null | grep -q "^- ${AUTO_TITLE_ID} "; then
    log_info "herdr plugin ${AUTO_TITLE_ID} already installed"
else
    is_pkg_installed go || sudo pacman -S --needed --noconfirm go
    if "${herdr_bin}" plugin install --yes "${AUTO_TITLE_REPO}" </dev/null; then
        log_success "herdr plugin ${AUTO_TITLE_ID} installed"
    else
        log_warn "herdr plugin ${AUTO_TITLE_ID} failed (retry: herdr plugin install ${AUTO_TITLE_REPO})"
    fi
fi

script_end "60-herdr.sh"
