# Hashiru — login shell profile (stow-managed: stow/hyprland/.zprofile)
#
# Personal shell config lives in ~/.zshrc (your dotfiles). This file carries
# only the desktop hand-off, because the desktop is Hashiru's to own.

# Auto-start Hyprland on TTY1
if [[ -z "${DISPLAY}" && "${XDG_VTNR}" == 1 ]]; then
    if command -v start-hyprland &>/dev/null; then
        exec start-hyprland
    else
        exec Hyprland
    fi
fi
