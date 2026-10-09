# Hashiru — login shell profile (stow-managed: stow/hyprland/.zprofile)
#
# Interactive shell config lives in ~/.zshrc (stow/zsh). This file carries the
# desktop hand-off and the session environment Hyprland inherits.

# ~/.local/bin on PATH for the whole graphical session.
#
# This has to happen here, not in ~/.zshrc. Hyprland is exec'd below from a
# *login* shell, which never reads ~/.zshrc — that only runs for interactive
# shells. Without this the session PATH is whatever /etc/profile built, which
# adds /usr/local/bin but not ~/.local/bin, so every Hyprland keybind naming a
# command from stow/bin (`update-system`) or the herdr binary dies with
# "command not found" while the same name works fine once you're in a terminal.
# environment.d can't cover this either: it applies to systemd user services,
# and Hyprland is exec'd straight from this file.
[[ -d "${HOME}/.local/bin" ]] && export PATH="${HOME}/.local/bin:${PATH}"

# Auto-start Hyprland on TTY1 — except while first boot stands failed: the
# login notice (/etc/profile.d/hashiru-firstboot-failed.sh) has just said what
# broke and how to finish, and a desktop launched over it, half-installed,
# would hide both. The marker goes once the bootstrap completes.
if [[ -z "${DISPLAY}" && "${XDG_VTNR}" == 1 && -e /var/lib/hashiru/firstboot-failed ]]; then
    print -r -- "Hyprland not started while first boot is unfinished (start it anyway: start-hyprland)"
elif [[ -z "${DISPLAY}" && "${XDG_VTNR}" == 1 ]]; then
    if command -v start-hyprland &>/dev/null; then
        exec start-hyprland
    else
        exec Hyprland
    fi
fi
