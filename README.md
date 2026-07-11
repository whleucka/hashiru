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

Run a single stage with `./install.sh 30`.

## Stages

| Stage | Script | What it does |
|-------|--------|--------------|
| 10 | `10-base.sh` | Update, base packages, microcode, firmware, NetworkManager, Bluetooth, TLP, cronie, zram, sysctl/udev |
| 15 | `15-grub.sh` | GRUB boot tune, regenerate `grub.cfg` (skipped on systemd-boot) |
| 20 | `20-aur.sh` | yay + AUR packages |
| 30 | `30-desktop.sh` | Hyprland/Wayland stack, PipeWire, fonts, terminal tools, zsh, TTY1 auto-login |
| 35 | `35-zsh.sh` | Oh My Zsh, Powerlevel10k, plugins |
| 40 | `40-hyprland.sh` | Hyprland environment dirs |
| 50 | `50-snapper.sh` | Snapper + grub-btrfs (btrfs only) |
| 60 | `60-dotfiles.sh` | Clone + stow dotfiles, tmux/TPM, bat cache |
| 99 | `99-reboot.sh` | Dev tools, desktop apps, Rust, user groups, verify, reboot |

## Notes

* Arch only, Hyprland only. No other distros or WMs.
* Work in progress. Breaking changes are expected.
