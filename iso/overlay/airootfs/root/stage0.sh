#!/usr/bin/env bash
# stage0.sh — Hashiru live installer front-end.
#
# Runs in the archiso live environment (tty1). Collects the only things that
# vary per machine — username, password, timezone, target disk (+ optional
# separate LUKS passphrase) — splices them into the archinstall config, then
# hands off to archinstall, which owns partitioning, LUKS, pacstrap, fstab,
# bootloader and user creation. Hashiru itself bootstraps on first boot.
set -euo pipefail

CONFIG_SRC="/root/archinstall/user_config.json"
CONFIG_RUN="/root/user_config.json"
CREDS_RUN="/root/user_creds.json"
DEFAULT_TZ="America/Toronto"
DEFAULT_HOSTNAME="hashiru"

c_red=$'\e[0;31m'; c_blu=$'\e[0;34m'; c_rst=$'\e[0m'
say() { printf '%s %s\n' "${c_blu}==>${c_rst}" "$*"; }
err() { printf '%s %s\n' "${c_red}!!${c_rst}" "$*" >&2; }

clear 2>/dev/null || true
cat <<'BANNER'
==================================================
        ▓░ ░ ▓▒▀▓ ▓█▀▀ ▓░ ░ ▓░ ▓█▀▓ ▓█ ░
        ▒▓▀▒ ▒░▄▒ ▀▀▒▓ ▒▓▀▒ ▒▒ ▒▓▄▀ ▒▓ ▒
        ░  ▓ ░  ░ ▄▄░▒ ░  ▓ ░▓ ░▒ ▒ ░▒▄▓
         Arch + Hyprland live installer
            Created by: Will Hleucka
==================================================
This ERASES the target disk, sets up LUKS disk
encryption, installs base Arch, and bootstraps
Hashiru (Hyprland desktop) on first boot.
==================================================
BANNER
echo

# --- network is required (archinstall pacstraps from the mirrors) -------------
# Ping a literal IP, never a hostname: ping's -W only bounds the reply wait, not
# the DNS lookup, so pinging a name stalls on getaddrinfo until the resolver
# times out (~20-30s) if DNS isn't up yet. Retry briefly so a slow NIC/DHCP
# lease on real hardware gets a chance to come up before we give up.
have_net() {
  local host
  for host in 1.1.1.1 8.8.8.8 9.9.9.9; do
    timeout 3 ping -c1 -W2 "${host}" &>/dev/null && return 0
  done
  return 1
}

