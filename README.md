# Hashiru

<img width="1920" height="1200" alt="image" src="https://github.com/user-attachments/assets/1ca9dccb-0e34-4998-9c63-8e4531aba1b6" />


Hashiru (走る, "to run") is an opinionated Arch + Hyprland bootstrap. One repo
installs the machine, then keeps owning its config.

This is a personal project.
An Omarchy alternative.
Use it, fork it, or steal the bits you like.

Documentation lives at **[hashiru.williamhleucka.com](https://hashiru.williamhleucka.com)**.

## Install from the ISO

**[Download the latest ISO](https://github.com/whleucka/hashiru/releases/latest)**
(`hashiru-YYYY.MM.DD-x86_64.iso`)

1. Flash it, boot it.
2. Answer the prompts: username, password, timezone, hostname, disk.
3. Go do something else.

It installs an encrypted base Arch system, reboots, then runs the Hashiru stages
on first boot. Bring a network connection, because the ISO clones Hashiru rather
than carrying it.

Each ISO is pinned to the commit it was built from, so the newest one gets you
that release rather than today's `main`. Run `hashiru update` once you are
booted.

Building the ISO yourself pins it to your current `HEAD`:

```bash
sudo pacman -S archiso
sudo ./iso/build.sh             # -> iso/out/hashiru-*.iso
```

## Install on an Arch system you already have

```bash
sudo git clone https://github.com/whleucka/hashiru.git /opt/hashiru
sudo chown -R "${USER}:${USER}" /opt/hashiru
cd /opt/hashiru && ./install.sh
```

The checkout has to be yours, not root's. Somewhere other than `/opt/hashiru`
works, but pick the spot before you install: stow bakes that path into every
symlink it creates, so moving the repo later turns `~/.config` into a pile of
dead links.

Expect a long first run, a pile of packages, and a reboot at the end.

## Once it is running

```bash
hashiru update          # pull, then replay every stage
hashiru update 45       # config only, the common case
hashiru update --no-confirm --no-reboot   # unattended, machine stays up
hashiru status          # commit, install date, checkout state, how far behind
hashiru version         # one line: what this machine is running
hashiru config          # edit this machine's overrides in $EDITOR
hashiru log --last      # what the last run actually did
hashiru doctor          # read-only health check, fixes nothing
hashiru help            # the rest of it
```

Every stage is idempotent, so replaying the install *is* the update. There is no
diffing engine and no migration system. `hashiru update` refuses to run on a
checkout with uncommitted changes to *tracked* files; untracked ones are left
alone and reported.

## Keybinds

`Super+/` lists every bind the running compositor has, type to filter. That is
the fastest way to learn them.

Two things worth knowing first: `SUPER` is the modifier for almost everything,
and **Caps Lock is a second Super**, so the whole set is reachable from home row.

Full list: **[keybinds](https://hashiru.williamhleucka.com/docs/keybinds.html)**.

## Changing things

Hashiru owns everything in `stow/` and restows all of it on every update, so
editing a shipped config file gets you nowhere. Machine-local config goes in
`~/.config/hashiru/`, which nothing in the install ever writes over.

Monitors are the one you are most likely to need:

```bash
cp /opt/hashiru/examples/hypr/monitors.thinkpad-t14s.lua \
   ~/.config/hashiru/hypr/monitors.lua      # then edit for your displays
hyprctl monitors all                        # names, descriptions, modes
```

Hyprland modules, kitty, waybar CSS and zsh all have override hooks. The full
table is in [configuration](https://hashiru.williamhleucka.com/docs/configuration.html#table),
and `hashiru doctor` tells you what you have overridden.

## Docs

Everything a user reads lives on the site:

| | |
|---|---|
| [Install](https://hashiru.williamhleucka.com/docs/install.html) | both paths, and what each stage does |
| [Keybinds](https://hashiru.williamhleucka.com/docs/keybinds.html) | every bind, and how to rebind them |
| [CLI](https://hashiru.williamhleucka.com/docs/cli.html) | every `hashiru` subcommand and flag |
| [Configuration](https://hashiru.williamhleucka.com/docs/configuration.html) | overrides, monitors, `hashiru.conf` |
| [Internals](https://hashiru.williamhleucka.com/docs/internals.html) | stages, layout, config ownership |
| [Roadmap](https://hashiru.williamhleucka.com/docs/roadmap.html) | where this is going, and why |

Two things stay in the repo, because something reads them here:

| | |
|---|---|
| [Releases](docs/releases/) | what changed, per tag — `hashiru changelog` reads these |
| [ISO](iso/README.md) | building and testing the installer image |

## Notes

* Arch only. Hyprland only.
* Breaking changes are expected.
* Bug reports and patches are welcome. Read
  [contributing](https://hashiru.williamhleucka.com/docs/internals.html#contributing) first, it is short.
