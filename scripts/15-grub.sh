#!/usr/bin/env bash
# 15-grub.sh — grub.cfg regeneration
# hashiru: offline
#
# Declares that this stage touches no network, so install.sh skips its up-front
# connectivity check when every selected stage is marked. Unmarked is the safe
# default — a new stage that fetches something still gets the check.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

script_start "15-grub.sh"

# Skip cleanly if GRUB isn't the bootloader (e.g. systemd-boot)
if [[ ! -f /etc/default/grub ]]; then
    log_warn "/etc/default/grub not found — skipping GRUB configuration"
    script_end "15-grub.sh"
    exit 0
fi

# This stage used to set GRUB_INIT_TUNE to the Mario power-up jingle. It never
# played on real machines (the beep needs a PC speaker the kernel drives), so
# it went. Replay is the only migration there is: a machine that still carries
# that exact line gets the stock commented-out default back. A tune anyone set
# themselves doesn't match, so it is left alone.
readonly OLD_TUNE="1750 523 1 392 1 523 1 659 1 784 1 1047 1 784 1 415 1 523 1 622 1 831 1 622 1 831 1 1046 1 1244 1 1661 1 1244 1 466 1 587 1 698 1 932 1 1195 1 1397 1 1865 1 1397 1"
if grep -qxF "GRUB_INIT_TUNE=\"${OLD_TUNE}\"" /etc/default/grub; then
    log_info "Removing the old GRUB boot tune"
    sudo sed -i "s|^GRUB_INIT_TUNE=\"${OLD_TUNE}\"\$|#GRUB_INIT_TUNE=\"480 440 1\"|" /etc/default/grub
fi

# Two seconds on a fresh machine, but grub-btrfs and a few dozen snapper
# snapshots turn this into the second-longest step in a run, and it is the only
# other unlabelled one.
#
# grub-btrfsd races this. Stage 10's pacman -Syu makes snap-pac take a pre/post
# snapshot, the daemon sees it and runs 41_snapshots-btrfs on its own, and a
# grub-mkconfig started in that window runs the same script against the same
# temp mount and fails. So wait for the daemon's run to finish first, and if a
# snapshot still lands mid-run, wait again and retry once.
wait_for_grub_btrfsd() {
    local i
    for (( i = 0; i < 30; i++ )); do
        pgrep -f /etc/grub.d/41_snapshots-btrfs >/dev/null || return 0
        sleep 1
    done
}

log_info "Regenerating grub.cfg"
progress_set "regenerating grub.cfg"
wait_for_grub_btrfsd
if ! sudo grub-mkconfig -o /boot/grub/grub.cfg; then
    log_warn "grub-mkconfig failed (grub-btrfsd may have been running) — retrying"
    sleep 2
    wait_for_grub_btrfsd
    sudo grub-mkconfig -o /boot/grub/grub.cfg
fi

script_end "15-grub.sh"
