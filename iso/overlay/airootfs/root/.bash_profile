# Hashiru live: auto-launch the installer on the main console (tty1).
# Mirror of .zprofile in case the live root shell is bash rather than zsh.
if [[ "$(tty)" == "/dev/tty1" ]]; then
    /root/stage0.sh
fi
