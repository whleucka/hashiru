# Hashiru

<img width="1920" height="1200" alt="image" src="https://github.com/user-attachments/assets/94fcf733-6785-42cf-9537-7d416c03a3e2" />

---

Hashiru (走る, "to run") is my personal Arch + Hyprland bootstrap. Bare metal to
a working Wayland desktop in about 10 minutes.

It's opinionated and built for me. You're welcome to use it. It won't ask you
any questions about what you'd prefer.

## Install (ISO)

A live ISO does everything. It asks for a few machine-specific answers, installs
an encrypted base Arch system with `archinstall`, then runs the Hashiru stages
on first boot while you go do something else.

### Download one

Every release ships a prebuilt ISO.

**[Latest release](https://github.com/whleucka/hashiru/releases/latest)** ·
`hashiru-YYYY.MM.DD-x86_64.iso`

Each ISO is pinned to the commit it was built from. The installer clones this
repo and hard-resets to that commit, so the ISO and the code it installs can't
drift apart. Downloading the newest ISO gets you that release, not whatever
`main` looks like today. Run `hashiru update` after first boot to catch up.

### Or build one

```bash
sudo pacman -S archiso          # one-time
sudo ./iso/build.sh             # -> iso/out/hashiru-*.iso
```

Building pins to your current `HEAD`. Use this when you're testing changes and
want the installed system to run the code you're actually holding.

### Either way

Flash it, boot it, answer the prompts (username, password, timezone, hostname,
target disk). Everything else is decided for you in
`iso/archinstall/user_config.json`.

Bring a network connection. The ISO doesn't carry Hashiru, it clones it.

The installed system keeps the repo at `/opt/hashiru`, owned by you, with
`~/hashiru` and `/usr/local/bin/hashiru` pointing at it. First boot runs the
stages from a systemd one-shot. If the bootstrap dies, the unit stays enabled
and tries again next boot instead of leaving you with half a machine.

`iso/README.md` has the build internals, QEMU testing, and the parts most likely
to break (archinstall changes its schema whenever it feels like it).

## Install (manual)

On an existing base Arch system:

```bash
sudo git clone https://github.com/whleucka/hashiru.git /opt/hashiru
sudo chown -R "${USER}:${USER}" /opt/hashiru
cd /opt/hashiru && ./install.sh
```

The checkout has to be yours, not root's. The stages run unprivileged and call
`sudo` where they need it, and `hashiru update` pulls as you.

```
./install.sh            # everything, in order
./install.sh 30         # just stage 30
./install.sh 30+        # stage 30 onward, for resuming a failed run
./install.sh --from 30  # same thing
./install.sh 30 35      # these two
./install.sh --list     # what stages exist
```

`/opt/hashiru` is a convention. Everything derives from wherever the checkout
actually lives, so anywhere works. Pick the spot before you install, though.
Stow bakes that path into every symlink it creates, so moving the repo later
turns `~/.config` into a pile of dead links. Stage 45 will mention it if you
install somewhere unusual.

## How it works

Ten numbered scripts in `scripts/`, run in order by `install.sh`. Every stage
can run twice without breaking anything. That property is load-bearing: it's the
entire update mechanism.

A stage failing stops the run. `install.sh` tells you how to resume
(`./install.sh 45+`) and gets out of the way. Things Hashiru doesn't control get
demoted to warnings instead: an AUR package that won't build, a dotfiles repo
that won't clone, a stow conflict. Those get collected and printed at the end,
then shown again at first login via `/etc/profile.d/hashiru-report.sh`, because
nobody reads scrollback.

A full run stamps `/etc/hashiru-release` with the commit and date that built the
machine. Single stages don't, since one stage isn't a bootstrap. `hashiru update`
re-stamps either way.

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
would change the ordering and I have better things to do. The reboot moved to
the end of `install.sh`, after `/etc/hashiru-release` gets written, because a
stage that reboots the machine before the stamp means a full interactive install
can never record which commit built it. Unattended runs don't prompt at all. The
firstboot wrapper reboots after disabling its own unit, and doing it any earlier
produces a boot loop.

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

Only numbered scripts in `scripts/` are stages. Everything else there is a
helper. One-off maintenance lives in `tools/` so it can't get swept into a full
run, which it did once, and that was enough.

## Config ownership

Split by ownership, not by directory:

- **`stow/`** is user config Hashiru owns. Symlinked into `$HOME` with stow.
- **`config/`** is system config Hashiru owns. Copied into `/etc`.
- **`~/.dotfiles`** is yours. Hashiru doesn't own it and doesn't need it.

`stow/` has one package per area: `hyprland` (hypr, waybar, mako, swayosd,
fuzzel, gtk-3.0, xdg-desktop-portal, wallpapers), `kitty`, `thunar`, `yazi`,
`bpytop`, `chromium`, `bat`, `fzf`, `ripgrep`, `herdr`, and `zsh-fallback`.

The desktop hand-off belongs to Hashiru too. `stow/hyprland/.zprofile` starts
Hyprland on TTY1 and `stow/hyprland/.config/environment.d/10-hashiru.conf` sets
the session environment. Stage 30 used to append both of those to files it
didn't own, which was a bad idea for the obvious reason.

Personal config (shell, editor, git identity) stays in a dotfiles repo at
`~/.dotfiles`, stowed by stage 60: `zsh`, `bash`, `nvim`, `vim`, `git`, `p10k`,
`alias`, `functions`, `scripts`. The two sets don't overlap. Stage 60 skips
anything in `HASHIRU_OWNED` so an old dotfiles checkout can't stow over
Hashiru's copies.

### Dotfiles are optional

The default is my dotfiles repo. You almost certainly don't want my aliases, so
copy `hashiru.conf.example` to `hashiru.conf` and point it somewhere else, or
turn it off:

```bash
: "${HASHIRU_DOTFILES_REPO=https://github.com/you/dotfiles.git}"
: "${HASHIRU_DOTFILES_REPO=}"   # none at all
: "${HASHIRU_DOTFILES_DIR=${HOME}/.dotfiles}"
```

`hashiru.conf` is gitignored on purpose. `hashiru update` refuses to run on a
dirty checkout, so a tracked config file would brick updates on any machine you
customized. Use the `: "${VAR=value}"` form so environment overrides still win.

Stage 60 assumes your repo is stow-shaped, one package per top-level directory,
each mirroring `$HOME`. That's my layout. If yours is different, set the
variable empty and manage your own config, which you were probably going to do
anyway.

With no repo configured, stage 60 still stows an existing `~/.dotfiles` if it
finds one. It just won't clone or pull. `doctor` reports the section as skipped
rather than failed.

A failed clone is a warning, not a fatal error. Dotfiles aren't load-bearing,
and a typo'd URL used to kill the entire bootstrap, which on the ISO path meant
firstboot retried forever. Clones run with `GIT_TERMINAL_PROMPT=0` and
`ssh -o BatchMode=yes` so a private repo fails immediately instead of blocking
on a password prompt that nothing can answer. SSH URLs need their host key in
`known_hosts` before firstboot.

### The zsh fallback

`stow/zsh-fallback` is the only package that isn't stowed unconditionally.

Stage 35 installs zsh, Oh My Zsh, Powerlevel10k and three plugins, makes zsh
your login shell, then clears the generated `.zshrc` assuming dotfiles will
provide a real one. Turn dotfiles off and nothing does. You get a bare prompt
with a fully configured shell sitting there unused.

So it gets stowed only when nothing else provides `~/.zshrc`, and unstowed the
moment something does, whether that's a dotfiles repo or a file you wrote
yourself. Hashiru doesn't own your shell config. It just refuses to leave the
shell it configured with nothing configuring it. Machine-local settings go in
`~/.zshrc.local`, which it sources and updates never touch.

`ensure_zshrc` in `lib/common.sh` makes that call twice per install. Once in
stage 45, so `hashiru update 45` works on its own. Again in stage 60 *before*
the dotfiles get stowed, where the checkout exists and the answer is a fact
instead of a guess.

The order is not negotiable. Run it after the stow loop and the fallback is
still holding `~/.zshrc` when your `zsh` package tries to claim it. That package
fails, then the fallback removes itself, and you end up with no `.zshrc` at all.
Ask me how I know.

A real `~/.zshrc` that predates Hashiru gets backed up to `.zshrc.pre-hashiru`.
Only an untouched Oh My Zsh template gets deleted outright.

## Updating

```bash
hashiru update          # pull, then replay every stage
hashiru update 45+      # pull, then stage 45 onward
hashiru update 45       # config only, the common case
hashiru install 45      # replay without pulling, for local edits
hashiru status          # commit, install date, how far behind origin
hashiru doctor          # health check
```

There's no diffing engine and no migration system. Every stage is idempotent and
`stow --restow` sorts out added, removed and renamed config files by itself, so
replaying the install *is* the update. Stage selectors pass straight through to
`install.sh`.

`hashiru update` refuses to run on a dirty checkout. Local changes to a machine's
own config are fine, they just need committing or stashing on purpose rather than
by accident. `hashiru install` skips the pull when you're iterating locally. Both
re-stamp `/etc/hashiru-release`.

### Migrating an older machine

Machines built when the desktop config still lived in the dotfiles repo need a
one-time handover.

Get the repo to `/opt/hashiru` first. Stow writes the source path into every
symlink, so migrating from `~/hashiru` points all of `~/.config` there
permanently, and moving it afterwards means a full re-stow. Relocate first:

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
/opt/hashiru/tools/migrate-desktop-config.sh --dry-run   # safe anywhere
/opt/hashiru/tools/migrate-desktop-config.sh             # from a TTY, Hyprland stopped
```

It unstows the Hashiru-owned packages from `~/.dotfiles`, stows the copies here,
checks every link resolves where it should, and prints the `git rm` for cleaning
up the dotfiles side. It won't run under a live Hyprland session, because the
config directory vanishes for a few seconds in the middle and you'd be watching
it happen.

Two things reliably block it, both reported up front instead of one crash at a
time: real files sitting where stowed config needs to go, and dangling symlinks
anywhere in `~/.config`. Stow refuses to touch *any* package while a broken link
exists, including packages that have nothing to do with it.

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
