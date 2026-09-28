#!/usr/bin/env bash
# stage0.sh — Hashiru live installer front-end.
#
# Runs in the archiso live environment (tty1). Collects the only things that
# vary per machine — username, password, timezone, target disk (+ optional
# separate LUKS passphrase) — splices them into the archinstall config, then
# hands off to archinstall, which owns partitioning, LUKS, pacstrap, fstab,
# bootloader and user creation. Hashiru itself bootstraps on first boot.
#
#   stage0.sh            the installer
#   stage0.sh --dry-run  every step, then print the config it would use
#                        (secrets redacted) and stop before archinstall
#
# Everything is a function and main runs only when executed, so the pieces can
# be sourced and tested on their own without an ISO.
set -euo pipefail

CONFIG_SRC="/root/archinstall/user_config.json"
CONFIG_RUN="/root/user_config.json"
CREDS_RUN="/root/user_creds.json"
DEFAULT_TZ="America/Toronto"
DEFAULT_HOSTNAME="hashiru"
DRY_RUN=0

# The steps, in order, as the rail shows them.
STEPS=(Network Account Machine Disk)

# The shared installer UI — banner, Tokyo Night palette, prompts. build.sh
# copies lib/ui.sh from the repo to /root/lib/ui.sh, beside this script.
# shellcheck source=lib/ui.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/ui.sh"

say() { ui_note "$*"; }
err() { ui_error "$*"; }

# --- UEFI is required (the archinstall config sets up GRUB on an ESP) ---------
require_uefi() {
  if [[ ! -d /sys/firmware/efi ]]; then
    err "Booted in BIOS/CSM mode, but Hashiru installs a UEFI system."
    err "Reboot and select the UEFI entry for this USB/CD in your firmware menu."
    exit 1
  fi
}

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

# The step's rail: which of STEPS this is, by name.
rail() {
  local i
  for i in "${!STEPS[@]}"; do
    if [[ "${STEPS[${i}]}" == "$1" ]]; then
      ui_rail "$(( i + 1 ))" "${STEPS[@]}"
      return 0
    fi
  done
}

# --- step: network ------------------------------------------------------------
# Wired first; WiFi only if that fails and there is a radio. The WiFi prompts
# are still plain reads — install-recovery rewrites this step's failure path.
ask_network() {
  rail Network
  say "Waiting for network (wired auto-connects)…"
  local net_ok='' _
  for _ in $(seq 1 5); do
    if have_net; then net_ok=1; break; fi
    sleep 2
  done

  # No wired link. If there's a WiFi radio, offer to set it up interactively.
  if [[ -z "${net_ok}" ]] && has_wifi_dev; then
    say "No wired network detected."
    if ui_confirm "Set up WiFi now?" yes && connect_wifi; then
      net_ok=1
    fi
  fi

  if [[ -z "${net_ok}" ]]; then
    err "No network connection."
    err "Connect wired, or set up wifi manually with 'iwctl', then re-run:"
    err "    /root/stage0.sh"
    exit 1
  fi
  ui_success "Network is up."
}

# --- step: account --------------------------------------------------------------
ask_account() {
  rail Account
  HUSER="$(ui_input "Username" "${HUSER:-}")"
  until [[ "${HUSER}" =~ ^[a-z_][a-z0-9_-]*$ ]]; do
    err "Invalid username (lowercase, start with letter/underscore)."
    HUSER="$(ui_input "Username")"
  done

  HPASS="$(ui_password "Password for ${HUSER}")"

  # LUKS passphrase — reuse the user password by default (asked only if not).
  if ui_confirm "Reuse this password for disk encryption?" yes; then
    HLUKS="${HPASS}"
  else
    HLUKS="$(ui_password "LUKS passphrase")"
  fi
}