# Name of the first wireless interface (e.g. wlan0), or non-zero if none.
# /sys/class/net/<iface>/wireless exists only for 802.11 devices, so this is a
# reliable, parse-free probe — unlike scraping `iwctl device list` output, which
# is box-drawing-decorated and colourised.
first_wifi_dev() {
  local d
  for d in /sys/class/net/*/wireless; do
    [[ -e "${d}" ]] || continue
    basename "$(dirname "${d}")"
    return 0
  done
  return 1
}
has_wifi_dev() { first_wifi_dev >/dev/null 2>&1; }

# Captured when WiFi is set up, so the same credentials can be seeded into the
# installed system's NetworkManager after archinstall (see end of script).
WIFI_SSID=""
WIFI_PSK=""

# Bring up WiFi in the live environment via iwd (iwctl). On success, exports
# WIFI_SSID/WIFI_PSK and returns 0. The live env runs systemd-networkd +
# systemd-resolved + iwd, so once iwd associates, DHCP and DNS follow.
connect_wifi() {
  local dev ssid psk
  dev="$(first_wifi_dev)" || { err "No WiFi device found."; return 1; }

  rfkill unblock wifi 2>/dev/null || true
  iwctl device "${dev}" set-property Powered on 2>/dev/null || true

  say "Scanning for networks on ${dev}…"
  iwctl station "${dev}" scan 2>/dev/null || true
  sleep 3
  iwctl station "${dev}" get-networks || true
  echo

  read -rp "WiFi SSID: " ssid
  [[ -n "${ssid}" ]] || { err "Empty SSID."; return 1; }
  read -rsp "WiFi passphrase: " psk; echo

  say "Connecting to ${ssid}…"
  if ! iwctl --passphrase "${psk}" station "${dev}" connect "${ssid}"; then
    err "WiFi connection failed (wrong passphrase or out of range?)."
    return 1
  fi

  # Association is near-instant but the DHCP lease can lag a couple of seconds.
  local _
  for _ in $(seq 1 10); do
    if have_net; then WIFI_SSID="${ssid}"; WIFI_PSK="${psk}"; return 0; fi
    sleep 2
  done
  err "Associated with ${ssid} but no internet (DHCP/DNS not up?)."
  return 1
}

say "Waiting for network (wired auto-connects)…"
net_ok=
for _ in $(seq 1 5); do
  if have_net; then net_ok=1; break; fi
  sleep 2
done

# No wired link. If there's a WiFi radio, offer to set it up interactively.
if [[ -z "${net_ok}" ]] && has_wifi_dev; then
  say "No wired network detected."
  read -rp "Set up WiFi now? [Y/n] " DOWIFI
  if [[ "${DOWIFI,,}" != "n" ]] && connect_wifi; then
    net_ok=1
  fi
fi

if [[ -z "${net_ok}" ]]; then
  err "No network connection."
  err "Connect wired, or set up wifi manually with 'iwctl', then re-run:"
  err "    /root/stage0.sh"
  exit 1
fi

# --- prompts ------------------------------------------------------------------
read -rp "Username: " HUSER
while [[ ! "${HUSER}" =~ ^[a-z_][a-z0-9_-]*$ ]]; do
  err "Invalid username (lowercase, start with letter/underscore)."
  read -rp "Username: " HUSER
done

read -rsp "Password for ${HUSER}: " HPASS; echo
read -rsp "Confirm password: " HPASS2; echo
while [[ -z "${HPASS}" || "${HPASS}" != "${HPASS2}" ]]; do
  err "Empty or mismatched — try again."
  read -rsp "Password for ${HUSER}: " HPASS; echo
  read -rsp "Confirm password: " HPASS2; echo
done

# LUKS passphrase — reuse the user password by default (4th prompt only if not).
read -rp "Reuse this password for disk encryption? [Y/n] " REUSE
if [[ "${REUSE,,}" == "n" ]]; then
  read -rsp "LUKS passphrase: " HLUKS; echo
  read -rsp "Confirm LUKS passphrase: " HLUKS2; echo
  while [[ -z "${HLUKS}" || "${HLUKS}" != "${HLUKS2}" ]]; do
    err "Empty or mismatched — try again."
    read -rsp "LUKS passphrase: " HLUKS; echo
    read -rsp "Confirm LUKS passphrase: " HLUKS2; echo
  done
else
  HLUKS="${HPASS}"
fi

read -rp "Hostname [${DEFAULT_HOSTNAME}]: " HHOST
HHOST="${HHOST:-${DEFAULT_HOSTNAME}}"
while [[ ! "${HHOST}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; do
  err "Invalid hostname (lowercase letters/digits/hyphens, no leading/trailing hyphen)."
  read -rp "Hostname [${DEFAULT_HOSTNAME}]: " HHOST
  HHOST="${HHOST:-${DEFAULT_HOSTNAME}}"
done

read -rp "Timezone [${DEFAULT_TZ}]: " HTZ
HTZ="${HTZ:-${DEFAULT_TZ}}"
while [[ ! -f "/usr/share/zoneinfo/${HTZ}" ]]; do
  err "Unknown timezone '${HTZ}'. Example: Europe/Berlin"
  read -rp "Timezone [${DEFAULT_TZ}]: " HTZ
  HTZ="${HTZ:-${DEFAULT_TZ}}"
done

# --- target disk --------------------------------------------------------------
echo
say "Available disks:"
lsblk -dno NAME,SIZE,MODEL | sed 's/^/    \/dev\//'
read -rp "Target disk to ERASE (e.g. /dev/nvme0n1): " HDISK
while [[ ! -b "${HDISK}" ]]; do
  err "Not a block device."
  read -rp "Target disk: " HDISK
done

echo
err "ALL DATA on ${HDISK} will be destroyed."
read -rp "Type 'yes' to proceed: " CONFIRM
[[ "${CONFIRM}" == "yes" ]] || { err "Aborted."; exit 1; }

# --- splice answers into config + creds --------------------------------------
say "Preparing archinstall configuration…"
sed -e "s|__TIMEZONE__|${HTZ}|g" \
    -e "s|__HOSTNAME__|${HHOST}|g" \
    -e "s|__HASHIRU_USER__|${HUSER}|g" \
    -e "s|__TARGET_DISK__|${HDISK}|g" \
    "${CONFIG_SRC}" > "${CONFIG_RUN}"

# The saved layout froze an absolute btrfs partition size (captured on a small
# test disk). Resize it to fill the actual target disk: total bytes, minus the
# btrfs start offset, minus 1 MiB for the GPT backup header.
DISK_BYTES="$(blockdev --getsize64 "${HDISK}")"
BTRFS_START="$(jq -r '.disk_config.device_modifications[0].partitions[]
                      | select(.fs_type=="btrfs") | .start.value' "${CONFIG_RUN}")"
BTRFS_SIZE=$(( DISK_BYTES - BTRFS_START - 1048576 ))
# Round the size DOWN to a 1 MiB boundary. The start is already 1 MiB-aligned,
# so a 1 MiB-multiple size keeps the partition END aligned too. Without this the
# end lands at (disk_bytes - 1 MiB), and a real disk is sectors*512 — almost
# never a whole MiB — so parted/archinstall rejects it as misaligned. (A round
# qcow2 test disk IS a whole MiB, which is why QEMU never tripped this.) 1 MiB is
# a multiple of both 512- and 4096-byte sectors, so this is safe on 4Kn drives.
BTRFS_SIZE=$(( (BTRFS_SIZE / 1048576) * 1048576 ))
say "Sizing btrfs partition to fill ${HDISK} (${BTRFS_SIZE} bytes)"
tmp="$(mktemp)"
jq --argjson sz "${BTRFS_SIZE}" '
  .disk_config.device_modifications[0].partitions |=
    map(if .fs_type=="btrfs" then .size.value = $sz else . end)
' "${CONFIG_RUN}" > "${tmp}" && mv "${tmp}" "${CONFIG_RUN}"

# Build creds with jq so special characters in passwords are escaped correctly.
# Schema confirmed against archinstall v4.3: top-level "encryption_password"
# (plaintext) and "users" (each user takes a plaintext password under the
# "!password" key). root_enc_password is omitted, leaving root locked — the
# user has sudo. See iso/README.md if the archinstall version changes.
jq -n \
  --arg user "${HUSER}" \
  --arg pass "${HPASS}" \
  --arg luks "${HLUKS}" \
  '{
     "encryption_password": $luks,
     "users": [ { "username": $user, "!password": $pass, "sudo": true, "groups": [] } ]
   }' > "${CREDS_RUN}"
chmod 600 "${CREDS_RUN}"

# --- hand off to archinstall --------------------------------------------------
say "Launching archinstall — this installs the base system (several minutes)…"
archinstall --config "${CONFIG_RUN}" --creds "${CREDS_RUN}" --silent

echo

# --- seed WiFi into the installed system --------------------------------------
# archinstall installs NetworkManager (network_config.type = "nm") but does NOT
# carry over the live env's iwd connection. Without this, a WiFi-only machine
# boots with NM running but zero saved connections, so network-online.target
# never comes up and the first-boot bootstrap (pacman/AUR/git) hangs or fails.
# Wired machines never hit this — DHCP satisfies network-online.target on its
# own, which is exactly why it's invisible under QEMU.
#
# Write a NetworkManager keyfile into the target so NM auto-connects on first
# boot. No uuid: NM generates and persists one when it first reads the file.
# /mnt is still mounted here (archinstall unmounts only on reboot, below).
if [[ -n "${WIFI_SSID}" ]]; then
  say "Seeding WiFi connection '${WIFI_SSID}' into the installed system…"
  NMDIR="/mnt/etc/NetworkManager/system-connections"
  # Sanitise only the filename; id/ssid keep the exact SSID.
  NMFILE="${NMDIR}/$(printf '%s' "${WIFI_SSID}" | tr -c 'A-Za-z0-9._-' '_').nmconnection"
  mkdir -p "${NMDIR}"
  cat > "${NMFILE}" <<EOF
[connection]
id=${WIFI_SSID}
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=${WIFI_SSID}

[wifi-security]
key-mgmt=wpa-psk
psk=${WIFI_PSK}

[ipv4]
method=auto

[ipv6]
method=auto
EOF
  # NM refuses to load system-connection keyfiles unless they are root-owned and
  # not group/world readable (they hold the plaintext PSK).
  chown 0:0 "${NMFILE}"
  chmod 600 "${NMFILE}"
fi

say "Base install complete. Hashiru will bootstrap automatically on first boot."
read -rp "Reboot now? [Y/n] " RB
if [[ "${RB,,}" != "n" ]]; then
  umount -R /mnt 2>/dev/null || true
  systemctl reboot
fi
