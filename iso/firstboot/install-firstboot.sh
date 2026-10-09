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

# Tell the first-boot unit which user to bootstrap as. The attempt count starts
# at 0; hashiru-firstboot.sh rewrites this file on each failure, adding the
# stage to resume from.
printf 'HASHIRU_USER=%s\nHASHIRU_FIRSTBOOT_ATTEMPTS=0\n' "${HUSER}" > /etc/hashiru-firstboot.env

# The login notice for a failed first boot. Here rather than in a stage, so it
# is in place however early the bootstrap fails.
install -Dm644 "${REPO}/config/profile.d/hashiru-firstboot-failed.sh" \
  /etc/profile.d/hashiru-firstboot-failed.sh

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

# Hyprland reads its own kb_layout and ignores the system keymap, so without
# this a uk or de install gets a us desktop. The keymap picked in stage0 is
# already here as an xkb layout: archinstall set it with localectl before
# creating the user, and systemd-localed wrote the X11 equivalent from its
# kbd-model-map. Turn that into ~/.config/hashiru/hypr/local.lua, the
# machine-local override Hashiru never touches.
#
# Done here, not in stage0, because this runs inside the target while it is
# certainly mounted; after archinstall returns, stage0 can't count on /mnt.
# Created only if absent, and nothing for plain us. Of the options only the
# grp: ones are kept (how a two-layout map like ru,us switches), and
# caps:super is repeated because kb_options is one string: setting the switch
# alone would drop Hashiru's Caps-as-Super.
write_hypr_keyboard() {
  local conf="${X11_KEYBOARD_CONF:-/etc/X11/xorg.conf.d/00-keyboard.conf}"
  local file="${USER_HOME}/.config/hashiru/hypr/local.lua"
  local layout variant options grp='' opt dir fields
  [[ -r "${conf}" && ! -e "${file}" ]] || return 0
  xkb_option() { sed -n "s/^[[:space:]]*Option[[:space:]]*\"$1\"[[:space:]]*\"\([^\"]*\)\".*/\1/p" "${conf}" | head -1; }
  layout="$(xkb_option XkbLayout)"
  variant="$(xkb_option XkbVariant)"
  options="$(xkb_option XkbOptions)"
  [[ -n "${layout}" ]] || return 0
  [[ "${layout}" == "us" && -z "${variant}" ]] && return 0
  # Only what an xkb name can hold, so nothing odd lands inside a Lua string.
  [[ "${layout}${variant}${options}" =~ ^[A-Za-z0-9_,:()+-]*$ ]] || return 0

  local IFS=,
  for opt in ${options}; do
    [[ "${opt}" == grp* ]] && grp+="${grp:+,}${opt}"
  done
  unset IFS

  fields="kb_layout = \"${layout}\""
  [[ -n "${variant}" ]] && fields+=", kb_variant = \"${variant}\""
  [[ -n "${grp}" ]] && fields+=", kb_options = \"caps:super,${grp}\""

  for dir in "${USER_HOME}/.config" "${USER_HOME}/.config/hashiru" "${USER_HOME}/.config/hashiru/hypr"; do
    [[ -d "${dir}" ]] || install -d -m 755 -o "${HUSER}" -g "${HUSER}" "${dir}"
  done
  printf '%s\n' \
    "-- Written by the Hashiru installer for this machine's keyboard (${layout}${variant:+ ${variant}})." \
    "-- Yours from here on: nothing in Hashiru overwrites this file." \
    "hl.config({ input = { ${fields} } })" \
    | install -m 644 -o "${HUSER}" -g "${HUSER}" /dev/stdin "${file}"
}
write_hypr_keyboard

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
