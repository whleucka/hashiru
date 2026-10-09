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
# stage0's own event log: plain lines, never a secret. The failure screens point
# here. Overridable so a test run doesn't need /var/log.
STAGE0_LOG="${HASHIRU_STAGE0_LOG:-/var/log/hashiru-stage0.log}"
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
STEPS=(Keyboard Network Account Machine Disk Review)

# The shared installer UI — banner, Tokyo Night palette, prompts. build.sh
# copies lib/ui.sh from the repo to /root/lib/ui.sh, beside this script.
# shellcheck source=lib/ui.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/ui.sh"

# Append one plain, timestamped line to the stage0 log. Only these wrappers and
# the step summaries write it, and none of them is ever handed HPASS, HLUKS or
# WIFI_PSK. A log that can't be written never stops the install.
slog() {
  printf '%(%F %T)T %s\n' -1 "$*" >> "${STAGE0_LOG}" 2>/dev/null || true
}

say()  { slog "$*"; ui_note "$*"; }
ok()   { slog "$*"; ui_success "$*"; }
warn() { slog "warning: $*"; ui_warn "$*"; }
err()  { slog "error: $*"; ui_error "$*"; }

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

# iwd's own store. A passphrase goes to iwd as a network file here rather than
# `iwctl --passphrase`, which would put it in /proc/*/cmdline for anything on
# the live system to read.
IWD_DIR="/var/lib/iwd"

# The networks a scan found, one "ssid<TAB>security<TAB>signal" line each,
# strongest first (iwctl's order). get-networks is a table drawn for people:
# colour codes, a title, rules and a header, then rows of
#   [>] <name, may hold spaces>  <psk|open|8021x|wep>  <*…>
# so a row is recognised by its last two fields and the name is what's left.
wifi_networks() {
  local line ssid sec sig
  iwctl station "$1" get-networks 2>/dev/null </dev/null \
    | sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' \
    | while IFS= read -r line; do
        [[ "${line}" =~ ^[[:space:]]*(\>[[:space:]]+)?(.*[^[:space:]])[[:space:]]+(psk|open|8021x|wep)[[:space:]]+(\*+)[[:space:]]*$ ]] || continue
        ssid="${BASH_REMATCH[2]}" sec="${BASH_REMATCH[3]}" sig="${BASH_REMATCH[4]}"
        printf '%s\t%s\t%s\n' "${ssid}" "${sec}" "${sig}"
      done
}

# iwd's file for an SSID: the name as-is when it is only letters, digits,
# space, _ and -, otherwise "=" and the SSID's bytes in hex (iwd.network(5)).
iwd_file() {
  # C, because in a UTF-8 locale [A-Za-z] takes in é, and iwd wouldn't.
  local LC_ALL=C
  local ssid="$1" ext="$2" hex
  if [[ "${ssid}" =~ ^[A-Za-z0-9\ _-]+$ ]]; then
    printf '%s/%s.%s' "${IWD_DIR}" "${ssid}" "${ext}"
  else
    hex="$(printf '%s' "${ssid}" | od -An -tx1 | tr -d ' \n')"
    printf '%s/=%s.%s' "${IWD_DIR}" "${hex}" "${ext}"
  fi
}

# wifi_connect <dev> <ssid> <security> [psk] — join one network and wait for
# the internet behind it. The passphrase reaches iwd through its network file
# (written by printf, a builtin, so never an argv), and the file goes again if
# the join fails: it would otherwise sit in iwd's list as a known network.
wifi_connect() {
  local dev="$1" ssid="$2" sec="$3" psk="${4:-}" file='' _
  if [[ "${sec}" == psk ]]; then
    file="$(iwd_file "${ssid}" psk)"
    mkdir -p "${IWD_DIR}"
    ( umask 077; printf '[Security]\nPassphrase=%s\n' "${psk}" > "${file}" )
  fi
  say "Connecting to ${ssid}…"
  if ! iwctl --dont-ask station "${dev}" connect "${ssid}" </dev/null >/dev/null 2>&1; then
    [[ -n "${file}" ]] && command rm -f "${file}"
    return 1
  fi
  # Association is near-instant but the DHCP lease can lag a couple of seconds.
  for _ in $(seq 1 10); do
    have_net && return 0
    sleep 2
  done
  err "Joined ${ssid}, but there's no internet behind it (DHCP or DNS not up?)."
  return 2
}

