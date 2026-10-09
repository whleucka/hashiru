#!/usr/bin/env bash
# hashiru-firstboot.sh — runs once on first boot (as root, via systemd).
#
# Hashiru's install.sh must run as the unprivileged user and uses sudo. A
# systemd unit has no TTY to type a sudo password into, so we grant the user
# temporary passwordless sudo for the duration of the bootstrap and remove it
# afterwards. On success the unit disables itself; on failure it stays enabled
# so the next boot retries from the stage that failed, up to MAX_ATTEMPTS.
set -euo pipefail

: "${HASHIRU_USER:?HASHIRU_USER not set}"
# How many times first boot has failed so far, and the stage to resume from.
# Both live in the env file and are rewritten on each failure.
HASHIRU_FIRSTBOOT_ATTEMPTS="${HASHIRU_FIRSTBOOT_ATTEMPTS:-0}"
HASHIRU_RESUME_FROM="${HASHIRU_RESUME_FROM:-}"
readonly MAX_ATTEMPTS=3

# Every path below sits under ROOT, which is empty on a real boot. A test points
# it at a scratch tree.
ROOT="${HASHIRU_FIRSTBOOT_ROOT:-}"
SUDOERS="${ROOT}/etc/sudoers.d/hashiru-firstboot"
ENV_FILE="${ROOT}/etc/hashiru-firstboot.env"
# Read at every login by config/profile.d/hashiru-firstboot-failed.sh.
MARKER="${ROOT}/var/lib/hashiru/firstboot-failed"
# Permanent location — see install-firstboot.sh. ~/hashiru is a symlink here.
REPO="/opt/hashiru"
USER_UID="$(id -u "${HASHIRU_USER}")"
USER_HOME="$(getent passwd "${HASHIRU_USER}" | cut -d: -f6)"
# Written by install.sh when a stage fails, removed once it succeeds.
FAILED_STAGE_FILE="${ROOT}${USER_HOME}/.local/share/hashiru/failed-stage"
INSTALL_LOG="${USER_HOME}/.local/share/hashiru/install.log"

# Keeps the tty1 login prompt away while first boot runs (install-firstboot.sh).
GETTY_DROPIN="${ROOT}/etc/systemd/system/getty@tty1.service.d/10-hashiru-firstboot.conf"
# This boot only: /run is tmpfs. Sorts after both the drop-in above and stage
# 30's autologin.conf, so its resets win.
FAILED_DROPIN="${ROOT}/run/systemd/system/getty@tty1.service.d/zz-hashiru-failed.conf"
# Set just before `systemctl reboot`, so the trap can tell "we're on our way
# down" from "we died" — the two want opposite things done to tty1.
REBOOTING=0

