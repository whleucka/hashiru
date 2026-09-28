#!/usr/bin/env bash
# stage0.sh — Hashiru live installer front-end.
#
# Runs in the archiso live environment (tty1). Collects the only things that
# vary per machine — keyboard, username, password, hostname, timezone,
# language, target disk (+ optional separate LUKS passphrase) — splices them into the archinstall config, then
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
DEFAULT_TZ="UTC"
DEFAULT_LOCALE="en_US.UTF-8"
LOCALES_SUPPORTED="/usr/share/i18n/SUPPORTED"
DEFAULT_HOSTNAME="hashiru"
DEFAULT_KEYMAP="us"
KBD_MODEL_MAP="/usr/share/systemd/kbd-model-map"
SHOW_ALL_KEYMAPS="Show all keymaps…"
DRY_RUN=0

# The steps, in order, as the rail shows them.
# Keyboard comes first: the WiFi passphrase in Network is already typed on it.
STEPS=(Keyboard Network Account Machine Disk)

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
  detect_timezone
}

# --- timezone from the network ------------------------------------------------
# Only a starting point for the Machine step's picker, shown there and never
# applied on its own. ipinfo.io answers in plain text; ipwho.is is the JSON
# fallback. 3 s each, so an offline or rate-limited run costs at most ~6 s.
# Whatever comes back must name a real zoneinfo file, and the pattern keeps a
# hostile or broken answer (HTML, "../../etc/passwd") from getting that far.
valid_timezone() {
  [[ "$1" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ && -f "/usr/share/zoneinfo/$1" ]]
}

detect_timezone() {
  local tz
  tz="$(curl -fsS --max-time 3 https://ipinfo.io/timezone 2>/dev/null)" || tz=""
  if ! valid_timezone "${tz}"; then
    tz="$(curl -fsS --max-time 3 https://ipwho.is/ 2>/dev/null | jq -r '.timezone.id // empty' 2>/dev/null)" || tz=""
  fi
  if valid_timezone "${tz}"; then
    HTZ_DETECTED="${tz}"
  else
    HTZ_DETECTED="${DEFAULT_TZ}"
  fi
}

# --- step: keyboard -----------------------------------------------------------
# The console keymap archinstall sets (vconsole.conf) never reaches Hyprland,
# which reads its own input:kb_layout. So the pick is translated to xkb here,
# through the same table localectl uses, and written into the new user's
# ~/.config/hashiru/hypr/local.lua after the install (write_local_lua).

# xkb_for_keymap <keymap> — "layout|variant|options" from the first matching
# kbd-model-map row, or non-zero if the keymap isn't in it. Options keep only
# the grp:/grp_led: ones: they are how a two-layout map like ru ("ru,us")
# switches layouts, and the rest (terminate:ctrl_alt_bksp) aren't ours to add.
xkb_for_keymap() {
  awk -v k="$1" '
    !/^#/ && $1 == k {
      variant = ($4 == "-") ? "" : $4
      opts = ""
      n = split($5, o, ",")
      for (i = 1; i <= n; i++)
        if (o[i] ~ /^grp/) opts = opts (opts == "" ? "" : ",") o[i]
      print $2 "|" variant "|" opts
      found = 1
      exit
    }
    END { exit !found }
  ' "${KBD_MODEL_MAP}"
}

# Keymaps that are both installed and have an xkb equivalent: the default list.
mapped_keymaps() {
  comm -12 <(awk '!/^#/ && NF { print $1 }' "${KBD_MODEL_MAP}" | sort -u) \
           <(localectl list-keymaps --no-pager | sort -u)
}

