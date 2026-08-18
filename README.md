# Hashiru

<img width="1920" height="1200" alt="image" src="https://github.com/user-attachments/assets/94fcf733-6785-42cf-9537-7d416c03a3e2" />

---

Hashiru (走る, "to run") is my personal Arch + Hyprland bootstrap. Bare metal to
a working Wayland desktop in about 10 minutes.

It's opinionated and built for me. You're welcome to use it. It won't ask you
any questions about what you'd prefer.

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
| 40 | `40-hyprland.sh` | Makes a screenshots directory. That's it |
| 45 | `45-config.sh` | Stows Hashiru's own config from `stow/`, puts `hashiru` on PATH |
| 50 | `50-snapper.sh` | Snapper + grub-btrfs, btrfs only |
| 60 | `60-herdr.sh` | Installs the herdr binary |
| 99 | `99-reboot.sh` | Dev tools, desktop apps, Rust, user groups, final verification |

Package lists live in `pacman/*.txt`. Everything else — Hyprland, waybar, kitty,
the shell, the prompt, aliases, helper scripts — is configured from `stow/`,
which Hashiru owns and updates.

## Dotfiles

There aren't any. Hashiru doesn't clone a dotfiles repo, doesn't stow one, and
has no setting pointing at one. It installs the whole machine and the machine is
complete when it finishes.

That's a deliberate reversal of how this used to work, and the test that decided
it is: **would you want this on a machine Hashiru didn't build?** A shell prompt,
a file manager theme, a terminal colour scheme and a set of aliases all fail it —
they describe this machine, so they belong here. What passes is an editor config,
because that is what you actually miss when you ssh somewhere. So `nvim` and
`vim` live in a personal repo, and nothing in Hashiru knows or cares.

The practical benefit is that config and the thing that activates it stop living
in different repos. `stow/fzf` ships `fzfrc`; `stow/zsh` exports the
`FZF_DEFAULT_OPTS_FILE` that makes fzf read it. Those two used to be split across
Hashiru and a dotfiles checkout, and neither half worked on its own.

More detail on config ownership and updating is in
[`docs/internals.md`](docs/internals.md).

## Contributing

Bug reports and fixes are welcome. If you do send a patch:

* Stages must be idempotent. Running one twice is normal and must not break.
* Scripts the desktop invokes live beside the config that invokes them, under
  `stow/hyprland/.config/{hypr,waybar}/scripts/`, and carry no `.sh` extension.

## Notes

* Arch only. Hyprland only.
* Open source, single user. The defaults are mine.
* Work in progress. Breaking changes are expected and there is no changelog.