# Pick a network and join it. 0 once online, 1 to go back to the network menu.
# A wrong passphrase asks again, three times, then goes back to the list.
#
# The caller tests the result, so set -e and the ERR trap are off in here:
# every prompt's status is checked by hand, or Ctrl-C in gum would read as an
# empty answer.
set_up_wifi() {
  local dev
  dev="$(first_wifi_dev)" || { err "No WiFi device found."; return 1; }
  rfkill unblock wifi 2>/dev/null || true
  iwctl device "${dev}" set-property Powered on </dev/null >/dev/null 2>&1 || true

  local -a nets=() items=()
  local net ssid sec sig pick i rc psk tries pad
  while true; do
    say "Scanning for networks on ${dev}…"
    iwctl station "${dev}" scan </dev/null >/dev/null 2>&1 || true
    sleep 3
    mapfile -t nets < <(wifi_networks "${dev}")
    items=()
    for net in "${nets[@]}"; do
      IFS=$'\t' read -r ssid sec sig <<< "${net}"
      # Padded by character count: printf's %-32s pads bytes, and an SSID
      # like "Café" would knock its row out of line.
      pad=""
      (( ${#ssid} < 32 )) && printf -v pad '%*s' "$(( 32 - ${#ssid} ))" ''
      items+=("${ssid}${pad} $(printf '%-6s' "${sec}") ${sig}")
    done
    (( ${#nets[@]} )) || warn "No networks found."
    rc=0
    pick="$(ui_choose "WiFi network" "${items[@]}" "Scan again" "Hidden network…" Back)" || rc=$?
    if (( rc != 0 )); then
      (( rc == 1 )) && ui_gum && continue
      exit "${rc}"
    fi

    case "${pick}" in
      "Scan again") continue ;;
      Back)         return 1 ;;
      "Hidden network…")
        ssid="$(ui_input "Network name (SSID)")" || { stop_on_ctrl_c $?; continue; }
        [[ -n "${ssid}" ]] || continue
        sec=psk ;;
      *)
        for i in "${!items[@]}"; do
          [[ "${items[${i}]}" == "${pick}" ]] || continue
          IFS=$'\t' read -r ssid sec sig <<< "${nets[${i}]}"
          break
        done ;;
    esac
    slog "wifi: ${ssid} (${sec})"

    case "${sec}" in
      open)
        rc=0
        wifi_connect "${dev}" "${ssid}" open || rc=$?
        if (( rc == 0 )); then WIFI_SSID="${ssid}" WIFI_PSK=""; return 0; fi
        (( rc == 2 )) || err "Couldn't join ${ssid} (out of range?)."
        continue ;;
      psk) ;;
      *)
        err "${ssid} uses ${sec}, which this installer can't set up."
        err "Pick Shell from the network menu and connect with 'iwctl'."
        continue ;;
    esac

    for (( tries = 1; tries <= 3; tries++ )); do
      psk="$(ui_password "Passphrase for ${ssid}")" || { stop_on_ctrl_c $?; break; }
      rc=0
      wifi_connect "${dev}" "${ssid}" psk "${psk}" || rc=$?
      if (( rc == 0 )); then WIFI_SSID="${ssid}" WIFI_PSK="${psk}"; return 0; fi
      (( rc == 2 )) && break
      err "Couldn't join ${ssid}: wrong passphrase, or out of range? (${tries} of 3)"
    done
    if (( tries > 3 )); then
      slog "wifi: three misses on ${ssid}"
      return 1
    fi
  done
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
# Wired first: it needs nothing from anyone. Without it, a menu until the
# network is up — Retry for a cable plugged in late, WiFi when there's a radio,
# and a shell for anything else. Nothing here exits on its own.
wait_for_net() {
  local _
  for _ in $(seq 1 "$1"); do
    have_net && return 0
    sleep 2
  done
  return 1
}

