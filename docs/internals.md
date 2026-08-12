# Internals

The stuff that doesn't belong in the README. Read this when something breaks or
you're changing how Hashiru works.

## Run mechanics

Ten numbered scripts in `scripts/`, run in order by `install.sh`. Every stage can
run twice without breaking anything. That property is load-bearing, because it's
the entire update mechanism.

A failed stage stops the run and tells you how to resume (`./install.sh 45+`).
Things Hashiru doesn't control get demoted to warnings: an AUR package that won't
build, a dotfiles repo that won't clone, a stow conflict. Those get collected,
printed at the end, and shown again at first login via
`/etc/profile.d/hashiru-report.sh`, because nobody reads scrollback.

A full run stamps `/etc/hashiru-release` with the commit and date that built the
machine. Single stages don't, since one stage isn't a bootstrap. `hashiru update`
re-stamps either way.

Stage 99 does not reboot, despite the name. Renaming it would change the
ordering. The reboot moved to the end of `install.sh`, after the release stamp
gets written, since a stage that reboots first means a full install can never
record which commit built it. Unattended runs never prompt: the firstboot wrapper
reboots after disabling its own unit, and doing it any earlier produces a boot
loop.

## Layout

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

Stage 60 skips anything in `HASHIRU_OWNED`, so an old dotfiles checkout can't
stow over Hashiru's copies.

### Dotfiles clone behaviour

A failed clone is a warning, not a fatal error. Dotfiles aren't load-bearing, and
a typo'd URL used to kill the whole bootstrap, which on the ISO path meant
firstboot retried forever. Clones run with `GIT_TERMINAL_PROMPT=0` and
`ssh -o BatchMode=yes`, so a private repo fails immediately instead of waiting on
a password prompt nothing can answer. SSH URLs need their host key in
`known_hosts` beforehand.

With no repo configured, stage 60 still stows an existing `~/.dotfiles` if it
finds one. It just won't clone or pull.

## The zsh fallback

`stow/zsh-fallback` is the only package not stowed unconditionally.

Stage 35 installs zsh, Oh My Zsh, Powerlevel10k and three plugins, makes zsh the
login shell, then clears the generated `.zshrc` assuming dotfiles will supply a
real one. Turn dotfiles off and nothing does. You get a bare prompt with a fully
configured shell sitting there unused.

So it's stowed only when nothing else provides `~/.zshrc`, and unstowed the
moment something does. Hashiru doesn't own your shell config, it just refuses to
leave the shell it configured with nothing configuring it. Machine-local settings
go in `~/.zshrc.local`, which it sources and updates never touch.

`ensure_zshrc` in `lib/common.sh` decides this twice: in stage 45, so
`hashiru update 45` works alone, and again in stage 60 **before** the dotfiles get
stowed, where the answer is a fact instead of a guess.

That order is not negotiable. Run it after the stow loop instead and the fallback
is still holding `~/.zshrc` when your `zsh` package tries to claim it. That
package fails, the fallback then removes itself, and you end up with no `.zshrc`
at all.

An existing `~/.zshrc` gets backed up to `.zshrc.pre-hashiru`. Only an untouched
Oh My Zsh template is deleted outright.

## Migrating an older machine

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

## ISO

`iso/README.md` covers build internals, QEMU testing, and the parts most likely
to break (archinstall changes its schema whenever it feels like it).

The installed system keeps the repo at `/opt/hashiru`, owned by the user, with
`~/hashiru` and `/usr/local/bin/hashiru` pointing at it. First boot runs from a
systemd one-shot. If it dies, the unit stays enabled and retries next boot
instead of leaving half a machine.