ask_keyboard() {
  rail Keyboard
  local pick
  if ui_gum; then
    # The fuzzy finder shows the list, so the full one can hide behind an entry.
    pick="$( { mapped_keymaps; echo "${SHOW_ALL_KEYMAPS}"; } \
             | ui_filter "Keyboard layout" "${HKEYMAP:-${DEFAULT_KEYMAP}}")"
    if [[ "${pick}" == "${SHOW_ALL_KEYMAPS}" ]]; then
      pick="$(localectl list-keymaps --no-pager | ui_filter "Keyboard layout (all)" "${HKEYMAP:-${DEFAULT_KEYMAP}}")"
    fi
  else
    # Typed, so any installed keymap is accepted as-is; a miss lists close ones.
    pick="$(localectl list-keymaps --no-pager | ui_filter "Keyboard layout" "${HKEYMAP:-${DEFAULT_KEYMAP}}")"
  fi
  HKEYMAP="${pick}"

  if IFS='|' read -r HXKB_LAYOUT HXKB_VARIANT HXKB_OPTIONS < <(xkb_for_keymap "${HKEYMAP}"); then
    HXKB_MAPPED=1
  else
    HXKB_MAPPED=0 HXKB_LAYOUT="us" HXKB_VARIANT="" HXKB_OPTIONS=""
    ui_warn "${HKEYMAP} has no desktop equivalent; Hyprland will stay on us."
    ui_warn "Set it later in ~/.config/hashiru/hypr/local.lua."
  fi

  # Live, so every later answer (the password above all) is typed on the
  # layout the user just picked. Fails harmlessly off a VT (tests, ssh).
  if loadkeys "${HKEYMAP}" >/dev/null 2>&1; then
    ui_success "Keyboard is now ${HKEYMAP}."
  else
    ui_warn "Couldn't switch this console to ${HKEYMAP}; it is still set for the install."
  fi
}

# local_lua — the override that puts Hyprland on the picked layout, on stdout.
# Empty when there is nothing to say (us, or an unmapped keymap). caps:super
# is repeated from hyprland.lua because kb_options is one string: setting the
# layout switch alone would drop Hashiru's Caps-as-Super.
local_lua() {
  (( HXKB_MAPPED )) || return 0
  [[ "${HXKB_LAYOUT}" == "us" && -z "${HXKB_VARIANT}" ]] && return 0
  local fields="kb_layout = \"${HXKB_LAYOUT}\""
  [[ -n "${HXKB_VARIANT}" ]] && fields+=", kb_variant = \"${HXKB_VARIANT}\""
  [[ -n "${HXKB_OPTIONS}" ]] && fields+=", kb_options = \"caps:super,${HXKB_OPTIONS}\""
  printf '%s\n' \
    "-- Written by the Hashiru installer for the keymap picked there (${HKEYMAP})." \
    "-- Yours from here on: nothing in Hashiru overwrites this file." \
    "hl.config({ input = { ${fields} } })"
}

# Into the installed system, after archinstall and while /mnt is mounted.
# Created only if absent, owned by the new user (numeric ids from the target's
# passwd: the live system has no such user).
write_local_lua() {
  local body home dir file uid gid
  body="$(local_lua)"
  [[ -n "${body}" ]] || return 0
  home="/mnt/home/${HUSER}"
  file="${home}/.config/hashiru/hypr/local.lua"
  [[ -e "${file}" ]] && return 0
  IFS=: read -r uid gid < <(awk -F: -v u="${HUSER}" '$1 == u { print $3 ":" $4 }' /mnt/etc/passwd)
  if [[ -z "${uid}" ]]; then
    ui_warn "No ${HUSER} in the new system's passwd; Hyprland keyboard left at us."
    return 0
  fi
  for dir in "${home}/.config" "${home}/.config/hashiru" "${home}/.config/hashiru/hypr"; do
    [[ -d "${dir}" ]] || install -d -m 755 -o "${uid}" -g "${gid}" "${dir}"
  done
  printf '%s\n' "${body}" > "${file}"
  chown "${uid}:${gid}" "${file}"
  chmod 644 "${file}"
  say "Hyprland keyboard set to ${HXKB_LAYOUT}${HXKB_VARIANT:+ (${HXKB_VARIANT})} in ${file#/mnt}"
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

  # Pickers, so an answer is always one archinstall accepts.
  HTZ="$(timedatectl list-timezones --no-pager \
         | ui_filter "Timezone" "${HTZ:-${HTZ_DETECTED:-${DEFAULT_TZ}}}")"
  HLOCALE="$(system_locales | ui_filter "Language" "${HLOCALE:-${DEFAULT_LOCALE}}")"
}