ask_network() {
  rail Network
  say "Waiting for network (wired auto-connects)…"
  local -a options
  local choice rc wait=5
  # 10 s for the first look, 4 s after each pick: the menu shouldn't drag.
  until wait_for_net "${wait}"; do
    wait=2
    err "No network connection. archinstall downloads the system, so it needs one."
    options=(Retry)
    has_wifi_dev && options+=("Set up WiFi")
    options+=(Shell "Power off")
    rc=0
    choice="$(ui_choose "What now?" "${options[@]}")" || rc=$?
    if (( rc != 0 )); then
      (( rc == 1 )) && ui_gum && continue
      exit "${rc}"
    fi
    slog "network menu: ${choice}"
    case "${choice}" in
      Retry)         say "Waiting for network…" ;;
      "Set up WiFi") set_up_wifi && break ;;
      Shell)         drop_to_shell ;;
      "Power off")   power_off; exit 1 ;;
    esac
  done
  ok "Network is up."
  slog "network: ${WIFI_SSID:+wifi ${WIFI_SSID}}${WIFI_SSID:-wired}"
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
# which reads its own input:kb_layout. install-firstboot.sh writes that into
# the new user's ~/.config/hashiru/hypr/local.lua from the X11 layout localed
# derives. Here the same table (kbd-model-map) only tells the review card what
# Hyprland will get, and warns when a keymap has no match.

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

  if IFS='|' read -r HXKB_LAYOUT HXKB_VARIANT _ < <(xkb_for_keymap "${HKEYMAP}"); then
    HXKB_MAPPED=1
  else
    HXKB_MAPPED=0 HXKB_LAYOUT="us" HXKB_VARIANT=""
    warn "${HKEYMAP} has no desktop equivalent; Hyprland will stay on us."
    warn "Set it later in ~/.config/hashiru/hypr/local.lua."
  fi

  # Live, so every later answer (the password above all) is typed on the
  # layout the user just picked. Fails harmlessly off a VT (tests, ssh).
  if loadkeys "${HKEYMAP}" >/dev/null 2>&1; then
    ok "Keyboard is now ${HKEYMAP}."
  else
    warn "Couldn't switch this console to ${HKEYMAP}; it is still set for the install."
  fi
  slog "keyboard: ${HKEYMAP} -> Hyprland ${HXKB_LAYOUT}${HXKB_VARIANT:+ (${HXKB_VARIANT})}"
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
    HLUKS="${HPASS}" HLUKS_SAME=1
  else
    HLUKS="$(ui_password "LUKS passphrase")" HLUKS_SAME=0
  fi
  local key="same as login"
  (( HLUKS_SAME )) || key="separate"
  slog "account: ${HUSER}, disk key ${key}"
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
  slog "machine: ${HHOST}, ${HTZ}, ${HLOCALE}"
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
#
# The start comes from btrfs_start, read once by ask_disk. Not here: this runs
# inside $(…) under a condition (disk_fits), where a failed jq is silently
# swallowed and the size comes out wrong instead of stopping anything.
BTRFS_START=""
btrfs_start() {
  BTRFS_START="$(jq -r '.disk_config.device_modifications[0].partitions[]
                        | select(.fs_type=="btrfs") | .start.value' "${CONFIG_SRC}")"
  if [[ ! "${BTRFS_START}" =~ ^[0-9]+$ ]]; then
    err "Can't read the btrfs partition's start from ${CONFIG_SRC} (got '${BTRFS_START}')."
    return 1
  fi
}

