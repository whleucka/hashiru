# Hashiru — Arch + Hyprland Bootstrap Plan

> **Goal:** Fresh Arch ISO → fully functional Hyprland desktop in ~10 minutes.

---

## 1. Target Machines

- ThinkPad T14s (Intel/AMD)
- ThinkPad P43s
- Personal desktop(s)

Known hardware only — hardcode configs, no portability concerns.

---

## 2. Installation Strategy

### Pre-bootstrap (archinstall)

Use `archinstall` with minimal options:

- **Filesystem:** btrfs
  - Subvolumes: `@`, `@home`, `@pkg`, `@snapshots`
- **Bootloader:** GRUB
- **Network:** NetworkManager
- **Packages:** base, base-devel, git, networkmanager

Do **not** install Hyprland via archinstall — Hashiru handles that.

### Getting Hashiru

After first reboot into the base system:

```bash
git clone https://github.com/whleucka/hashiru.git
cd hashiru
./install.sh
```

---

## 3. Repository Structure

```
hashiru/
├── install.sh              # Entry point, orchestrates everything
├── lib/
│   └── common.sh           # Shared functions, logging, error handling
├── pacman/
│   ├── base.txt
│   ├── aur.txt             # AUR helper + AUR-only packages
│   ├── wayland.txt
│   ├── terminal.txt
│   ├── fonts.txt
│   ├── dev.txt
│   └── apps.txt            # Default applications
├── config/
│   ├── environment.d/
│   ├── snapper/
│   ├── sysctl/
│   └── udev/
├── hypr/
│   └── hyprland.conf
└── scripts/
    ├── 10-base.sh
    ├── 20-aur.sh
    ├── 30-desktop.sh
    ├── 40-hyprland.sh
    ├── 50-snapper.sh
    ├── 60-dotfiles.sh
    └── 99-reboot.sh
```

### Script Requirements

- All scripts are **idempotent** — safe to re-run
- All scripts log to `~/.local/share/hashiru/install.log`
- Scripts exit non-zero on failure; `install.sh` halts on first error
- No automatic rollback — fix and re-run

---

## 4. Package Layers

### Base System (`pacman/base.txt`)

```
base
base-devel
linux
linux-firmware
amd-ucode
intel-ucode
btrfs-progs
efibootmgr
git
snapper
snap-pac
grub-btrfs
inotify-tools
zram-generator
networkmanager
wireless-regdb
iw
iwd
sof-firmware
power-profiles-daemon
fwupd
ufw
```

### AUR Bootstrap (`pacman/aur.txt`)

```
# AUR helper (installed via makepkg first)
paru-bin

# AUR-only packages
oh-my-zsh-git
hyprlauncher
neovim-nightly-bin
intelephense
pyright
resvg
```

### Wayland + Hyprland (`pacman/wayland.txt`)

```
hyprland
xdg-desktop-portal-hyprland
xdg-desktop-portal-gtk
polkit-gnome
pipewire
pipewire-pulse
pipewire-alsa
wireplumber
wl-clipboard
grim
slurp
mako
waybar
hypridle
hyprlock
hyprpicker
brightnessctl
pamixer
playerctl
qt5-wayland
qt6-wayland
gvfs
```

### Terminal + Shell (`pacman/terminal.txt`)

```
kitty
zsh
starship
fzf
zoxide
bat
eza
ripgrep
fd
less
man-db
stow
yazi
ffmpeg
p7zip
jq
poppler
imagemagick
```

### Fonts + Visuals (`pacman/fonts.txt`)

```
noto-fonts
noto-fonts-cjk
noto-fonts-emoji
ttf-jetbrains-mono-nerd
ttf-cascadia-mono-nerd
papirus-icon-theme
```

### Development (`pacman/dev.txt`)

```
github-cli
lua-language-server
bash-language-server
clang
llvm
rust
rust-analyzer
composer
pnpm
docker
docker-compose
docker-buildx
mise
python-pynvim
```

### Apps (`pacman/apps.txt`)

```
chromium
libreoffice-fresh
gimp
```

> Additional apps (Steam, OBS, etc.) installed manually as needed.

---

## 5. Environment Variables

Managed globally via systemd user environment:

**`~/.config/environment.d/10-hashiru.conf`**

```ini
EDITOR=nvim
TERMINAL=kitty
BROWSER=chromium
XDG_SESSION_TYPE=wayland
QT_QPA_PLATFORM=wayland
```

Shell configs (`.zshrc`) are for aliases and interactive preferences only.

---

## 6. Snapper Configuration

Enable automatic btrfs snapshots:

1. Create snapper config for root: `snapper -c root create-config /`
2. Enable timeline snapshots in `/etc/snapper/configs/root`
3. `snap-pac` hooks create snapshots on every pacman transaction
4. Enable `grub-btrfsd.service` for automatic GRUB menu updates
5. Snapshots appear in GRUB submenu — boot directly into any snapshot

Snapper config lives in `config/snapper/root` and is deployed by `50-snapper.sh`.

---

## 7. Hyprland Configuration

Hardcoded for known hardware:

- Monitor layout (per-machine)
- Keyboard layout (us)
- Touchpad (tap-to-click, natural scroll)
- Idle/lock behavior (hypridle + hyprlock)
- Keybinds (Super as mod key)

No dynamic detection — opinionated defaults only.

---

## 8. Dotfiles Management

```bash
git clone https://github.com/whleucka/dotfiles.git ~/.dotfiles
cd ~/.dotfiles
stow */
```

- GNU Stow symlinks configs into place
- Conflicts fail loudly — resolve manually
- Core packages must be installed before stowing (handled by script order)

---

## 9. Verification

Run before reboot:

```bash
Hyprland --version
systemctl --user status pipewire wireplumber
snapper list
echo $EDITOR $TERMINAL
```

Reboot only after all checks pass.

---

## 10. Post-Install (Manual)

After system verification, install as needed:

- **Media:** mpv, OBS
- **Gaming:** Steam, Lutris, RetroArch
- **Dev extras:** VS Code, JetBrains IDEs

These are intentionally not automated — preferences change.

---

## 11. Principles

- **Fast:** ~10 minutes from ISO to desktop
- **Reproducible:** Same result every time
- **Idempotent:** Safe to re-run any script
- **Minimal:** No bloat, no magic
- **Opinionated:** Built for me, not everyone
