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

cleanup() { rm -f "${SUDOERS}"; }
trap cleanup EXIT

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
  exit 1
fi

# Disable the unit BEFORE rebooting so it never runs a second time. The bootstrap
# itself no longer reboots (see 99-apps.sh) — the reboot lives here, after the
# disable, so the disable can't be pre-empted by an in-bootstrap reboot. The EXIT
# trap (sudoers cleanup) still fires before the machine goes down.
systemctl disable hashiru-firstboot.service
# Also drop the env file: ConditionPathExists then blocks the unit for good,
# even if something re-enables it later.
rm -f /etc/hashiru-firstboot.env
echo "==> Hashiru bootstrap complete — rebooting into the finished system."
systemctl reboot