# Hand tty1 back to a plain login prompt for the rest of this boot. Not
# autologin: once stage 30 and 45 have run, autologin starts Hyprland, right
# over the failure it should be showing. The runtime drop-in:
#   - cancels the gate's condition, so the getty runs now; the gate itself
#     stays, and keeps tty1 quiet while the next boot retries. An empty
#     ConditionPathExists= clears every one, getty@'s own /dev/tty0 check
#     included, so that one is put back.
#   - resets ExecStart to the stock prompt, dropping any --autologin
#   - keeps the screen: getty@ deallocates the VT when it starts, which would
#     wipe the failure screen before anyone could read it
restore_getty() {
  mkdir -p "${FAILED_DROPIN%/*}"
  cat > "${FAILED_DROPIN}" <<'DROPIN'
[Unit]
ConditionPathExists=
ConditionPathExists=/dev/tty0

[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --noreset --noclear - ${TERM}
TTYVTDisallocate=no
DROPIN
  systemctl daemon-reload
  systemctl start --no-block getty@tty1.service || true
}

# The stage install.sh last failed in ("50"), or nothing when it stopped
# before any stage (network check, sudo).
failed_stage() {
  local n
  n="$(cat "${FAILED_STAGE_FILE}" 2>/dev/null || true)"
  [[ "${n}" =~ ^[0-9]+$ ]] && echo "${n}"
  return 0
}

# "50-snapper.sh" for "50", for people to read.
stage_name() {
  local f
  for f in "${REPO}/scripts/$1"-*.sh; do
    [[ -e "${f}" ]] && { echo "${f##*/}"; return 0; }
  done
  echo "stage $1"
}

# Rewrite the env file in one move, so a power cut never leaves half of it.
write_env() {
  local tmp="${ENV_FILE}.new"
  {
    printf 'HASHIRU_USER=%s\n' "${HASHIRU_USER}"
    printf 'HASHIRU_FIRSTBOOT_ATTEMPTS=%s\n' "$1"
    [[ -n "$2" ]] && printf 'HASHIRU_RESUME_FROM=%s\n' "$2"
  } > "${tmp}"
  mv -f "${tmp}" "${ENV_FILE}"
}

# The failure path: count it, remember where to resume, leave a marker for the
# login notice, say so on tty1, and give up after MAX_ATTEMPTS.
on_failure() {
  local attempt stage name resume gave_up=0
  attempt=$(( HASHIRU_FIRSTBOOT_ATTEMPTS + 1 ))
  stage="$(failed_stage)"
  # A failure before any stage keeps the previous resume point.
  stage="${stage:-${HASHIRU_RESUME_FROM}}"
  name=""
  [[ -n "${stage}" ]] && name="$(stage_name "${stage}")"
  resume="hashiru install${stage:+ ${stage}+}"

  write_env "${attempt}" "${stage}"
  if (( attempt >= MAX_ATTEMPTS )); then
    gave_up=1
    systemctl disable hashiru-firstboot.service || true
    # Nothing will run first boot again, so nothing should hold tty1 back.
    rm -f "${GETTY_DROPIN}"
  fi

  mkdir -p "${MARKER%/*}"
  {
    printf 'stage=%s\n' "${name:-before the first stage}"
    printf 'attempt=%s\n' "${attempt}"
    printf 'max=%s\n' "${MAX_ATTEMPTS}"
    printf 'gave_up=%s\n' "${gave_up}"
    printf 'resume=%s\n' "${resume}"
    printf 'time=%(%F %T)T\n' -1
  } > "${MARKER}"
  chmod 644 "${MARKER}"

  # The journal gets plain lines, whatever tty1 shows.
  echo "!! Hashiru first boot failed${name:+ in ${name}} (attempt ${attempt} of ${MAX_ATTEMPTS})." >&2
  echo "!! Log: ${INSTALL_LOG}" >&2
  if (( gave_up )); then
    echo "!! No more automatic tries. After fixing it, run: ${resume}" >&2
  else
    echo "!! The next boot tries again${stage:+ from stage ${stage}}." >&2
  fi

  if [[ -w /dev/tty1 ]] && declare -F ui_failure >/dev/null; then
    local next
    if (( gave_up )); then
      next="That was the last automatic try: first boot won't run again."
    else
      next="The next boot tries again${stage:+, starting from ${name}}."
    fi
    ui_failure "First boot failed${name:+ in ${name}}" "${ROOT}${INSTALL_LOG}" 20 \
      "Attempt ${attempt} of ${MAX_ATTEMPTS}. ${next}" \
      "Log in below and look at the log: hashiru log" \
      "After fixing it, finish the install with: ${resume}" > /dev/tty1 2>&1 || true
  fi
}

cleanup() {
  rm -f "${SUDOERS}"
  (( REBOOTING )) || restore_getty
}
trap cleanup EXIT

# The unit has just hung up and reset tty1 (TTYVHangup/TTYReset), so the screen
# is whatever the kernel last left on it. Clear it and put Hashiru's name up
# before the bootstrap starts scrolling, so first boot reads as a deliberate
# install step rather than a machine talking to itself. Guarded: /dev/tty1
# doesn't exist on a serial-console or headless boot, where the journal is the
# only output that matters.
if [[ -w /dev/tty1 ]]; then
  # The shared installer UI, drawn on the block's stdout (tty1). It spots a VT
  # from where the fd points, not from TERM, which this unit doesn't set, and
  # loads the Tokyo Night palette before the clear so the background takes it.
  # The palette stays with the VT, so install.sh's progress line below inherits
  # it too.
  {
    # shellcheck source=lib/ui.sh
    source "${REPO}/lib/ui.sh"
    HASHIRU_UI_FD=1
    ui_console_palette
    printf '\033[H\033[2J'
    ui_banner "First boot"
    cat <<'MSG'
Setting up your Hyprland desktop. This downloads
and builds a fair amount, so it takes a while —
leave it alone and it will reboot when it's done.

A progress line follows below. The full output of
every stage goes to the install log instead of the
screen; after the reboot, read it with
`hashiru log` (or `hashiru report` for warnings).
MSG
    ui_rule
    echo
  } > /dev/tty1
fi

# archinstall copies its log onto the target world-readable, and it records the
# install, so it goes root-only whether or not this archinstall redacts it.
chmod -R go-rwx /var/log/archinstall 2>/dev/null || true

printf '%s ALL=(ALL) NOPASSWD: ALL\n' "${HASHIRU_USER}" > "${SUDOERS}"
chmod 440 "${SUDOERS}"

# Several stages call `systemctl --user` (PipeWire sockets, wireplumber).
# Those need a running per-user systemd instance and D-Bus session bus, which
# normally exist only inside a login session — and this unit runs the bootstrap
# via `sudo -u` from a *system* service, where there is none. Enable lingering
# so systemd starts the user manager now, then wait for its runtime bus socket
# before handing off.
echo "==> Enabling lingering user systemd instance for ${HASHIRU_USER}"
loginctl enable-linger "${HASHIRU_USER}"
for _ in $(seq 1 30); do
  [[ -S "/run/user/${USER_UID}/bus" ]] && break
  sleep 1
done
if [[ ! -S "/run/user/${USER_UID}/bus" ]]; then
  echo "!! user D-Bus session bus never appeared at /run/user/${USER_UID}/bus" >&2
  exit 1
fi

echo "==> Running Hashiru bootstrap as ${HASHIRU_USER}"
# Pass the user-session env so `systemctl --user` can connect, plus
# HASHIRU_UNATTENDED=1 (skip prompts, auto-reboot at the end). These are set
# inside the user's shell because sudo strips the environment.
#
# The bootstrap's own output goes straight to /dev/tty1 rather than through the
# unit's journal+console: in quiet mode install.sh draws a progress line with
# carriage returns, and a `\r`-redrawn bar recorded into the journal is
# unreadable noise. Same guard as the banner above — a serial-console or
# headless boot has no tty1, and there the unmodified stream is the only output
# there is, so the bar degrades to plain log lines on its own.
#
# What this costs: install.sh's stage-by-stage detail no longer reaches the
# journal. It is all in ~/.local/share/hashiru/install.log (`hashiru log`), and
# the ==>/!! lines below still go to the journal, which is what someone
# debugging a failed first boot as root before any login actually needs.
#
# A retry resumes at the stage that failed (stages are idempotent, so this only
# saves time), and still stamps /etc/hashiru-release: install.sh stamps full
# runs only, and a resumed first boot finishes the whole bootstrap.
run_bootstrap() {
  local args=""
  if [[ "${HASHIRU_RESUME_FROM}" =~ ^[0-9]+$ ]]; then
    args="${HASHIRU_RESUME_FROM}+"
    echo "==> Resuming from stage ${HASHIRU_RESUME_FROM} (attempt $(( HASHIRU_FIRSTBOOT_ATTEMPTS + 1 )) of ${MAX_ATTEMPTS})"
  fi
  sudo -u "${HASHIRU_USER}" -H bash -lc "
      export XDG_RUNTIME_DIR='/run/user/${USER_UID}'
      export DBUS_SESSION_BUS_ADDRESS='unix:path=/run/user/${USER_UID}/bus'
      ${args:+export HASHIRU_STAMP_UPDATED=1}
      cd '${REPO}' && HASHIRU_UNATTENDED=1 ./install.sh ${args}
    "
}
BOOTSTRAP_OK=1
if [[ -w /dev/tty1 ]]; then
  run_bootstrap > /dev/tty1 2>&1 || BOOTSTRAP_OK=0
else
  run_bootstrap || BOOTSTRAP_OK=0
fi
if [[ "${BOOTSTRAP_OK}" -eq 0 ]]; then
  on_failure
  exit 1
fi

# Disable the unit BEFORE rebooting so it never runs a second time. The bootstrap
# itself no longer reboots (see 99-apps.sh) — the reboot lives here, after the
# disable, so the disable can't be pre-empted by an in-bootstrap reboot. The EXIT
# trap (sudoers cleanup) still fires before the machine goes down.
systemctl disable hashiru-firstboot.service
# Also drop the env file: ConditionPathExists then blocks the unit for good,
# even if something re-enables it later. Dropping the getty drop-in alongside
# it keeps that gate honest — were the file left behind, anything that recreated
# the env file would silently suppress the tty1 login prompt as well. The
# marker and runtime drop-in go too: a retry that succeeds leaves no trace of
# the attempts before it.
rm -f "${ENV_FILE}" "${GETTY_DROPIN}" "${MARKER}" "${FAILED_DROPIN}"
echo "==> Hashiru bootstrap complete — rebooting into the finished system."
REBOOTING=1
systemctl reboot