btrfs_size() {
  local size
  size=$(( $1 - BTRFS_START - 1048576 ))
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
  btrfs_start
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
    HDISK_LABEL="$(tr -s ' ' <<< "${pick}")"
    if ! valid_target "${HDISK}"; then
      continue
    elif ! disk_fits "${HDISK}"; then
      err "${HDISK} is too small: Hashiru needs a disk of more than 16 GiB. Pick another disk."
      continue
    fi
    break
  done
  slog "disk: ${HDISK_LABEL}"
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

# --- review: every answer on one card, any of them editable ------------------
# Nothing has been written anywhere yet, so leaving from here costs nothing.
REVIEW_NOTE=""

keyboard_summary() {
  if (( HXKB_MAPPED )); then
    printf '%s → Hyprland %s%s' "${HKEYMAP}" "${HXKB_LAYOUT}" "${HXKB_VARIANT:+ (${HXKB_VARIANT})}"
  else
    printf '%s → Hyprland us (no match)' "${HKEYMAP}"
  fi
}

review_card() {
  local luks="same as login"
  (( HLUKS_SAME )) || luks="separate"
  ui_card "Review" \
    Keyboard  "$(keyboard_summary)" \
    Network   "${WIFI_SSID:+WiFi ${WIFI_SSID}}${WIFI_SSID:-wired}" \
    Username  "${HUSER}" \
    Password  "••••••••" \
    "Disk key" "${luks}" \
    Hostname  "${HHOST}" \
    Timezone  "${HTZ}" \
    Language  "${HLOCALE}" \
    Disk      "${HDISK_LABEL}"
  if (( ! HXKB_MAPPED )); then
    ui_warn "${HKEYMAP} has no desktop equivalent, so Hyprland stays on us."
    ui_warn "Set it later in ~/.config/hashiru/hypr/local.lua."
  fi
}

# Loops until Install is confirmed (returns) or Quit (exits 0). An edit re-runs
# just that step, which re-applies whatever it does (loadkeys for Keyboard).
review() {
  local choice rc
  while true; do
    rail Review
    review_card
    if [[ -n "${REVIEW_NOTE}" ]]; then
      err "${REVIEW_NOTE}"
      REVIEW_NOTE=""
    fi
    rc=0
    choice="$(ui_choose "Ready to install?" Install "Edit Keyboard" "Edit Account" \
                "Edit Machine" "Edit Disk" Quit)" || rc=$?
    if (( rc != 0 )); then
      # Esc in gum is "not yet", not "quit": stay here. Anything else
      # (Ctrl-C, end of input) is a real stop.
      (( rc == 1 )) && ui_gum && continue
      exit "${rc}"
    fi
    slog "review: ${choice}"
    case "${choice}" in
      Install)         confirm_wipe && return 0 ;;
      "Edit Keyboard") ask_keyboard ;;
      "Edit Account")  ask_account ;;
      "Edit Machine")  ask_machine ;;
      "Edit Disk")     ask_disk ;;
      Quit)
        ui_note "Nothing was written. Run /root/stage0.sh to start again."
        exit 0 ;;
    esac
  done
}

# --- the point of no return ----------------------------------------------------
# Typing the disk's own name (nvme0n1) rather than "yes" makes the answer
# depend on which disk is about to go. A miss goes back to review.
confirm_wipe() {
  local name="${HDISK#/dev/}" typed
  echo
  err "ALL DATA on ${HDISK_LABEL} will be destroyed."
  # review calls this inside `&&`, where a failed $(…) doesn't stop anything:
  # without the check, Ctrl-C in gum would read as a mistyped name.
  typed="$(ui_input "Type ${name} to erase it and install")" || {
    stop_on_ctrl_c $?
    typed=""
  }
  if [[ "${typed}" == "${name}" ]]; then
    slog "confirmed: erasing ${HDISK}"
    return 0
  fi
  REVIEW_NOTE="'${typed}' is not ${name}. Nothing was erased."
  slog "wipe not confirmed (typed '${typed}')"
  return 1
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
  ok "Dry run complete. Nothing was written to any disk."
}

# --- hand off to archinstall --------------------------------------------------
ARCHINSTALL_LOG="/var/log/archinstall/install.log"
# The disk the last archinstall run was given. A retry cleans up after that
# one, which is not HDISK any more if "Edit answers" picked another disk.
LAST_TARGET=""

