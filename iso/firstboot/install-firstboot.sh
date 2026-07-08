#!/usr/bin/env bash
# install-firstboot.sh — runs INSIDE the freshly installed system (in chroot),
# invoked by archinstall's custom_commands at the end of the base install.
#
# It wires up a one-shot systemd unit that runs Hashiru's ./install.sh on the
# first real boot, as the target user. We can't run Hashiru here in the chroot:
# stages like default-shell, user services and TTY auto-login need a booted
# system and a live user session.
#
# Usage: install-firstboot.sh <username>
set -euo pipefail

HUSER="${1:?username required}"
REPO_SRC="/opt/hashiru"
USER_HOME="/home/${HUSER}"

install -Dm644 "${REPO_SRC}/iso/firstboot/hashiru-firstboot.service" \
  /etc/systemd/system/hashiru-firstboot.service
install -Dm755 "${REPO_SRC}/iso/firstboot/hashiru-firstboot.sh" \
  /usr/local/bin/hashiru-firstboot.sh

# Tell the first-boot unit which user to bootstrap as.
printf 'HASHIRU_USER=%s\n' "${HUSER}" > /etc/hashiru-firstboot.env

# Drop the repo in the user's home so the bootstrap runs from there.
cp -a "${REPO_SRC}" "${USER_HOME}/hashiru"
chown -R "${HUSER}:${HUSER}" "${USER_HOME}/hashiru"

systemctl enable hashiru-firstboot.service

# The first-boot unit orders After=network-online.target, but that target is a
# no-op unless a wait-online service is enabled — without this, the bootstrap
# can start before DHCP finishes and fail its network check.
systemctl enable NetworkManager-wait-online.service

# The user's copy is the one that runs; remove the staging clone so two
# divergent copies don't linger. (bash keeps this script's fd open, so
# deleting the directory we were invoked from is safe.)
rm -rf "${REPO_SRC}"
