# Roadmap

Where Hashiru is going, and why. Ordered, not dated — this is a one-person
project and dates would be fiction.

## What changed

Hashiru started as an Arch installer plus a dotfiles repo. It is now closer to a
base Arch system definition: one repo that owns the whole machine, replayed
idempotently instead of migrated. Two things follow from that, and they pull in
opposite directions.

The first is that owning the machine means owning it completely — no layering,
no negotiation, one repo per `$HOME`. That decision is documented in
[`internals.md`](internals.md#what-belongs-in-stow) and it was the right one; the
alternative cost real work and produced config split across two repos from the
thing that activated it.

The second is that "the machine" isn't singular. A monitor layout describes one
desk. `hashiru update` refuses to run on a dirty checkout, so a tracked file
that every machine has to edit is a file that makes every machine
un-updatable — which is exactly why `hashiru.conf` was gitignored from the start.
That reasoning was never extended past shell variables to config files, and
`monitors.lua` shipped a hardcoded ThinkPad panel as a result.

v1.6 closes that gap without reopening the layering question: the seam is one
level outside `stow/`, in `~/.config/hashiru/`, using each tool's own include
mechanism rather than a second stow tree. What got rejected before was two stow
dirs fighting over `$HOME`. This isn't that.

## v1.6 — Overrides *(done)*

- `hypr/hashiru.lua` loader: `<module>.lua` replaces, `<module>.extra.lua`
  extends, `local.lua` gets the last word
- `monitors.lua` reduced to the auto-detect catch-all; real layouts moved to
  `examples/hypr/`
- `kitty.conf` ends with `globinclude ../hashiru/kitty/*.conf`
- waybar `style.css` ends with `@import url("../hashiru/waybar/style.css")`
- `hashiru.conf` moves to `~/.config/hashiru/`, in-repo path still read
- `hashiru doctor` lists active overrides and runs `luac -p` over the Lua
- `omarchy-chromium-bin` → `chromium` from `[extra]`

## v1.7 — Deterministic installs

The install currently downloads the world and builds AUR packages on the user's
machine at first boot, one at a time, with failures demoted to warnings. That
means two installs of the same commit can produce measurably different machines,
which is the one property a system definition should not have.

- Bake every package in `pacman/*.txt` into the ISO so `pacstrap` installs from
  the ISO's own squashfs. Offline install, deterministic, and it cuts most of the
  ten minutes. Currently `packages.x86_64.extra` contains one line.
- CI builds the ISO on tag and attaches it to the release, instead of the
  maintainer running `iso/build.sh` by hand
- CI runs an install smoke test in QEMU — `iso/test-qemu.sh` exists and is not
  automated
- Move `require_network` off the stage-45 path; a config-only replay, which the
  README calls the common case, currently blocks on an HTTPS probe it never needs
- Fold stage 40 (it is one `mkdir`) and rename `99-reboot.sh`, which does not
  reboot. Both docs currently apologise for it. Stage numbers are a public API
  and this is the cheapest it will ever be to fix.

## v1.8 — The package repo

This is the actual line between "installer" and "distro" — not the ISO, which
already exists.

- Build every AUR dependency once in a clean chroot with `pkgctl`, sign them,
  publish as a pacman repo
- Add it to `pacman.conf`; AUR builds on user machines go to zero and `yay`
  leaves the critical path
- Ship `hashiru` itself as a package
- Put a version, not just a commit, in `/etc/hashiru-release`; add
  `hashiru changelog`

Config stays in `stow/`. Shipping it as a package would delete the hairiest code
in `45-config.sh` — the `~/.local/bin` unfolding, the leaked-file rescue, the
baked checkout path — but it costs "edit the file, `hashiru install 45`, see it
immediately," which is how this project is actually developed. Not worth it.

## v2.0 — Identity

- Write up the Hyprland Lua config. It is the real differentiator: almost nobody
  has adopted 0.55+ Lua yet, and it is the same feature as the override system —
  `hl.config` re-parsing per key is *why* `local.lua` can work at all. A static
  `.conf` could not do this.
- State the one-user policy in the README. "Even if I'm the only user, that's
  fine" is the correct framing for a project like this, and writing it down sets
  expectations instead of implying a support obligation.

## Deferred

**Per-file adopt/skip** (`hashiru adopt ~/.config/waybar/config.jsonc`). Would
let a tier-1 file be handed over to the user, with stow stepping aside and
`hashiru diff` reporting drift against upstream. It needs a manifest, a carve-out
inside stow's package model, and the diff tooling to stay honest — real
complexity, for a userbase of one. Build it when a second person wants a waybar
module, not before.

**Named window rules.** Hyprland merges window and layer rules on redeclaration
*by name* (`m_luaWindowRules` is keyed by name). `layerrules.lua` mostly names
its rules; `windowrules.lua` names one. Naming the rest would let an override
retarget an individual rule instead of replacing the file — upstream's own idiom,
so nearly free, but only worth doing if anyone wants it.
