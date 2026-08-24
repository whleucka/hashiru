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
# /opt/hashiru is permanent, not staging: it stays on the installed system as
# the single copy of Hashiru. The desktop config is stowed out of it (symlinks
# into stow/ point here for the life of the machine) and `hashiru update` pulls
# into it. Copying it into the home directory instead would leave two divergent
# checkouts and dangling stow links.
REPO="/opt/hashiru"
USER_HOME="/home/${HUSER}"

install -Dm644 "${REPO}/iso/firstboot/hashiru-firstboot.service" \
  /etc/systemd/system/hashiru-firstboot.service
install -Dm755 "${REPO}/iso/firstboot/hashiru-firstboot.sh" \
  /usr/local/bin/hashiru-firstboot.sh

# Tell the first-boot unit which user to bootstrap as.
printf 'HASHIRU_USER=%s\n' "${HUSER}" > /etc/hashiru-firstboot.env

# Keep the tty1 login prompt off the screen for the whole first boot. Without
# this, getty@tty1 comes up with multi-user.target, paints a login prompt, and
# is then scribbled over by the bootstrap's console logging a moment later —
# which looks broken. The condition is the same env file the first-boot unit
# gates on, so the getty returns by itself the moment the bootstrap clears it
# (and hashiru-firstboot.sh removes this drop-in on the failure path, so a
# failed run still leaves a way to log in). A separate file from stage 30's
# autologin.conf, so removing it never disturbs the autologin config.
install -Dm644 /dev/stdin \
  /etc/systemd/system/getty@tty1.service.d/10-hashiru-firstboot.conf <<'EOF'
[Unit]
ConditionPathExists=!/etc/hashiru-firstboot.env
EOF

# install.sh runs as the unprivileged user and refuses to run as root, and
# `hashiru update` has to `git pull` here without sudo. Hand the whole checkout
# to the user rather than leaving it root-owned.
chown -R "${HUSER}:${HUSER}" "${REPO}"

# Convenience only — the real location is /opt/hashiru.
ln -sfn "${REPO}" "${USER_HOME}/hashiru"
chown -h "${HUSER}:${HUSER}" "${USER_HOME}/hashiru"

# Put the management CLI on PATH: `hashiru update`, `hashiru doctor`.
ln -sfn "${REPO}/bin/hashiru" /usr/local/bin/hashiru

systemctl enable hashiru-firstboot.service

# The first-boot unit orders After=network-online.target, but that target is a
# no-op unless a wait-online service is enabled — without this, the bootstrap
# can start before DHCP finishes and fail its network check.
systemctl enable NetworkManager-wait-online.service
