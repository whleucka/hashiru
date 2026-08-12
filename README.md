# Hashiru

<img width="1920" height="1200" alt="image" src="https://github.com/user-attachments/assets/94fcf733-6785-42cf-9537-7d416c03a3e2" />

---

Hashiru (走る, "to run") is my personal Arch + Hyprland bootstrap. Bare metal to
a working Wayland desktop in about 10 minutes.

It's opinionated and built for me. You're welcome to use it. It won't ask you
any questions about what you'd prefer.

## Install (ISO)

The ISO does everything. A few machine-specific prompts, an encrypted base Arch
system via `archinstall`, then the Hashiru stages run on first boot while you go
do something else.

**[Latest release](https://github.com/whleucka/hashiru/releases/latest)** ·
`hashiru-YYYY.MM.DD-x86_64.iso`

Every release ships a prebuilt ISO, pinned to the commit it was built from. The
installer clones this repo and hard-resets to that commit, so the two can't
drift. That also means the newest ISO gets you that release, not today's `main`.
Run `hashiru update` once you're booted.

Building it yourself pins to your current `HEAD`, which is what you want when
testing changes:

```bash
sudo pacman -S archiso          # one-time
sudo ./iso/build.sh             # -> iso/out/hashiru-*.iso
```

Either way: flash it, boot it, answer the prompts (username, password, timezone,
hostname, disk). Everything else is decided for you in
`iso/archinstall/user_config.json`. Bring a network connection, because the ISO
doesn't carry Hashiru, it clones it.

The installed system keeps the repo at `/opt/hashiru`, owned by you, with
`~/hashiru` and `/usr/local/bin/hashiru` pointing at it. First boot runs from a
systemd one-shot. If it dies, the unit stays enabled and retries next boot
instead of leaving you half a machine.

`iso/README.md` covers build internals, QEMU testing, and the parts most likely
to break (archinstall changes its schema whenever it feels like it).

## Install (manual)

On an existing base Arch system:

```bash
sudo git clone https://github.com/whleucka/hashiru.git /opt/hashiru
sudo chown -R "${USER}:${USER}" /opt/hashiru
cd /opt/hashiru && ./install.sh
```

The checkout has to be yours, not root's. Stages run unprivileged and call
`sudo` where needed, and `hashiru update` pulls as you.

```
./install.sh            # everything, in order
./install.sh 30         # just stage 30
./install.sh 30+        # stage 30 onward, for resuming a failed run
./install.sh 30 35      # these two
./install.sh --list     # what stages exist
```

`/opt/hashiru` is a convention, not a requirement. Pick the spot before you
install, though: stow bakes that path into every symlink it creates, so moving
the repo later turns `~/.config` into a pile of dead links.

## How it works

Ten numbered scripts in `scripts/`, run in order by `install.sh`. Every stage
can run twice without breaking anything. That property is load-bearing, because
it's the entire update mechanism.

A failed stage stops the run and tells you how to resume (`./install.sh 45+`).
Things Hashiru doesn't control get demoted to warnings: an AUR package that
won't build, a dotfiles repo that won't clone, a stow conflict. Those get
collected, printed at the end, and shown again at first login via
`/etc/profile.d/hashiru-report.sh`, because nobody reads scrollback.

A full run stamps `/etc/hashiru-release` with the commit and date that built the
machine. Single stages don't, since one stage isn't a bootstrap.

### Stages

| Stage | Script | What it does |
|-------|--------|--------------|
| 10 | `10-base.sh` | Update, `base.txt`, microcode, firmware, NetworkManager, Bluetooth, TLP, cronie, zram, sysctl/udev |
| 15 | `15-grub.sh` | GRUB boot tune, regenerate `grub.cfg`. Skips itself on systemd-boot |
| 20 | `20-aur.sh` | yay, then `aur.txt` one package at a time so one bad build can't take down the run |
| 30 | `30-desktop.sh` | `wayland.txt`, `terminal.txt`, `fonts.txt`, PipeWire, XDG dirs, zsh as login shell, TTY1 auto-login |
| 35 | `35-zsh.sh` | Oh My Zsh, Powerlevel10k, three plugins |
| 40 | `40-hyprland.sh` | Makes a screenshots directory. That's it. The Hyprland config is stage 45's problem |
| 45 | `45-config.sh` | Stows Hashiru's own config from `stow/`, zsh fallback, bat cache, `hashiru` on PATH |
| 50 | `50-snapper.sh` | Snapper + grub-btrfs, btrfs only |
| 60 | `60-dotfiles.sh` | Clones and stows personal dotfiles if you have them, installs herdr |
| 99 | `99-reboot.sh` | `dev.txt`, `apps.txt`, Rust toolchain, user groups, final verification |

Stage 99 does not reboot. It's still called `99-reboot.sh` because renaming it
would change the ordering. The reboot moved to the end of `install.sh`, after
the release stamp gets written, since a stage that reboots first means a full
install can never record which commit built it.

### Layout

```
install.sh          orchestrator
doctor.sh           read-only health check
bin/hashiru         the CLI, symlinked to /usr/local/bin/hashiru
scripts/NN-*.sh     stages, numeric prefix required
lib/common.sh       logging, package helpers, stow helpers
pacman/*.txt        package manifests
stow/               Hashiru's user config ($HOME), stow packages
config/             Hashiru's system config (/etc), copied not stowed
tools/              one-off maintenance, never runs during an install
iso/                ISO build, archinstall config, firstboot units
```

Only numbered scripts in `scripts/` are stages. One-off maintenance lives in
`tools/` so it can't get swept into a full run, which it did once, and that was
enough.

## Config ownership

Split by ownership, not by directory:

- **`stow/`** is user config Hashiru owns. Symlinked into `$HOME` with stow.
- **`config/`** is system config Hashiru owns. Copied into `/etc`.
- **`~/.dotfiles`** is yours. Hashiru doesn't own it and doesn't need it.

`stow/` has one package per area: `hyprland` (hypr, waybar, mako, swayosd,
fuzzel, gtk-3.0, xdg-desktop-portal, wallpapers), `kitty`, `thunar`, `yazi`,
`bpytop`, `chromium`, `bat`, `fzf`, `ripgrep`, `herdr`, `zsh-fallback`.

The desktop hand-off belongs to Hashiru too: `stow/hyprland/.zprofile` starts
Hyprland on TTY1, and `10-hashiru.conf` under `environment.d` sets the session
environment. Stage 30 used to append both to files it didn't own.

Personal config (shell, editor, git identity) lives in `~/.dotfiles`, stowed by
stage 60. The two sets don't overlap. Stage 60 skips anything in
`HASHIRU_OWNED`, so an old dotfiles checkout can't stow over Hashiru's copies.

### Dotfiles are optional

The default is my dotfiles repo. You almost certainly don't want my aliases, so
copy `hashiru.conf.example` to `hashiru.conf` and point it elsewhere, or turn it
off:

```bash
: "${HASHIRU_DOTFILES_REPO=https://github.com/you/dotfiles.git}"
: "${HASHIRU_DOTFILES_REPO=}"   # none at all
```

`hashiru.conf` is gitignored on purpose. `hashiru update` refuses to run on a
dirty checkout, so a tracked config file would brick updates on any machine you
customized.

Stage 60 assumes your repo is stow-shaped: one package per top-level directory,
each mirroring `$HOME`. That's my layout. If yours is different, set the
variable empty and manage your own config, which you were going to do anyway.

A failed clone is a warning, not a fatal error. Dotfiles aren't load-bearing,
and a typo'd URL used to kill the whole bootstrap, which on the ISO path meant
firstboot retried forever. Clones run with `GIT_TERMINAL_PROMPT=0` and
`ssh -o BatchMode=yes`, so a private repo fails immediately instead of waiting
on a password prompt nothing can answer. SSH URLs need their host key in
`known_hosts` beforehand.

### The zsh fallback

`stow/zsh-fallback` is the only package not stowed unconditionally.

Stage 35 installs zsh, Oh My Zsh, Powerlevel10k and three plugins, makes zsh
your login shell, then clears the generated `.zshrc` assuming dotfiles will
supply a real one. Turn dotfiles off and nothing does. You get a bare prompt
with a fully configured shell sitting there unused.

So it's stowed only when nothing else provides `~/.zshrc`, and unstowed the
moment something does. Hashiru doesn't own your shell config, it just refuses to
leave the shell it configured with nothing configuring it. Machine-local
settings go in `~/.zshrc.local`, which it sources and updates never touch.

`ensure_zshrc` in `lib/common.sh` decides this twice: in stage 45, so
`hashiru update 45` works alone, and again in stage 60 *before* the dotfiles get
stowed, where the answer is a fact instead of a guess.

That order is not negotiable. Run it after the stow loop instead and the
fallback is still holding `~/.zshrc` when your `zsh` package tries to claim it.
That package fails, the fallback then removes itself, and you end up with no
`.zshrc` at all. Ask me how I know.

An existing `~/.zshrc` gets backed up to `.zshrc.pre-hashiru`. Only an untouched
Oh My Zsh template is deleted outright.

## Updating

```bash
hashiru update          # pull, then replay every stage
hashiru update 45       # config only, the common case
hashiru install 45      # replay without pulling, for local edits
hashiru status          # commit, install date, how far behind origin
hashiru doctor          # health check
```

No diffing engine, no migration system. Every stage is idempotent and
`stow --restow` sorts out added, removed and renamed files by itself, so
replaying the install *is* the update.

`hashiru update` refuses to run on a dirty checkout. Local changes are fine,
they just need committing or stashing on purpose rather than by accident.

### Migrating an older machine

Machines built when the desktop config still lived in the dotfiles repo need a
one-time handover. Get the repo to `/opt/hashiru` first, since stow writes the
source path into every symlink and moving it afterwards means a full re-stow:

```bash
sudo mv ~/hashiru /opt/hashiru
sudo chown -R "${USER}:${USER}" /opt/hashiru
ln -sfn /opt/hashiru ~/hashiru

# Older ISOs pinned the clone with `checkout --detach`, leaving no upstream for
# `hashiru update` to fast-forward. Get back on a branch:
git -C /opt/hashiru checkout main
```

Then hand over ownership:

```bash
/opt/hashiru/tools/migrate-desktop-config.sh --dry-run   # safe anywhere
/opt/hashiru/tools/migrate-desktop-config.sh             # from a TTY, Hyprland stopped
```

It unstows the Hashiru-owned packages from `~/.dotfiles`, stows the copies here,
checks every link resolves, and prints the `git rm` to clean up the dotfiles
side. It won't run under a live Hyprland session, because the config directory
vanishes for a few seconds in the middle and you'd be watching it happen.

Two things reliably block it, both reported up front instead of one crash at a
time: real files sitting where stowed config needs to go, and dangling symlinks
anywhere in `~/.config`. Stow refuses to touch *any* package while a broken link
exists, including ones that have nothing to do with it.

Rollback is a `stow -D` and `stow` pair. Nothing is deleted until you run that
`git rm` yourself.

## Health check

```bash
hashiru doctor          # or ./doctor.sh
```

Read-only audit: install provenance, packages against the manifests, services,
desktop stack, shell, storage, stowed config, dotfiles. Non-zero exit on
failures.

It never fixes anything. It has to be safe to run on a machine that's already
broken, so it looks around, tells you what's wrong, and leaves. `hashiru update`
is the thing that repairs.

## Notes

* Arch only. Hyprland only.
* Open source, single user. The defaults are mine.
* Work in progress. Breaking changes are expected and there is no changelog.