# The UTF-8 locales glibc can generate, as archinstall's sys_lang wants them
# (en_US.UTF-8, sr_RS@latin). C.UTF-8 is always there, so it isn't a choice.
system_locales() {
  awk '$2 == "UTF-8" && $1 != "C.UTF-8" { print $1 }' "${LOCALES_SUPPORTED}"
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

# btrfs_size <disk bytes> — the btrfs partition that fills such a disk.
#
# The saved layout froze an absolute btrfs partition size (captured on a small
# test disk), so it is recomputed for the actual target: total bytes, minus the
# btrfs start offset, minus 1 MiB for the GPT backup header. Then rounded DOWN
# to a 1 MiB boundary. The start is already 1 MiB-aligned, so a 1 MiB-multiple
# size keeps the partition END aligned too. Without this the end lands at
# (disk_bytes - 1 MiB), and a real disk is sectors*512 — almost never a whole
# MiB — so parted/archinstall rejects it as misaligned. (A round qcow2 test disk
# IS a whole MiB, which is why QEMU never tripped this.) 1 MiB is a multiple of
# both 512- and 4096-byte sectors, so this is safe on 4Kn drives.
btrfs_size() {
  local start size
  start="$(jq -r '.disk_config.device_modifications[0].partitions[]
                  | select(.fs_type=="btrfs") | .start.value' "${CONFIG_SRC}")"
  size=$(( $1 - start - 1048576 ))
  echo $(( (size / 1048576) * 1048576 ))
}

# Base system + Hyprland desktop needs real space, and a tiny disk would make
# the size calculation go zero or negative. Checked when the disk is picked,
# not after the final confirmation.
MIN_BTRFS_SIZE=$(( 15 * 1024 * 1024 * 1024 ))
disk_fits() {
  (( $(btrfs_size "$(blockdev --getsize64 "$1")") >= MIN_BTRFS_SIZE ))
}

# The disks stage0 may offer, one "/dev/x  size  model" line each: whole disks
# only (TYPE filter drops the airootfs loop device, partitions and the CD
# drive), never zram/loop/ram, never the live installer medium. TYPE sits
# before MODEL so the greedy last read field keeps models with spaces intact.
disk_choices() {
  local name size _type model dev
  while read -r name size _type model; do
    dev="/dev/${name}"
    [[ -n "${BOOT_DISK}" && "${dev}" == "${BOOT_DISK}" ]] && continue
    printf '%-14s %7s  %s\n' "${dev}" "${size}" "${model:-unknown model}"
  done < <(lsblk -dno NAME,SIZE,TYPE,MODEL | awk '$3=="disk" && $1 !~ /^(zram|loop|ram)/')
}

ask_disk() {
  rail Disk
  find_boot_disk
  local -a choices=()
  mapfile -t choices < <(disk_choices)
  if (( ${#choices[@]} == 0 )); then
    err "No disk to install to (the one this installer booted from is never offered)."
    err "Attach the target disk (or check it shows in 'lsblk'), then re-run /root/stage0.sh."
    exit 1
  fi
  # Every disk too small would otherwise be a picker that refuses every pick.
  local line fits=0
  for line in "${choices[@]}"; do
    disk_fits "${line%% *}" && { fits=1; break; }
  done
  if (( ! fits )); then
    err "No disk here is big enough: Hashiru needs a disk of more than 16 GiB."
    printf '    %s\n' "${choices[@]}" >&2
    exit 1
  fi

  local pick
  while true; do
    pick="$(ui_choose "Disk to ERASE and install to" "${choices[@]}")"
    HDISK="${pick%% *}"
    if ! valid_target "${HDISK}"; then
      continue
    elif ! disk_fits "${HDISK}"; then
      err "${HDISK} is too small: Hashiru needs a disk of more than 16 GiB. Pick another disk."
      continue
    fi
    break
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
      -e "s|__KB_LAYOUT__|${HKEYMAP}|g" \
      -e "s|__SYS_LANG__|${HLOCALE}|g" \
      -e "s|__HOSTNAME__|${HHOST}|g" \
      -e "s|__HASHIRU_USER__|${HUSER}|g" \
      -e "s|__TARGET_DISK__|${HDISK}|g" \
      "${CONFIG_SRC}" > "${CONFIG_RUN}"

  local tmp
  DISK_BYTES="$(blockdev --getsize64 "${HDISK}")"
  BTRFS_SIZE="$(btrfs_size "${DISK_BYTES}")"
  # ask_disk already refused small disks; this only guards a disk that changed.
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

  ask_keyboard
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
  write_local_lua
  offer_reboot
}

# Run only when executed; sourcing (tests) just defines the functions.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
