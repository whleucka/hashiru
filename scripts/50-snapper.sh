#!/usr/bin/env bash
# 50-snapper.sh — Snapper snapshot configuration, grub-btrfs integration

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

script_start "50-snapper.sh"

# Check if root is btrfs
ROOT_FS=$(findmnt -n -o FSTYPE /)
if [[ "${ROOT_FS}" != "btrfs" ]]; then
    log_warn "Root filesystem is not btrfs (${ROOT_FS}) — skipping snapper setup"
    script_end "50-snapper.sh"
    exit 0
fi

# Create snapper config for root if it doesn't exist
if [[ ! -f /etc/snapper/configs/root ]]; then
    log_info "Creating snapper configuration for root"

    # Snapper expects /.snapshots to not exist when creating config
    # but we need it to be a btrfs subvolume mounted
    if [[ -d /.snapshots ]]; then
        # Check if it's already properly set up
        if findmnt /.snapshots &>/dev/null; then
            log_info "/.snapshots already mounted"
        fi
    fi

    sudo snapper -c root create-config /
    log_success "Snapper root config created"

    # Configure snapper for reasonable defaults
    log_info "Configuring snapper timeline settings"
    sudo snapper -c root set-config "TIMELINE_CREATE=yes"
    sudo snapper -c root set-config "TIMELINE_CLEANUP=yes"
    sudo snapper -c root set-config "TIMELINE_LIMIT_HOURLY=5"
    sudo snapper -c root set-config "TIMELINE_LIMIT_DAILY=7"
    sudo snapper -c root set-config "TIMELINE_LIMIT_WEEKLY=0"
    sudo snapper -c root set-config "TIMELINE_LIMIT_MONTHLY=0"
    sudo snapper -c root set-config "TIMELINE_LIMIT_YEARLY=0"
else
    log_info "Snapper root config already exists"
fi

# Enable snapper timers
enable_service "snapper-timeline.timer"
enable_service "snapper-cleanup.timer"

# Enable grub-btrfs for bootable snapshots
if is_pkg_installed "grub-btrfs"; then
    enable_service "grub-btrfsd.service"
    log_info "grub-btrfs daemon enabled — snapshots will appear in GRUB menu"
fi

# Allow user to use snapper without sudo for their own snapshots
SNAPPER_USER_CONFIG="/etc/snapper/configs/root"
if [[ -f "${SNAPPER_USER_CONFIG}" ]]; then
    CURRENT_USER="${USER}"
    if ! grep -q "ALLOW_USERS=\".*${CURRENT_USER}.*\"" "${SNAPPER_USER_CONFIG}"; then
        log_info "Adding ${CURRENT_USER} to snapper ALLOW_USERS"
        sudo sed -i "s/ALLOW_USERS=\"\"/ALLOW_USERS=\"${CURRENT_USER}\"/" "${SNAPPER_USER_CONFIG}"
    fi
fi

script_end "50-snapper.sh"
