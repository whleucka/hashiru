#!/usr/bin/env bash
# 15-grub.sh — GRUB tweaks (boot tune) and grub.cfg regeneration
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

# Set a key in /etc/default/grub, uncommenting/replacing or appending as needed
grub_opt() {
    local key="$1"    # option name, e.g. GRUB_INIT_TUNE
    local value="$2"  # value (will be quoted)
    local line="${key}=\"${value}\""
    if grep -q "^#\?${key}=" /etc/default/grub; then
        sudo sed -i "s|^#\?${key}=.*|${line}|" /etc/default/grub
    else
        echo "${line}" | sudo tee -a /etc/default/grub > /dev/null
    fi
}

# Mario Bros. mushroom power-up jingle on boot (needs pcspkr; silent without it)
GRUB_TUNE="1750 523 1 392 1 523 1 659 1 784 1 1047 1 784 1 415 1 523 1 622 1 831 1 622 1 831 1 1046 1 1244 1 1661 1 1244 1 466 1 587 1 698 1 932 1 1195 1 1397 1 1865 1 1397 1"

log_info "Setting GRUB_INIT_TUNE"
grub_opt "GRUB_INIT_TUNE" "${GRUB_TUNE}"

log_info "Regenerating grub.cfg"
sudo grub-mkconfig -o /boot/grub/grub.cfg

script_end "15-grub.sh"
