# Hashiru

Hashiru is an opinionated, personal Arch Linux bootstrap designed to get *my* machines from a bare Arch ISO to a fully working Hyprland desktop in minutes — not hours, not days.

This is not a distro.
This is not a framework.
This is a fast, reproducible way to build *my* Linux environment exactly the way I like it.

---

## What is Hashiru?

**Hashiru** (走る — *to run*) is a scripted, interactive setup that:

* Starts with a clean Arch Linux install
* Applies sane defaults and best practices
* Installs a Hyprland-based Wayland desktop
* Pulls in my dotfiles and system preferences
* Boots straight into a usable, polished system

The goal is simple:

> **From Arch ISO → fully configured desktop in ~10 minutes.**

---

## Status

🚧 **Work in progress**

This project evolves as my workflow evolves.
Breaking changes are expected.

---

## Philosophy

* **Opinionated by design** — this is built for *me*
* **Fast over flexible** — customization happens in code, not prompts
* **Reproducible** — same result every time
* **Minimal ceremony** — no bloated abstractions
* **Arch-native** — trust the Arch Wiki, not magic

---

## High-Level Flow

1. Install Arch using `archinstall`
2. Reboot into base system
3. Run the Hashiru bootstrap script
4. Install system packages + drivers
5. Install and configure Hyprland
6. Clone dotfiles to `~/.dotfiles`
7. Apply configs via GNU Stow
8. Reboot
9. Done. Run.

---

## Non-Goals

* Supporting other distros
* Supporting other window managers
* Endless customization toggles
* Being beginner-friendly

Hashiru assumes you know what you’re doing — or you’re okay fixing it if you break it.

---

## Target Machines

* ThinkPad T14s
* ThinkPad P43s
* Personal desktops

Hardware support is intentional and explicit.

---

## Why "Hashiru"?

Because speed matters.
Because momentum matters.
Because life’s too short to reconfigure the same system twice.

**Run fast.**