# Undo what a failed run left open, so the next one starts from nothing:
# everything under /mnt, then the LUKS mappings on <disk>, deepest first. Then
# check rather than trust: anything still mounted or mapped fails it.
release_target() {
  local disk="$1" name type
  if mountpoint -q /mnt; then
    umount -R /mnt || true
  fi
  if [[ -n "${disk}" && -b "${disk}" ]]; then
    while read -r name type; do
      [[ "${type}" == crypt ]] && { cryptsetup close "${name}" || true; }
    done < <(lsblk -rno NAME,TYPE "${disk}" 2>/dev/null | tac)
  fi

  local left=""
  mountpoint -q /mnt && left="/mnt is still mounted"
  if [[ -z "${left}" && -n "${disk}" ]] \
     && lsblk -rno TYPE "${disk}" 2>/dev/null | grep -qx crypt; then
    left="a LUKS mapping on ${disk} is still open"
  fi
  if [[ -n "${left}" ]]; then
    err "Couldn't clean up after the failed run: ${left}."
    err "Pick Shell to look (lsblk, umount -R /mnt, cryptsetup close), then try again."
    return 1
  fi
  slog "released ${disk:-nothing}"
}

# --- F3: archinstall died in one of the custom commands -----------------------
# archinstall runs custom_commands[N] as /var/tmp/user-command.N.sh inside the
# target, and a failure raises with that path and "exit code" on one log line.
# By then the base system is installed; only Hashiru's wiring (clone, pin,
# first-boot unit) is missing, so it can be re-run without a re-install.

# Sets UCMD to the index of the custom command that failed, or "" when the
# failure was somewhere else (plain F2).
UCMD=""
failed_user_command() {
  UCMD="$(sed -nE 's/.*user-command\.([0-9]+)\.sh.*exit code.*/\1/p' \
            "${ARCHINSTALL_LOG}" 2>/dev/null | tail -1)" || UCMD=""
}

# The installed system is still there to chroot into: archinstall leaves /mnt
# mounted when it fails.
target_ready() {
  mountpoint -q /mnt && [[ -r /mnt/etc/passwd ]]
}

# custom_command <index> — that entry of the spliced config, or "".
custom_command() {
  jq -r --argjson i "$1" '.custom_commands[$i] // empty' "${CONFIG_RUN}" 2>/dev/null || true
}

# The likely cause, for the failure screen.
user_command_hint() {
  case "$1" in
    "git clone"*)
      echo "The clone failed: no network, or github.com unreachable?" ;;
    "git -C"*reset*)
      echo "The pin failed: is this ISO's commit on GitHub (built from an unpushed commit)?" ;;
    *)
      echo "The first-boot wiring failed; the log below has why." ;;
  esac
}

# Re-run custom_commands from UCMD on, in the target, as archinstall would.
# The output goes to the screen and the stage0 log (the commands hold no
# secrets). Sets WIRED=1 when every one succeeded; otherwise UCMD is left on
# the one that failed, so the next try starts there.
WIRED=0
retry_wiring() {
  local cmd rc
  WIRED=0
  while cmd="$(custom_command "${UCMD}")"; [[ -n "${cmd}" ]]; do
    say "Running in the installed system: ${cmd}"
    rc=0
    arch-chroot /mnt bash -c "${cmd}" 2>&1 | tee -a "${STAGE0_LOG}" || rc=$?
    if (( rc != 0 )); then
      err "That failed (exit ${rc}). $(user_command_hint "${cmd}")"
      return 0
    fi
    UCMD=$(( UCMD + 1 ))
  done
  slog "wiring complete"
  WIRED=1
}

