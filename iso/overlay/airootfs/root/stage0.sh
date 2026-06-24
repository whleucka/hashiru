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
   Hashiru — Arch + Hyprland live installer
==================================================
This ERASES the target disk, sets up LUKS disk
encryption, installs base Arch, and bootstraps
Hashiru (Hyprland desktop) on first boot.
==================================================
BANNER
echo

# --- network is required (archinstall pacstraps from the mirrors) -------------
if ! ping -c1 -W2 archlinux.org &>/dev/null; then
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

# Build creds with jq so special characters in passwords are escaped correctly.
# NOTE: these key names (!users / !encryption_password / !root-password) track
# the archinstall schema and may need updating — see iso/README.md.
jq -n \
  --arg user "${HUSER}" \
  --arg pass "${HPASS}" \
  --arg luks "${HLUKS}" \
  '{
     "!users": [ { "username": $user, "!password": $pass, "sudo": true } ],
     "!encryption_password": $luks,
     "!root-password": ""
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
