# Hashiru

<img width="1920" height="1200" alt="image" src="https://github.com/user-attachments/assets/94fcf733-6785-42cf-9537-7d416c03a3e2" />

---

Hashiru is an opinionated, personal Arch Linux bootstrap designed to get my machines from a bare Arch ISO to a fully working Hyprland desktop in minutes.

## What is Hashiru?

**Hashiru** (走る, "to run") is a scripted setup that:

* Starts with a clean Arch Linux install
* Applies sane defaults and best practices
* Installs a Hyprland-based Wayland desktop
* Pulls in my dotfiles and system preferences
* Boots straight into a usable, polished system

The goal is simple: **Arch ISO to fully configured desktop in ~10 minutes.**

## Status

Work in progress. This project evolves as my workflow evolves. Breaking changes are expected.

## Philosophy

* **Opinionated by design** - built for me
* **Fast over flexible** - customization happens in code, not prompts
* **Reproducible** - same result every time
* **Minimal ceremony** - no bloated abstractions
* **Arch-native** - trust the Arch Wiki, not magic

## High-Level Flow

1. Install Arch using `archinstall`
2. Reboot into base system
3. Run the one-liner:

```bash
git clone https://github.com/whleucka/hashiru.git && cd hashiru && ./install.sh
```

You can also run a single stage, e.g. `./install.sh 30`.

Hashiru then runs these stages in order:

| Stage | Script | What it does |
|-------|--------|--------------|
| 10 | `10-base.sh` | System update, base packages, microcode, firmware, NetworkManager, Bluetooth, TLP, sysctl/udev configs |
| 20 | `20-aur.sh` | Bootstrap yay, install AUR packages (neovim-nightly, chromium, etc.) |
| 30 | `30-desktop.sh` | Wayland/Hyprland stack, PipeWire audio, fonts, terminal tools, zsh default shell, TTY1 auto-login |
| 35 | `35-zsh.sh` | Oh My Zsh, Powerlevel10k theme, zsh plugins |
| 40 | `40-hyprland.sh` | Prepare Hyprland environment directories |
| 50 | `50-snapper.sh` | Snapper btrfs snapshots, grub-btrfs integration (skipped if not btrfs) |
| 60 | `60-dotfiles.sh` | Clone dotfiles, stow configs, TPM + tmux plugins, bat cache |
| 99 | `99-reboot.sh` | Dev tools, desktop apps, Rust toolchain, user groups, verification, reboot prompt |

## Non-Goals

* Supporting other distros
* Supporting other window managers
* Endless customization toggles
* Being beginner-friendly

Hashiru assumes you know what you're doing, or you're okay fixing it if you break it.

## Target Machines

* ThinkPad T14s / P43s

Hardware support is intentional and explicit.