# The F2/F3 screen and its menu. Sets NEXT to retry, edit or wired; Power off
# doesn't come back. The creds file only exists while a run or Shell needs it.
#
# Results go through variables, not the return status, here and in
# run_archinstall: a function whose status is tested runs with set -e and the
# ERR trap off, and that would blind F0 to everything below it.
NEXT=""
archinstall_failed() {
  local rc="$1" choice crc cmd
  local -a options
  failed_user_command
  if [[ -n "${UCMD}" ]]; then
    cmd="$(custom_command "${UCMD}")"
    slog "failed in custom command ${UCMD}: ${cmd}"
    ui_failure "archinstall failed in a custom command (exit ${rc})" "${ARCHINSTALL_LOG}" 30 \
      "The base system is installed, but Hashiru isn't wired in yet." \
      "Failed: ${cmd:-custom command ${UCMD}}" \
      "$(user_command_hint "${cmd}")" \
      "Retry wiring re-runs just the missing steps, after you fix that." \
      "Retry install runs archinstall again from scratch."
  else
    ui_failure "archinstall failed (exit ${rc})" "${ARCHINSTALL_LOG}" 30 \
      "Hashiru isn't installed, and ${LAST_TARGET} may be partly written." \
      "Retry runs archinstall again with the same answers." \
      "Edit answers goes back to the review."
  fi
  while true; do
    options=(Retry)
    if [[ -n "${UCMD}" ]]; then
      options=("Retry install")
      if target_ready; then
        options=("Retry wiring" "${options[@]}")
      else
        slog "/mnt isn't mounted with an installed system; no Retry wiring"
      fi
    fi
    crc=0
    choice="$(ui_choose "What now?" "${options[@]}" "Edit answers" Shell "Power off")" || crc=$?
    if (( crc != 0 )); then
      (( crc == 1 )) && ui_gum && continue
      exit "${crc}"
    fi
    slog "archinstall failed menu: ${choice}"
    case "${choice}" in
      "Retry wiring")
        retry_wiring
        (( WIRED )) && { NEXT=wired; return 0; } ;;
      Retry|"Retry install")
        release_target "${LAST_TARGET}" && { NEXT=retry; return 0; } ;;
      "Edit answers")
        release_target "${LAST_TARGET}" && { NEXT=edit; return 0; } ;;
      Shell)
        # The one path that keeps the creds: re-running by hand needs them.
        write_creds
        ui_note "To re-run by hand: archinstall --config ${CONFIG_RUN} --creds ${CREDS_RUN}"
        ui_note "${CREDS_RUN} holds your passwords; it is removed when you exit."
        drop_to_shell
        command rm -f "${CREDS_RUN}" ;;
      "Power off")
        power_off
        exit 1 ;;
    esac
  done
}

