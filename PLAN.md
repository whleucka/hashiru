# Arch + Hyprland Personal Bootstrap Plan

This is a blueprint for a **minimal, opinionated, ready-to-go Arch Linux + Hyprland workstation** for personal machines (ThinkPad T14s, P43s, or other desktops).

> Goal: From fresh Arch ISO → fully functional Hyprland desktop, terminal, shell, and dev environment, **ready in ~10 minutes**. Optional apps installed after system verification.

> Project name: Hashiru (走る)

---

## 1. Target Machines

- ThinkPad T14s (Intel/AMD)
- ThinkPad P43s
- Personal desktop(s)
- Known hardware only → hardcode configs, no portability concerns.

---

## 2. Installation Strategy

- Use `archinstall` minimally:
  - Filesystem: **btrfs**
    - Subvolumes: `@`, `@home`, `@pkg`, `@snapshots`
  - Bootloader: `systemd-boot`
  - NetworkManager
  - Minimal packages only
- Do not install Hyprland yet — focus on a correct, bare system.

---

## 3. Bootstrap Repository Structure

```
arch-hypr-doom/
├── install.sh           # Single entry point
├── pacman/
│   ├── base.txt
│   ├── wayland.txt
│   ├── terminal.txt
│   ├── fonts.txt
│   └── dev.txt          # Optional, explicit install
├── config/
│   ├── environment.d/
│   ├── sysctl/
│   └── udev/
├── hypr/
│   └── hyprland.conf
└── scripts/
    ├── 10-base.sh
    ├── 20-desktop.sh
    ├── 30-hyprland.sh
    ├── 40-dotfiles.sh
    └── 99-reboot.sh
```

- All scripts are **idempotent** and log their actions.
- `install.sh` orchestrates the layers.

---

## 4. Package Layers

### 🔹 Base System (`pacman/base.txt`)

```
base
base-devel
linux
linux-firmware
amd-ucode
btrfs-progs
efibootmgr
snapper
zram-generator
networkmanager
wireless-regdb
iw
iwd
sof-firmware
power-profiles-daemon
fwupd
ufw
ufw-docker
```

### 🔹 Wayland + Hyprland (`pacman/wayland.txt`)

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
```

### 🔹 Terminal + Shell (`pacman/terminal.txt`)

```
kitty
zsh
starship
bash-completion
fzf
zoxide
bat
eza
ripgrep
fd
less
man-db
```

### 🔹 Fonts + Visuals (`pacman/fonts.txt`)

```
noto-fonts
noto-fonts-cjk
noto-fonts-emoji
ttf-jetbrains-mono-nerd
ttf-cascadia-mono-nerd
yaru-icon-theme
```

### 🔹 Development (optional, explicit) (`pacman/dev.txt`)

```
git
github-cli
neovim
lua-language-server
bash-language-server
tree-sitter-cli
clang
llvm
rust
ruby
composer
pnpm
docker
docker-compose
docker-buildx
mise
python-pynvim
```

> Optional apps (Steam, Gimp, LibreOffice, OBS, RetroArch, etc.) installed **after system verification**.

---

## 5. Environment Variables

- Managed globally in `~/.config/environment.d/10-core.conf`

```ini
EDITOR=nvim
TERMINAL=kitty
BROWSER=firefox
XDG_SESSION_TYPE=wayland
```

- Shell configs are for aliases and user preference only.

---

## 6. Hyprland Configuration

- Hardcode for known hardware:
  - Monitor layout
  - Keyboard layout
  - Touchpad behavior
  - Power management
  - Keybinds
- No dynamic detection — maintain opinionated defaults.

---

## 7. Dotfiles Management

- Clone personal dotfiles to `~/.dotfiles`
- Use GNU Stow aggressively:

```bash
cd ~/.dotfiles
stow */
```

- Fail loudly if conflicts occur.
- Ensure core packages exist before stowing.

---

## 8. Verification Steps

Before reboot:

- `Hyprland --version`
- `echo $PATH`
- `nvim +checkhealth`
- `systemctl --user status pipewire`
- `loginctl show-session $XDG_SESSION_ID`

Reboot once all checks pass.

---

## 9. Post-install Optional Apps

- Dev tools beyond bootstrap (`VS Code`, `IntelliJ`, `Poetry`, etc.)
- Media / gaming software
- Retro emulators / content

Install **after system verification** — ensures base system is solid.

---

## 10. Goals & Notes

- Fully functional, minimal, good-looking Hyprland system.
- Ready to go in ~10 minutes from fresh Arch ISO.
- Single-user, known-hardware focus.
- Everything reproducible, idempotent, and auditable.
- Opinionated defaults — the system bends to your taste, not generality.