# --- step: machine ----------------------------------------------------------------
ask_machine() {
  rail Machine
  HHOST="$(ui_input "Hostname" "${HHOST:-${DEFAULT_HOSTNAME}}")"
  until [[ "${HHOST}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; do
    err "Invalid hostname (lowercase letters/digits/hyphens, no leading/trailing hyphen)."
    HHOST="$(ui_input "Hostname" "${DEFAULT_HOSTNAME}")"
  done

  HTZ="$(ui_input "Timezone" "${HTZ:-${DEFAULT_TZ}}")"
  until [[ -n "${HTZ}" && -f "/usr/share/zoneinfo/${HTZ}" ]]; do
    err "Unknown timezone '${HTZ}'. Example: Europe/Berlin"
    HTZ="$(ui_input "Timezone" "${DEFAULT_TZ}")"
  done
}

# --- step: disk -------------------------------------------------------------------
# The medium the live ISO booted from must not be a target — erasing it yanks
# the installer out from under archinstall mid-run. archiso mounts it at
# bootmnt; resolve up to the whole disk (PKNAME), falling back to the source
# itself when it has no parent (e.g. /dev/sr0).
find_boot_disk() {
  local boot_src boot_pk
  BOOT_DISK=""
  boot_src="$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null || true)"
  if [[ -n "${boot_src}" && -b "${boot_src}" ]]; then
    boot_pk="$(lsblk -no PKNAME "${boot_src}" 2>/dev/null | head -1)"
    BOOT_DISK="${boot_pk:+/dev/${boot_pk}}"
    BOOT_DISK="${BOOT_DISK:-${boot_src}}"
  fi
}

ask_disk() {
  rail Disk
  find_boot_disk
  say "Available disks:"
  # TYPE filter drops the airootfs loop device and partitions; TYPE sits before
  # MODEL so the greedy last read field keeps models with spaces intact.
  local name size _type model dev
  while read -r name size _type model; do
    dev="/dev/${name}"
    if [[ "${dev}" == "${BOOT_DISK}" ]]; then
      printf '    %-16s %8s  %s  << live installer medium\n' "${dev}" "${size}" "${model}"
    else
      printf '    %-16s %8s  %s\n' "${dev}" "${size}" "${model}"
    fi
  done < <(lsblk -dno NAME,SIZE,TYPE,MODEL | awk '$3=="disk" && $1 !~ /^(zram|loop|ram)/')
  echo

  HDISK="$(ui_input "Target disk to ERASE (e.g. /dev/nvme0n1)")"
  while ! valid_target "${HDISK}"; do
    HDISK="$(ui_input "Target disk")"
  done
}

valid_target() {
  if [[ ! -b "$1" ]]; then
    err "Not a block device."
  elif [[ "$(lsblk -dno TYPE "$1" 2>/dev/null)" != "disk" || "$1" =~ ^/dev/(zram|loop|ram) ]]; then
    err "$1 is not an installable whole disk — pick e.g. /dev/nvme0n1, not a partition."
  elif [[ -n "${BOOT_DISK}" && "$1" == "${BOOT_DISK}" ]]; then
    err "$1 is the live installer medium — pick a different disk."
  else
    return 0
  fi
  return 1
}

# --- the point of no return ----------------------------------------------------
confirm_wipe() {
  echo
  err "ALL DATA on ${HDISK} ($(lsblk -dno SIZE,MODEL "${HDISK}" | tr -s ' ')) will be destroyed."
  local confirm
  confirm="$(ui_input "Type 'yes' to proceed")"
  [[ "${confirm}" == "yes" ]] || { err "Aborted."; exit 1; }
}

# --- splice answers into config + creds --------------------------------------
splice_config() {
  say "Preparing archinstall configuration…"
  sed -e "s|__TIMEZONE__|${HTZ}|g" \
      -e "s|__HOSTNAME__|${HHOST}|g" \
      -e "s|__HASHIRU_USER__|${HUSER}|g" \
      -e "s|__TARGET_DISK__|${HDISK}|g" \
      "${CONFIG_SRC}" > "${CONFIG_RUN}"

  # The saved layout froze an absolute btrfs partition size (captured on a small
  # test disk). Resize it to fill the actual target disk: total bytes, minus the
  # btrfs start offset, minus 1 MiB for the GPT backup header.
  local tmp
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
  # Sanity-check before archinstall produces a cryptic mid-partitioning error:
  # base system + Hyprland desktop needs real space, and a tiny disk would make
  # the size calculation go zero or negative.
  MIN_BTRFS_SIZE=$(( 15 * 1024 * 1024 * 1024 ))
  if (( BTRFS_SIZE < MIN_BTRFS_SIZE )); then
    err "${HDISK} is too small: need at least ~16 GiB, got $(( DISK_BYTES / 1024 / 1024 / 1024 )) GiB."
    exit 1
  fi
  say "Sizing btrfs partition to fill ${HDISK} (${BTRFS_SIZE} bytes)"
  tmp="$(mktemp)"
  jq --argjson sz "${BTRFS_SIZE}" '
    .disk_config.device_modifications[0].partitions |=
      map(if .fs_type=="btrfs" then .size.value = $sz else . end)
  ' "${CONFIG_RUN}" > "${tmp}" && mv "${tmp}" "${CONFIG_RUN}"
}

# Build creds with jq so special characters in passwords are escaped correctly.
# Secrets are passed via the environment ($ENV), not --arg, so they never
# appear on a command line (/proc/*/cmdline).
# Schema confirmed against archinstall v4.3: top-level "encryption_password"
# (plaintext) and "users" (each user takes a plaintext password under the
# "!password" key). root_enc_password is omitted, leaving root locked — the
# user has sudo. See iso/README.md if the archinstall version changes.
# umask in a subshell so the file is born 600 rather than chmod'ed after; a
# script-wide umask would reach archinstall and every file it installs.
write_creds() {
  ( umask 077
    HUSER="${HUSER}" HPASS="${HPASS}" HLUKS="${HLUKS}" jq -n \
      '{
         "encryption_password": $ENV.HLUKS,
         "users": [ { "username": $ENV.HUSER, "!password": $ENV.HPASS, "sudo": true, "groups": [] } ]
       }' > "${CREDS_RUN}" )
}

# --dry-run's report: the config archinstall would get, and the creds with every
# secret replaced. Then the creds file goes, same as after a real install.
show_dry_run() {
  ui_note "Dry run — archinstall would get this config:"
  jq . "${CONFIG_RUN}"
  ui_note "…and these credentials (secrets redacted):"
  jq '.encryption_password = "<redacted>" | .users[]."!password" = "<redacted>"' "${CREDS_RUN}"
  command rm -f "${CREDS_RUN}"
  ui_success "Dry run complete. Nothing was written to any disk."
}

# --- hand off to archinstall --------------------------------------------------
run_archinstall() {
  say "Launching archinstall — this installs the base system (several minutes)…"
  archinstall --config "${CONFIG_RUN}" --creds "${CREDS_RUN}" --silent

  # The live /root is tmpfs (RAM), but don't leave plaintext secrets around in
  # case the user pokes at the live session instead of rebooting. Kept on
  # archinstall failure (set -e exits above) to allow debugging a failed run.
  command rm -f "${CREDS_RUN}"
  echo
}

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
seed_wifi() {
  [[ -n "${WIFI_SSID}" ]] || return 0
  say "Seeding WiFi connection '${WIFI_SSID}' into the installed system…"
  NMDIR="/mnt/etc/NetworkManager/system-connections"
  # Sanitise only the filename; id/ssid keep the exact SSID.
  NMFILE="${NMDIR}/$(printf '%s' "${WIFI_SSID}" | tr -c 'A-Za-z0-9._-' '_').nmconnection"
  mkdir -p "${NMDIR}"
  ( umask 077; cat > "${NMFILE}" ) <<EOF
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
}

offer_reboot() {
  ui_success "Base install complete. Hashiru will bootstrap automatically on first boot."
  if ui_confirm "Reboot now?" yes; then
    umount -R /mnt 2>/dev/null || true
    systemctl reboot
  fi
}

usage() {
  echo "Usage: $0 [--dry-run]"
}

main() {
  while (( $# > 0 )); do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      -h|--help) usage; return 0 ;;
      *) usage >&2; return 2 ;;
    esac
    shift
  done

  # Palette before anything is drawn: on a VT it is what makes the splash's
  # colours Tokyo Night.
  ui_console_palette
  ui_splash "Arch + Hyprland live installer" "Press Enter to begin"
  require_uefi

  ask_network
  ask_account
  ask_machine
  ask_disk

  confirm_wipe
  splice_config
  write_creds

  if (( DRY_RUN )); then
    show_dry_run
    return 0
  fi

  run_archinstall
  seed_wifi
  offer_reboot
}

# Run only when executed; sourcing (tests) just defines the functions.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
