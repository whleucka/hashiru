# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Hashiru (走る — "to run") is an opinionated Arch Linux bootstrap system that automates desktop environment setup. It transforms a bare Arch installation into a fully configured Hyprland Wayland desktop in ~10 minutes.

**Status:** Work in progress — documentation complete, implementation pending.

## Architecture

```
hashiru/
├── install.sh              # Entry point orchestrator
├── lib/common.sh           # Shared functions, logging, error handling
├── scripts/                # Sequential installation phases (10-base.sh → 99-reboot.sh)
├── pacman/                 # Package manifests by category (*.txt files)
├── config/                 # System configs (environment.d/, snapper/, sysctl/, udev/)
└── hypr/                   # Hyprland WM configuration
```

**Execution flow:** `install.sh` runs scripts in numeric order. All scripts are idempotent and log to `~/.local/share/hashiru/install.log`. Scripts exit non-zero on failure; orchestrator halts on first error.

## Key Technical Decisions

- **Display:** Wayland only (no X11)
- **Window Manager:** Hyprland
- **Audio:** PipeWire + WirePlumber (not PulseAudio)
- **Shell:** Zsh
- **Terminal:** Kitty
- **Dotfiles:** GNU Stow for symlink management
- **Filesystem:** btrfs with snapper for snapshots
- **Bootloader:** GRUB (for grub-btrfs snapshot boot)

## Script Guidelines

- All bash scripts must be idempotent (safe to re-run)
- No automatic rollback — fix issues manually and re-run
- No interactive prompts — customization happens in code
- Hardcode configs for known hardware (ThinkPad T14s, P43s, personal desktops)
- Log all operations to the central log file
- Always update the SPEC.md when the requirements or shape of the project
  changes.

## Verification Commands

```bash
Hyprland --version
systemctl --user status pipewire wireplumber
snapper list
echo $EDITOR $TERMINAL
```
