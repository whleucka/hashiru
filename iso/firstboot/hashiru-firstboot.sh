#!/usr/bin/env bash
# hashiru-firstboot.sh — runs once on first boot (as root, via systemd).
#
# Hashiru's install.sh must run as the unprivileged user and uses sudo. A
# systemd unit has no TTY to type a sudo password into, so we grant the user
# temporary passwordless sudo for the duration of the bootstrap and remove it
# afterwards. On success the unit disables itself; on failure it stays enabled
# so the next boot retries.
set -euo pipefail

: "${HASHIRU_USER:?HASHIRU_USER not set}"
SUDOERS="/etc/sudoers.d/hashiru-firstboot"
# Permanent location — see install-firstboot.sh. ~/hashiru is a symlink here.
REPO="/opt/hashiru"
USER_UID="$(id -u "${HASHIRU_USER}")"

GETTY_DROPIN="/etc/systemd/system/getty@tty1.service.d/10-hashiru-firstboot.conf"
# Set just before `systemctl reboot`, so the trap can tell "we're on our way
# down" from "we died" — the two want opposite things done to tty1.
REBOOTING=0

# Hand tty1 back to a login prompt. On the success path the machine reboots
# into the finished system and stage 30's autologin takes over, so this only
# matters when the bootstrap failed: without it the drop-in would still be
# blocking the getty and there'd be no way to log in on tty1 and read what
# went wrong.
restore_getty() {
  rm -f "${GETTY_DROPIN}"
  systemctl daemon-reload
  systemctl start --no-block getty@tty1.service || true
}

cleanup() {
  rm -f "${SUDOERS}"
  (( REBOOTING )) || restore_getty
}
trap cleanup EXIT

# The unit has just hung up and reset tty1 (TTYVHangup/TTYReset), so the screen
# is whatever the kernel last left on it. Clear it and put Hashiru's name up
# before the bootstrap starts scrolling, so first boot reads as a deliberate
# install step rather than a machine talking to itself. Guarded: /dev/tty1
# doesn't exist on a serial-console or headless boot, where the journal is the
# only output that matters.
if [[ -w /dev/tty1 ]]; then
  {
    printf '\033[H\033[2J'
    cat <<'BANNER'
==================================================
        ▓░ ░ ▓▒▀▓ ▓█▀▀ ▓░ ░ ▓░ ▓█▀▓ ▓█ ░
        ▒▓▀▒ ▒░▄▒ ▀▀▒▓ ▒▓▀▒ ▒▒ ▒▓▄▀ ▒▓ ▒
        ░  ▓ ░  ░ ▄▄░▒ ░  ▓ ░▓ ░▒ ▒ ░▒▄▓
                  First boot
==================================================
Setting up your Hyprland desktop. This downloads
and builds a fair amount, so it takes a while —
leave it alone and it will reboot when it's done.

Progress is logged below and to the journal
(journalctl -u hashiru-firstboot).
==================================================
BANNER
    echo
  } > /dev/tty1
fi

printf '%s ALL=(ALL) NOPASSWD: ALL\n' "${HASHIRU_USER}" > "${SUDOERS}"
chmod 440 "${SUDOERS}"

# Several stages call `systemctl --user` (PipeWire sockets, wireplumber).
# Those need a running per-user systemd instance and D-Bus session bus, which
# normally exist only inside a login session — and this unit runs the bootstrap
# via `sudo -u` from a *system* service, where there is none. Enable lingering
# so systemd starts the user manager now, then wait for its runtime bus socket
# before handing off.
echo "==> Enabling lingering user systemd instance for ${HASHIRU_USER}"
loginctl enable-linger "${HASHIRU_USER}"
for _ in $(seq 1 30); do
  [[ -S "/run/user/${USER_UID}/bus" ]] && break
  sleep 1
done
if [[ ! -S "/run/user/${USER_UID}/bus" ]]; then
  echo "!! user D-Bus session bus never appeared at /run/user/${USER_UID}/bus" >&2
  exit 1
fi

echo "==> Running Hashiru bootstrap as ${HASHIRU_USER}"
# Pass the user-session env so `systemctl --user` can connect, plus
# HASHIRU_UNATTENDED=1 (skip prompts, auto-reboot at the end). These are set
# inside the user's shell because sudo strips the environment.
if ! sudo -u "${HASHIRU_USER}" -H bash -lc "
    export XDG_RUNTIME_DIR='/run/user/${USER_UID}'
    export DBUS_SESSION_BUS_ADDRESS='unix:path=/run/user/${USER_UID}/bus'
    cd '${REPO}' && HASHIRU_UNATTENDED=1 ./install.sh
  "; then
  echo "!! Hashiru bootstrap failed — unit left enabled; will retry next boot." >&2
  echo "!! Log in below and check: journalctl -u hashiru-firstboot" >&2
  echo "!! Or resume a partial run: cd ${REPO} && ./install.sh --from <stage>" >&2
  exit 1
fi

# Disable the unit BEFORE rebooting so it never runs a second time. The bootstrap
# itself no longer reboots (see 99-apps.sh) — the reboot lives here, after the
# disable, so the disable can't be pre-empted by an in-bootstrap reboot. The EXIT
# trap (sudoers cleanup) still fires before the machine goes down.
systemctl disable hashiru-firstboot.service
# Also drop the env file: ConditionPathExists then blocks the unit for good,
# even if something re-enables it later. Dropping the getty drop-in alongside
# it keeps that gate honest — were the file left behind, anything that recreated
# the env file would silently suppress the tty1 login prompt as well.
rm -f /etc/hashiru-firstboot.env "${GETTY_DROPIN}"
echo "==> Hashiru bootstrap complete — rebooting into the finished system."
REBOOTING=1
systemctl reboot
