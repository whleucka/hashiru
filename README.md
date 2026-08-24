# Hashiru

<img width="1920" height="1200" alt="image" src="https://github.com/user-attachments/assets/94fcf733-6785-42cf-9537-7d416c03a3e2" />

---

Hashiru (走る, "to run") is my personal Arch + Hyprland bootstrap. Bare metal to
a working Wayland desktop in about 10 minutes.

Looking for an alternative to Omarchy? You've found it.

## Install

**[Download the latest ISO](https://github.com/whleucka/hashiru/releases/latest)**
· `hashiru-YYYY.MM.DD-x86_64.iso`

Flash it, boot it, answer the prompts (username, password, timezone, hostname,
disk). It installs an encrypted base Arch system, then runs the Hashiru stages
on first boot while you go do something else. Bring a network connection,
because the ISO doesn't carry Hashiru, it clones it.

Each ISO is pinned to the commit it was built from, so the newest one gets you
that release rather than today's `main`. Run `hashiru update` once you're
booted.

To build the ISO yourself, which pins it to your current `HEAD`:

```bash
sudo pacman -S archiso
sudo ./iso/build.sh             # -> iso/out/hashiru-*.iso
```

### On an existing Arch system

```bash
sudo git clone https://github.com/whleucka/hashiru.git /opt/hashiru
sudo chown -R "${USER}:${USER}" /opt/hashiru
cd /opt/hashiru && ./install.sh
```

The checkout has to be yours, not root's. Anywhere other than `/opt/hashiru`
works, but pick the spot before you install: stow bakes that path into every
symlink it creates, so moving the repo later turns `~/.config` into a pile of
dead links.

## Commands

```bash
hashiru update          # pull, then replay every stage
hashiru update 45       # config only, the common case
hashiru install 45      # replay without pulling, for local edits
hashiru status          # commit, install date, how far behind origin
hashiru doctor          # read-only health check, fixes nothing
```

There's no diffing engine and no migration system. Every stage is idempotent, so
replaying the install *is* the update. `hashiru update` refuses to run on a dirty
checkout.

Stage selectors work the same on `install.sh` and `hashiru update`:

```
./install.sh            # everything, in order
./install.sh 45         # just stage 45
./install.sh 45+        # stage 45 onward, for resuming a failed run
./install.sh 30 45      # these two
./install.sh --list     # what stages exist
```

## What it installs

| Stage | Script | What it does |
|-------|--------|--------------|
| 10 | `10-base.sh` | Base packages, microcode, firmware, NetworkManager, Bluetooth, TLP, cronie, zram, sysctl/udev |
| 15 | `15-grub.sh` | GRUB boot tune. Skips itself on systemd-boot |
| 20 | `20-aur.sh` | yay, then AUR packages one at a time so one bad build can't take down the run |
| 30 | `30-desktop.sh` | Wayland stack, PipeWire, fonts, terminal tools, zsh as login shell, TTY1 auto-login |
| 35 | `35-zsh.sh` | Oh My Zsh, Powerlevel10k, plugins |
| 45 | `45-config.sh` | Stows Hashiru's own config from `stow/`, creates the override tree, puts `hashiru` on PATH |
| 50 | `50-snapper.sh` | Snapper + grub-btrfs, btrfs only |
| 60 | `60-herdr.sh` | Installs the herdr binary |
| 99 | `99-apps.sh` | Dev tools, desktop apps, Rust, user groups, final verification |

Package lists live in `pacman/*.txt`. Everything else — Hyprland, waybar, kitty,
the shell, the prompt, aliases, helper scripts — is configured from `stow/`,
which Hashiru owns and updates. To change any of it on one machine, see
[Making it yours](#making-it-yours) rather than editing the checkout.

More detail in [`docs/internals.md`](docs/internals.md). Where this is going:
[`docs/roadmap.md`](docs/roadmap.md).

## Making it yours

Hashiru owns everything in `stow/` and restows all of it on every update, so
editing a shipped config file is pointless at best. It will be reverted, or it
leaves the checkout dirty and `hashiru update` refuses to run. Machine-local
config goes in `~/.config/hashiru/` instead, which nothing in the install ever
writes over.

Monitors are the common case, and the only one you're likely to *need*:

```bash
cp /opt/hashiru/examples/hypr/monitors.thinkpad-t14s.lua \
   ~/.config/hashiru/hypr/monitors.lua      # then edit for your displays
hyprctl monitors all                        # names, descriptions, modes
```

Hashiru ships no real monitor layout of its own, just an auto-detect catch-all,
because `eDP-1` is the internal panel on every laptop and a hardcoded mode for
one of them is wrong for all the others.

Beyond that:

| Put a file here | Effect |
|---|---|
| `~/.config/hashiru/hypr/<module>.lua` | replaces that Hyprland module outright |
| `~/.config/hashiru/hypr/<module>.extra.lua` | runs after it, adding to it |
| `~/.config/hashiru/hypr/local.lua` | runs last — change any single setting from `hyprland.lua` |
| `~/.config/hashiru/kitty/*.conf` | read after `kitty.conf`, last-wins |
| `~/.config/hashiru/waybar/style.css` | cascades over the shipped bar styling |
| `~/.zshrc.local` | sourced by the shipped `.zshrc` |

Modules are `monitors`, `autostart`, `keybinds`, `windowrules`, `layerrules`,
`clamshell`. `local.lua` reaches the settings that aren't in a module, because a
later `hl.config` call wins per key and leaves the rest alone:

```lua
hl.config({ general = { gaps_in = 0, border_size = 1 } })
```

`hashiru doctor` lists what you've overridden and syntax-checks the Lua.

Anything not in that table (mako, fuzzel, thunar, yazi, waybar's `config.jsonc`) is Hashiru's outright. Fork the repo if you disagree with it.

## Contributing

Bug reports and fixes are welcome. If you do send a patch:

* Stages must be idempotent. Running one twice is normal and must not break.
* Scripts live with whatever invokes them, and carry no `.sh` extension:
  compositor scripts under `stow/hyprland/.config/{hypr,waybar}/scripts/`,
  herdr's helpers under `stow/herdr/.config/herdr/scripts/`, and anything you
  run yourself in `stow/bin/.local/bin/` (on PATH, so callers use a bare name).

## Notes

* Arch only. Hyprland only.
* Breaking changes are expected.
* Work in progress. 
