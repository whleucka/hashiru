# Hashiru — Arch + Hyprland Bootstrap

> Fresh Arch ISO → fully functional Hyprland desktop in ~10 minutes.

## Principles

- **Reproducible:** Same result every time
- **Idempotent:** Safe to re-run any script
- **Opinionated:** Known hardware only, no portability concerns

---

## Target Machines

ThinkPad T14s (Intel/AMD), ThinkPad P43s, personal desktops.

---

## Pre-Bootstrap (archinstall)

Use `archinstall` with:
- **Filesystem:** btrfs with subvolumes `@`, `@home`, `@pkg`, `@snapshots`
- **Bootloader:** GRUB
- **Packages:** base, base-devel, git, networkmanager

Do **not** install Hyprland — Hashiru handles that.

---

## Repository Structure

```
hashiru/
├── install.sh              # Entry point orchestrator
├── lib/common.sh           # Logging, error handling, shared functions
├── scripts/                # Numbered phases (10-base.sh → 99-reboot.sh)
├── pacman/                 # Package manifests (*.txt per category)
├── config/                 # System configs (environment.d/, snapper/, sysctl/, udev/)
└── hypr/                   # Hyprland configuration
```

### Scripts

| Script | Purpose |
|--------|---------|
| `10-base.sh` | Core packages, microcode, firmware |
| `20-aur.sh` | Bootstrap yay, install AUR packages |
| `30-desktop.sh` | Wayland stack, PipeWire audio |
| `40-hyprland.sh` | Hyprland + supporting tools |
| `50-snapper.sh` | Snapshot config, grub-btrfs integration |
| `60-dotfiles.sh` | Clone and stow dotfiles |
| `99-reboot.sh` | Final verification, prompt reboot |

**Requirements:**
- All scripts idempotent
- Log to `~/.local/share/hashiru/install.log`
- Exit non-zero on failure; orchestrator halts
- No rollback — fix and re-run

---

## Package Categories

| Manifest | Contents |
|----------|----------|
| `base.txt` | Kernel, firmware, microcode, btrfs tools, snapper, networking, power management |
| `aur.txt` | yay-bin, oh-my-zsh-git, neovim-nightly-bin, LSPs (intelephense, pyright) |
| `wayland.txt` | Hyprland, xdg-portals, PipeWire, screen tools (grim, slurp), waybar, hyprlock |
| `terminal.txt` | kitty, zsh, starship, fzf, zoxide, bat, eza, ripgrep, fd, yazi, stow |
| `fonts.txt` | Noto family, JetBrains Mono Nerd, Cascadia Mono Nerd, Papirus icons |
| `dev.txt` | github-cli, LSPs, clang/llvm, rust, docker, mise, pnpm, composer |
| `apps.txt` | chromium, libreoffice-fresh, gimp |

Full package lists live in `pacman/*.txt`, not this spec.

---

## Key Configurations

**Environment** (`~/.config/environment.d/10-hashiru.conf`):
```ini
EDITOR=nvim
TERMINAL=kitty
BROWSER=chromium
XDG_SESSION_TYPE=wayland
QT_QPA_PLATFORM=wayland
```

**Snapper:** Timeline snapshots + snap-pac hooks + grub-btrfs for bootable snapshots.

**Hyprland:** Hardcoded monitor layouts, US keyboard, touchpad gestures, Super as mod.

**Dotfiles:** `git clone` → `stow */` — conflicts fail loudly.

---

## Post-Install (Manual)

Optional packages not automated: Steam, OBS, mpv, VS Code, JetBrains IDEs.
