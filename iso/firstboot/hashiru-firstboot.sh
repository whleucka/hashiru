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
REPO="/home/${HASHIRU_USER}/hashiru"

cleanup() { rm -f "${SUDOERS}"; }
trap cleanup EXIT

printf '%s ALL=(ALL) NOPASSWD: ALL\n' "${HASHIRU_USER}" > "${SUDOERS}"
chmod 440 "${SUDOERS}"

echo "==> Running Hashiru bootstrap as ${HASHIRU_USER}"
# HASHIRU_UNATTENDED=1 makes install.sh skip interactive prompts and auto-reboot
# into the finished system at the end. (sudo strips the environment, so the var
# is set inside the user's shell rather than inherited.)
if ! sudo -u "${HASHIRU_USER}" -H bash -lc "cd '${REPO}' && HASHIRU_UNATTENDED=1 ./install.sh"; then
  echo "!! Hashiru bootstrap failed — unit left enabled; will retry next boot." >&2
  exit 1
fi

systemctl disable hashiru-firstboot.service
echo "==> Hashiru bootstrap complete."
