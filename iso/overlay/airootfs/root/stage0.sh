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
say "Waiting for network…"
net_ok=
for _ in $(seq 1 10); do
  if have_net; then net_ok=1; break; fi
  sleep 2
done
if [[ -z "${net_ok}" ]]; then
  err "No network connection."
  err "Connect first (wired auto-connects; wifi: use 'iwctl'), then re-run:"
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
say "Base install complete. Hashiru will bootstrap automatically on first boot."
read -rp "Reboot now? [Y/n] " RB
if [[ "${RB,,}" != "n" ]]; then
  umount -R /mnt 2>/dev/null || true
  systemctl reboot
fi
