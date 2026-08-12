# Hashiru

<img width="1920" height="1200" alt="image" src="https://github.com/user-attachments/assets/94fcf733-6785-42cf-9537-7d416c03a3e2" />

---

Hashiru (走る, "to run") is my personal Arch + Hyprland bootstrap. It takes a
machine from bare metal to a working Wayland desktop in about 10 minutes.

It's opinionated and built for me. Same result every time, customization lives
in the code, not in prompts.

## Install (ISO)

This is how I install. Build a live ISO that does the whole thing: prompts for
a few machine-specific answers, installs an encrypted base Arch system with
`archinstall`, then runs the Hashiru stages automatically on first boot.

```bash
sudo pacman -S archiso          # one-time
sudo ./iso/build.sh             # -> iso/out/hashiru-*.iso
```

Flash `iso/out/hashiru-*.iso`, boot it, and answer the prompts (username,
password, timezone, hostname, target disk). Everything else is fixed in
`iso/archinstall/user_config.json`.

See `iso/README.md` for the build internals, QEMU testing, and the fragile
bits to watch (mainly archinstall schema drift).

## Install (manual)

On an existing base Arch system:

```bash
git clone https://github.com/whleucka/hashiru.git && cd hashiru && ./install.sh
```

Run a single stage with `./install.sh 30`, resume a failed run from a stage
onward with `./install.sh 30+` (or `--from 30`), run several with
`./install.sh 30 35`, and list stages with `./install.sh --list`.

## Stages

| Stage | Script | What it does |
|-------|--------|--------------|
| 10 | `10-base.sh` | Update, base packages, microcode, firmware, NetworkManager, Bluetooth, TLP, cronie, zram, sysctl/udev |
| 15 | `15-grub.sh` | GRUB boot tune, regenerate `grub.cfg` (skipped on systemd-boot) |
| 20 | `20-aur.sh` | yay + AUR packages |
| 30 | `30-desktop.sh` | Hyprland/Wayland stack, PipeWire, fonts, terminal tools, zsh, TTY1 auto-login |
| 35 | `35-zsh.sh` | Oh My Zsh, Powerlevel10k, plugins |
| 40 | `40-hyprland.sh` | Hyprland environment dirs |
| 45 | `45-config.sh` | Stow Hashiru's own config from `stow/`, bat cache, `hashiru` CLI |
| 50 | `50-snapper.sh` | Snapper + grub-btrfs (btrfs only) |
| 60 | `60-dotfiles.sh` | Clone + stow personal dotfiles, herdr binary |
| 99 | `99-reboot.sh` | Dev tools, desktop apps, Rust, user groups, verify, reboot |

## Config ownership

Hashiru installs to **`/opt/hashiru` and stays there.** The desktop config is
stowed out of that checkout, so the symlinks in `~/.config` point into
`/opt/hashiru/stow/` for the life of the machine. Don't move it.

`stow/` holds one GNU Stow package per config area, and Hashiru owns all of
them: `hyprland` (hypr, waybar, mako, swayosd, fuzzel, gtk-3.0,
xdg-desktop-portal, wallpapers), `kitty`, `thunar`, `yazi`, `bpytop`,
`chromium`, `bat`, `fzf`, `ripgrep`, `herdr`.

Personal config — shell, editor, git identity — stays in a separate dotfiles
repo (`~/.dotfiles`, stowed by stage 60): `zsh`, `bash`, `nvim`, `vim`, `git`,
`p10k`, `alias`, `functions`, `scripts`. The two sets are disjoint; stage 60
skips anything Hashiru owns so a stale dotfiles checkout can't stow over it.

That repo is **optional and configurable.** The shipped default is the author's,
but nothing Hashiru owns depends on it. Copy `hashiru.conf.example` to
`hashiru.conf` (gitignored, so it can't dirty the checkout and block
`hashiru update`) to point at your own, or set it empty to opt out entirely:

```bash
: "${HASHIRU_DOTFILES_REPO=https://github.com/you/dotfiles.git}"
: "${HASHIRU_DOTFILES_REPO=}"   # no dotfiles at all
```

With no repo configured, stage 60 still stows an existing `~/.dotfiles` if one
is there — it just won't clone or pull — and `doctor` reports the dotfiles
section as skipped rather than failed.

### The zsh fallback

`stow/zsh-fallback` is the one package Hashiru does **not** stow
unconditionally. Stage 35 installs zsh, Oh My Zsh, Powerlevel10k and three
plugins and makes zsh the login shell, then deletes omz's generated `.zshrc` on
the assumption that dotfiles provide one. With dotfiles opted out, nothing does.

So it is stowed only when nothing else supplies `~/.zshrc`, and unstowed again
the moment something does — a dotfiles repo that ships one, or a file you wrote
yourself. Hashiru doesn't own your shell config; it just won't leave the shell it
configured without one. Put machine-local settings in `~/.zshrc.local`, which the
fallback sources and `hashiru update` never touches.

The decision (`ensure_zshrc` in `lib/common.sh`) runs twice per install: in
stage 45, so `hashiru update 45` is complete on its own, and again in stage 60
*before* the dotfiles are stowed, where the checkout exists and the answer is
exact rather than guessed. The second call is what clears the fallback out of
the way so a dotfiles `zsh` package can claim the path — and what keeps the
fallback when the repo turns out not to ship one.

Note the split is by *ownership*, not by directory: `stow/` is user config
(`$HOME`), while the older `config/` directory is system config (`/etc`) that
gets copied, not stowed.

## Updating an installed machine

```bash
hashiru update          # pull, then replay every stage
hashiru update 45+      # pull, then run stage 45 onward
hashiru update 45       # config only — the common case
hashiru status          # commit, install date, commits behind origin
```

There is no diffing or migration engine: every stage is idempotent and
`stow --restow` reconciles added, removed and renamed config files on its own,
so replaying the install *is* the update. `hashiru update` refuses to run with
a dirty `/opt/hashiru`, and re-stamps `/etc/hashiru-release` afterwards.

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

## Health check

```bash
hashiru doctor          # or ./doctor.sh
```

Read-only audit of an installed machine: packages vs. the manifests, services,
desktop stack, shell, storage, stowed config, dotfiles. Exits non-zero on
failures. Deliberately never modifies anything — it has to be safe to run on a
machine that is already broken; `hashiru update` is the thing that repairs.
Every full `./install.sh` run also stamps `/etc/hashiru-release` with the commit
and date it was bootstrapped from.

## Notes

* Arch only, Hyprland only. No other distros or WMs.
* Work in progress. Breaking changes are expected.
