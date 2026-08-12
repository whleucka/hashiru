# Hashiru

<img width="1920" height="1200" alt="image" src="https://github.com/user-attachments/assets/94fcf733-6785-42cf-9537-7d416c03a3e2" />

---

Hashiru (走る, "to run") is my personal Arch + Hyprland bootstrap. It takes a
machine from bare metal to a working Wayland desktop in about 10 minutes.

It's opinionated and built for me. Same result every time, customization lives
in the code, not in prompts.

## Install (ISO)

This is how I install. A live ISO does the whole thing: prompts for a few
machine-specific answers, installs an encrypted base Arch system with
`archinstall`, then runs the Hashiru stages automatically on first boot.

### Download one

Every release ships a prebuilt ISO, so there's nothing to build:

**[Latest release →](https://github.com/whleucka/hashiru/releases/latest)** —
`hashiru-YYYY.MM.DD-x86_64.iso`

Each ISO is pinned to the exact commit it was built from: the installer clones
this repo and `reset --hard`s to that commit, so the ISO and the code it installs
can't drift apart. That also means a downloaded ISO installs *that* release, not
whatever `main` looks like today — run `hashiru update` once you're booted to
catch up.

### Or build one

```bash
sudo pacman -S archiso          # one-time
sudo ./iso/build.sh             # -> iso/out/hashiru-*.iso
```

Building pins the ISO to your current `HEAD`, which is what you want when
testing changes — the installed system gets the code you're holding, not what's
on GitHub.

### Either way

Flash the ISO, boot it, and answer the prompts (username, password, timezone,
hostname, target disk). Everything else is fixed in
`iso/archinstall/user_config.json`. The target machine needs a network
connection: the installer clones Hashiru from GitHub rather than carrying it in
the ISO.

The installed system keeps the repo at `/opt/hashiru`, owned by your user, with
`~/hashiru` and `/usr/local/bin/hashiru` symlinked to it. First boot runs the
stages unattended from a systemd one-shot; if the bootstrap fails, the unit
stays enabled and retries on the next boot rather than leaving a half-built
machine.

See `iso/README.md` for the build internals, QEMU testing, and the fragile
bits to watch (mainly archinstall schema drift).

## Install (manual)

On an existing base Arch system:

```bash
sudo git clone https://github.com/whleucka/hashiru.git /opt/hashiru
sudo chown -R "${USER}:${USER}" /opt/hashiru
cd /opt/hashiru && ./install.sh
```

The checkout must be owned by your user, not root: the stages run unprivileged
(calling `sudo` only where needed), and `hashiru update` pulls as you.

```
./install.sh            # every stage, in order
./install.sh 30         # just stage 30
./install.sh 30+        # stage 30 onward — resume a failed run
./install.sh --from 30  # same thing
./install.sh 30 35      # several specific stages
./install.sh --list     # what stages exist
```

`/opt/hashiru` is a convention, not a requirement — everything derives from
wherever the checkout actually is. But stow bakes that path into every symlink
it creates, so pick the location *before* installing; moving it afterwards
breaks the desktop. Stage 45 says so out loud if you install from elsewhere.

## How it works

Ten numbered stage scripts in `scripts/`, run in order by `install.sh`. Each one
is idempotent and safe to re-run — that property is what makes updating work
later, so it isn't optional.

A stage failing aborts the whole run: `install.sh` prints how to resume
(`./install.sh 45+`) and stops. Things genuinely outside Hashiru's control —
an AUR package that won't build, a dotfiles repo that won't clone, a stow
conflict — degrade to warnings instead, get collected into a digest printed at
the end, and are shown again on first login via `/etc/profile.d/hashiru-report.sh`
so an unattended install's warnings aren't lost.

A full run stamps `/etc/hashiru-release` with the commit and date that built the
machine. Single-stage runs don't, since they don't represent a whole bootstrap —
but `hashiru update` re-stamps either way.

### Stages

| Stage | Script | What it does |
|-------|--------|--------------|
| 10 | `10-base.sh` | Update, `base.txt`, microcode, firmware, NetworkManager, Bluetooth, TLP, cronie, zram, sysctl/udev |
| 15 | `15-grub.sh` | GRUB boot tune, regenerate `grub.cfg` (skipped on systemd-boot) |
| 20 | `20-aur.sh` | yay, then `aur.txt` one package at a time so one bad build can't sink the run |
| 30 | `30-desktop.sh` | `wayland.txt`, `terminal.txt`, `fonts.txt`, PipeWire, XDG user dirs, zsh as login shell, TTY1 auto-login |
| 35 | `35-zsh.sh` | Oh My Zsh, Powerlevel10k, three plugins |
| 40 | `40-hyprland.sh` | Screenshots directory (the Hyprland config itself is stowed by 45) |
| 45 | `45-config.sh` | Stow Hashiru's own config from `stow/`, zsh fallback, bat cache, `hashiru` CLI on PATH |
| 50 | `50-snapper.sh` | Snapper + grub-btrfs (btrfs only) |
| 60 | `60-dotfiles.sh` | Clone + stow personal dotfiles (optional), herdr binary |
| 99 | `99-reboot.sh` | `dev.txt`, `apps.txt`, Rust toolchain, user groups, final verification |

Stage 99 does **not** reboot, despite the name. `/etc/hashiru-release` is written
after the stage loop, so rebooting from inside a stage meant a full interactive
install could never record its own commit. The reboot prompt lives at the end of
`install.sh` instead, and unattended runs never prompt at all — the firstboot
wrapper reboots after disabling its own unit.

### Repo layout

```
install.sh          orchestrator
doctor.sh           read-only health check
bin/hashiru         management CLI (symlinked to /usr/local/bin/hashiru)
scripts/NN-*.sh     the stages — numeric prefix required to be picked up
lib/common.sh       logging, package helpers, stow helpers
pacman/*.txt        package manifests, one per stage area
stow/               Hashiru-owned user config ($HOME), GNU Stow packages
config/             Hashiru-owned system config (/etc), copied not stowed
tools/              one-off maintenance, never run as part of an install
iso/                live-ISO build, archinstall config, firstboot units
```

Only numerically-prefixed scripts in `scripts/` are stages. Anything else there
is a helper; one-off maintenance lives in `tools/` so it can't be swept into a
full run.

## Config ownership

The split is by *ownership*, not by directory:

- **`stow/`** — user config Hashiru owns, symlinked into `$HOME` with GNU Stow.
- **`config/`** — system config Hashiru owns (`/etc`), copied into place.
- **`~/.dotfiles`** — personal config Hashiru does *not* own. Optional.

`stow/` holds one package per config area: `hyprland` (hypr, waybar, mako,
swayosd, fuzzel, gtk-3.0, xdg-desktop-portal, wallpapers), `kitty`, `thunar`,
`yazi`, `bpytop`, `chromium`, `bat`, `fzf`, `ripgrep`, `herdr`, and
`zsh-fallback` (see below).

The desktop hand-off belongs to Hashiru too: `stow/hyprland/.zprofile` starts
Hyprland on TTY1 and `stow/hyprland/.config/environment.d/10-hashiru.conf` sets
the session environment. Both used to be appended by stage 30, which left
ownership ambiguous — they're config, so they live with the config and update
like everything else.

Personal config — shell, editor, git identity — stays in a separate dotfiles
repo (`~/.dotfiles`, stowed by stage 60): `zsh`, `bash`, `nvim`, `vim`, `git`,
`p10k`, `alias`, `functions`, `scripts`. The two sets are disjoint; stage 60
skips anything Hashiru owns (`HASHIRU_OWNED`) so a stale dotfiles checkout can't
stow over it.

### Personal dotfiles are optional

The shipped default is my repo, but nothing Hashiru owns depends on it. Copy
`hashiru.conf.example` to `hashiru.conf` to point somewhere else, or opt out:

```bash
: "${HASHIRU_DOTFILES_REPO=https://github.com/you/dotfiles.git}"
: "${HASHIRU_DOTFILES_REPO=}"   # no dotfiles at all
: "${HASHIRU_DOTFILES_DIR=${HOME}/.dotfiles}"
```

`hashiru.conf` is gitignored on purpose: `hashiru update` refuses to run on a
dirty checkout, so a tracked config file would make every customized machine
un-updatable the moment it was edited. Use the `: "${VAR=value}"` form so
one-off environment overrides still win.

Stage 60 assumes the repo is stow-shaped — each top-level directory is a package
mirroring `$HOME`. That's my layout; a repo organized any other way should set
the variable empty and manage its own config.

With no repo configured, stage 60 still stows an existing `~/.dotfiles` if one is
there — it just won't clone or pull — and `doctor` reports the dotfiles section
as skipped rather than failed.

A clone failure is a warning, not a fatal error: dotfiles aren't load-bearing,
and a typo'd URL used to abort the whole bootstrap — which on the ISO path meant
firstboot retried forever. Clones run with `GIT_TERMINAL_PROMPT=0` and
`ssh -o BatchMode=yes` so a private repo fails fast instead of blocking on a
prompt with no TTY to answer it. An SSH URL therefore needs its host key in
`known_hosts` before firstboot.

### The zsh fallback

`stow/zsh-fallback` is the one package Hashiru does **not** stow
unconditionally. Stage 35 installs zsh, Oh My Zsh, Powerlevel10k and three
plugins and makes zsh the login shell, then clears omz's generated `.zshrc` on
the assumption that dotfiles provide the real one. With dotfiles opted out,
nothing does, and you'd get a bare prompt with all of it installed but unwired.

So it's stowed only when nothing else supplies `~/.zshrc`, and unstowed the
moment something does — a dotfiles repo that ships one, or a file you wrote
yourself. Hashiru doesn't own your shell config; it just won't leave the shell it
configured without one. Machine-local settings go in `~/.zshrc.local`, which the
fallback sources and updates never touch.

`ensure_zshrc` (`lib/common.sh`) makes that decision twice per install: in stage
45, so `hashiru update 45` is complete on its own, and again in stage 60 *before*
the dotfiles are stowed, where the checkout exists and the answer is exact rather
than guessed. The order matters — running it after the stow loop instead means
the fallback is still holding `~/.zshrc` when your `zsh` package tries to claim
it, so that package fails and then the fallback removes itself, leaving no
`.zshrc` at all.

A real `~/.zshrc` that predates Hashiru is backed up to `.zshrc.pre-hashiru`
rather than deleted. Only an unmodified Oh My Zsh template is removed outright.

## Updating an installed machine

```bash
hashiru update          # pull, then replay every stage
hashiru update 45+      # pull, then run stage 45 onward
hashiru update 45       # config only — the common case
hashiru install 45      # replay without pulling — for local edits
hashiru status          # commit, install date, commits behind origin
hashiru doctor          # health check
```

There is no diffing or migration engine: every stage is idempotent and
`stow --restow` reconciles added, removed and renamed config files on its own,
so replaying the install *is* the update. Stage selectors pass straight through
to `install.sh`.

`hashiru update` refuses to run with a dirty checkout — local changes to a
machine's own config are legitimate, they just need committing or stashing
deliberately rather than by a tool. `hashiru install` skips the pull for
iterating on local edits. Both re-stamp `/etc/hashiru-release`.

### Migrating a machine installed before this layout

Machines bootstrapped when the desktop config still lived in the dotfiles repo
need a one-time ownership handover.

**Get the repo to `/opt/hashiru` first.** Stow writes the source path into every
symlink it creates, so migrating from `~/hashiru` points all of `~/.config`
there permanently — moving the repo afterwards leaves dangling links and needs a
full re-stow. Older installs kept the repo at `~/hashiru`; relocate before
migrating, not after:

```bash
sudo mv ~/hashiru /opt/hashiru
sudo chown -R "${USER}:${USER}" /opt/hashiru
ln -sfn /opt/hashiru ~/hashiru

# ISOs built before this layout pinned the clone with `checkout --detach`, which
# leaves no upstream for `hashiru update` to fast-forward. Get back on a branch:
git -C /opt/hashiru checkout main
git -C /opt/hashiru status          # confirm main tracks origin/main
```

Then hand over ownership:

```bash
/opt/hashiru/tools/migrate-desktop-config.sh --dry-run   # preview, safe anywhere
/opt/hashiru/tools/migrate-desktop-config.sh             # from a TTY, Hyprland stopped
```

It unstows the Hashiru-owned packages from `~/.dotfiles`, stows the copies in
this repo, verifies every link resolves here, and prints the `git rm` to clean
up the dotfiles side. It refuses to run under a live Hyprland session, because
the config directory briefly disappears mid-flight. Rollback is a `stow -D` /
`stow` pair, and nothing is deleted until you run that final `git rm` yourself.

Two things reliably block it, both reported up front rather than one crash at a
time: real files sitting where stowed config needs to go, and dangling symlinks
anywhere in `~/.config` (stow refuses to act on *any* package while one exists,
even an unrelated one).

## Health check

```bash
hashiru doctor          # or ./doctor.sh
```

Read-only audit of an installed machine, in sections: install provenance,
packages vs. the manifests, system services, desktop stack, shell, storage,
stowed config, dotfiles. Exits non-zero on failures.

It never modifies anything — it has to be safe to run on a machine that is
already broken. `hashiru update` is the thing that repairs.

## Notes

* Arch only, Hyprland only. No other distros or WMs.
* Open source, but built for one user. Defaults are mine.
* Work in progress. Breaking changes are expected.