# Sets INSTALLED=1 once archinstall has succeeded, or leaves it 0 to go back to
# the review. archinstall's status is caught here rather than left to set -e: a
# failure gets the F2 menu, not the generic F0 one.
INSTALLED=0
run_archinstall() {
  local rc
  while true; do
    say "Launching archinstall — this installs the base system (several minutes)…"
    LAST_TARGET="${HDISK}"
    rc=0
    archinstall --config "${CONFIG_RUN}" --creds "${CREDS_RUN}" --silent || rc=$?
    # The live /root is tmpfs (RAM), but plaintext secrets don't stay around in
    # case the user pokes at the live session. A retry writes them again.
    command rm -f "${CREDS_RUN}"
    slog "archinstall exited ${rc}"
    if (( rc == 0 )); then
      INSTALLED=1
      echo
      return 0
    fi
    archinstall_failed "${rc}"
    if [[ "${NEXT}" == wired ]]; then
      INSTALLED=1
      return 0
    fi
    [[ "${NEXT}" == retry ]] || return 0
    write_creds
  done
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
#
# /mnt should still be mounted here (archinstall leaves it; offer_reboot
# unmounts), but a write through /mnt has failed silently before, so it is
# checked: an unmounted /mnt would put the keyfile in the live system, where it
# is lost on reboot. Any failure leaves WIFI_SEEDED=0 and the reboot screen
# says so; it never stops stage0, since the install itself is done.
WIFI_SEEDED=1
seed_wifi() {
  [[ -n "${WIFI_SSID}" ]] || return 0
  say "Seeding WiFi connection '${WIFI_SSID}' into the installed system…"
  WIFI_SEEDED=0
  if ! mountpoint -q /mnt || [[ ! -d /mnt/etc || ! -r /mnt/etc ]]; then
    slog "wifi seed skipped: /mnt isn't the installed system"
    return 0
  fi
  local nmdir="/mnt/etc/NetworkManager/system-connections" nmfile
  # Sanitise only the filename; id/ssid keep the exact SSID.
  nmfile="${nmdir}/$(printf '%s' "${WIFI_SSID}" | tr -c 'A-Za-z0-9._-' '_').nmconnection"
  # Tested, so set -e is off in write_keyfile and each step checks itself.
  if write_keyfile "${nmdir}" "${nmfile}" && [[ -s "${nmfile}" ]]; then
    WIFI_SEEDED=1
    slog "wifi seeded: ${nmfile}"
  else
    command rm -f "${nmfile}" 2>/dev/null || true
    slog "wifi seed failed: ${nmfile}"
  fi
}

write_keyfile() {
  local nmdir="$1" nmfile="$2"
  mkdir -p "${nmdir}" || return 1
  ( umask 077; cat > "${nmfile}" ) <<EOF || return 1
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
  chown 0:0 "${nmfile}" && chmod 600 "${nmfile}"
}

# For a prompt whose status is tested (so the ERR trap can't see it): Ctrl-C
# still stops stage0, anything else is left to the caller.
stop_on_ctrl_c() {
  (( $1 == 130 )) && exit 130
  return 0
}

drop_to_shell() {
  ui_note "A shell. Type 'exit' to come back here."
  bash -i < /dev/tty > /dev/tty 2>&1 || true
}

power_off() {
  slog "powering off"
  systemctl poweroff
}

# --- unexpected failures (F0) --------------------------------------------------
# set -E carries the ERR trap into every function and every $(…). In a subshell
# it must do nothing: whether a subshell's failure matters is its caller's call
# (`x="$(ui_choose …)" || rc=$?` is an answer, not a crash), and anything it
# printed to stdout would end up in x. So only the top-level shell acts, which
# also means one screen per failure rather than one per nesting level. ERR
# follows set -e's rules, so nothing inside an `if`, `&&` or `||` gets here.
on_err() {
  local rc="$1" line="$2" fn="$3" cmd="$4"
  (( BASH_SUBSHELL == 0 )) || return 0
  trap - ERR
  set +e
  # Ctrl-C in gum comes back as a failed $(…) with status 130: a stop, not a
  # crash. on_exit says so.
  (( rc == 130 )) && exit 130

  command rm -f "${CREDS_RUN}"
  # One line: a multi-line command keeps its indentation otherwise.
  cmd="${cmd//$'\n'/ }"
  while [[ "${cmd}" == *"  "* ]]; do cmd="${cmd//  / }"; done
  slog "FAILED in ${fn}, line ${line}: ${cmd} (exit ${rc})"
  ui_failure "stage0 stopped unexpectedly" "${STAGE0_LOG}" 12 \
    "In ${fn}, line ${line} (exit ${rc}):" \
    "  ${cmd}" \
    "Shell to look around, or Power off and boot the ISO again."

  local choice crc
  while true; do
    crc=0
    choice="$(ui_choose "What now?" Shell "Power off")" || crc=$?
    if (( crc != 0 )); then
      (( crc == 1 )) && ui_gum && continue
      exit "${rc}"
    fi
    case "${choice}" in
      Shell)       drop_to_shell ;;
      "Power off") power_off; exit "${rc}" ;;
    esac
  done
}

# 130 is Ctrl-C, from wherever it came: gum's status, review's exit, or the INT
# trap for a plain read. One line, no failure screen.
on_exit() {
  local rc=$?
  if (( rc == 130 )); then
    slog "stopped by the user"
    ui_warn "Stopped."
  fi
}

offer_reboot() {
  ok "Base install complete. Hashiru will bootstrap automatically on first boot."
  if (( ! WIFI_SEEDED )); then
    warn "Couldn't save WiFi '${WIFI_SSID}' into the installed system, so it boots without WiFi."
    warn "First boot needs the network: log in, connect with 'nmtui', then reboot to resume."
  fi
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

  # Here rather than at the top, so sourcing this file for tests doesn't arm it.
  set -E
  trap 'on_err $? "${LINENO}" "${FUNCNAME[0]:-main}" "${BASH_COMMAND}"' ERR
  trap 'exit 130' INT
  trap on_exit EXIT
  if (( DRY_RUN )); then slog "stage0 started (dry run)"; else slog "stage0 started"; fi

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

  # Round again from the review when a failed install's "Edit answers" says so.
  while true; do
    review
    splice_config
    write_creds

    if (( DRY_RUN )); then
      show_dry_run
      return 0
    fi

    run_archinstall
    (( INSTALLED )) && break
  done
  seed_wifi
  offer_reboot
}

# Run only when executed; sourcing (tests) just defines the functions.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
