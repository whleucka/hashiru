# Hashiru live: auto-launch the installer on the main console (tty1).
# Other TTYs / SSH get a plain root shell for debugging.
if [[ "$(tty)" == "/dev/tty1" ]]; then
    /root/stage0.sh
fi
