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

## v1.7 — CI *(done)*

Releases used to be built by hand on a laptop, which is neither deterministic nor
something that scales to caring.

- `.github/workflows/release.yml` builds the ISO on a `v*` tag in a privileged
  `archlinux` container — `mkarchiso` needs root, loop devices and mount — then
  verifies and publishes it. `workflow_dispatch` builds without touching a
  release. Runs in about 7 minutes.
- Building from CI on a tag removes the build-before-tag hazard entirely:
  checkout gives the tag's commit, so the pin is correct by construction rather
  than by remembering.
- `iso/verify.sh` checks the built image without booting it: size against
  GitHub's 2 GiB asset limit, the commit pin *inside* the squashfs, an
  unsubstituted `__HASHIRU_REF__`, and `stage0.sh`'s mode.
- `iso/build.sh` takes `HASHIRU_REF` from the environment, because
  `actions/checkout` falls back to a tarball when git is missing from the image
  — leaving no `.git`, and a `|| echo main` fallback that would quietly ship an
  unpinned ISO.
- Release bodies come from `docs/releases/<tag>.md`, falling back to
  `--generate-notes`.

Stage cleanups that went with it:

- `require_network` is now per-stage. Stages opt out with `# hashiru: offline`;
  `./install.sh 45` no longer waits on an HTTPS probe it never uses.
- Stage 40 folded into 45 — it was one `mkdir`, which is not worth a permanent
  stage number.
- `99-reboot.sh` → `99-apps.sh`, and the reboot prompt now keys off the last
  stage by position rather than by filename.

**A full install test stays manual.** The original plan was to automate
`iso/test-qemu.sh`, which is not possible on hosted runners: no `/dev/kvm`, no
display, and software emulation of a whole archinstall plus bootstrap would run
for hours rather than minutes. `verify.sh` covers what can be checked in seconds
by reading the image; booting one before publishing remains a local step.

**Packages are deliberately not baked into the ISO.** That was the original
plan; it collides with GitHub's 2 GiB release-asset cap. The ISO is already
1.5 GB, and the six package lists add at least another 1.4 GB — a floor, since
that was measured on a machine that already had most of the dependencies. Past
the cap, CI can build an ISO it cannot publish, which loses the entire point of
the milestone. v1.8 gets determinism without touching ISO size.

## v1.8 — The package repo

The install builds AUR packages on the user's machine at first boot, one at a
time, with failures demoted to warnings. Two installs of the same commit can
produce measurably different machines, which is the one property a system
definition should not have.

- Build every AUR dependency once in a clean chroot with `pkgctl`, sign them,
  publish as a pacman repo
- Add it to `pacman.conf`; AUR builds on user machines go to zero and `yay`
  leaves the critical path
- Ship `hashiru` itself as a package
- Put a version, not just a commit, in `/etc/hashiru-release`; add
  `hashiru changelog`

This is the actual line between "installer" and "distro" — not the ISO, which
already exists. It also beats baking packages on its own terms: it fixes
`hashiru update` as well as first boot, where baking only ever helped first
boot, and it costs the ISO a few KB of `pacman.conf` rather than gigabytes.
Offline install is the one thing it doesn't give, and Hashiru has never claimed
to offer one — the README says to bring a network connection.

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
