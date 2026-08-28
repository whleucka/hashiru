# Roadmap

Where Hashiru is going, and why. Ordered, not dated — this is a one-person
project and dates would be fiction.

## What changed

Hashiru started as an Arch installer plus a dotfiles repo. It is now closer to a
base Arch system definition: one repo that owns the whole machine, replayed
idempotently instead of migrated. v1.6 gave that definition a seam users can
bend without forking it; v1.7 moved release builds off a laptop and into CI.

The obvious next step looked like a signed package repo — the line where an
installer becomes a distro. That milestone existed here for a while, justified by
determinism: two installs of the same commit can produce different machines, and
a system definition shouldn't have that property. The justification does not
survive counting.

`pacman/aur.txt` is eight packages. The other six manifests are 165 packages
pulled from rolling Arch repos, with no version pin anywhere in the tree. Two
installs of the same commit *already* diverge by whatever `pacman -Syu` served
that day, and the divergence that would ever be noticed is in the kernel,
mesa and hyprland — none of which an AUR repo touches. Signing eight packages
pins under five percent of the machine and calls it reproducible. The only thing
that actually delivers the property is an Arch Linux Archive snapshot pin, which
is a different project, and one that argues against a rolling base rather than
for it.

What the repo *would* have delivered honestly is smaller than the milestone
claimed: `yay` off the critical path, and a few minutes of first-boot build time.
What it costs is permanent — a signing key in CI secrets and its rotation,
hosting, a `repo-add` pipeline, and the job of tracking eight upstreams that the
AUR tracked for free. The first day the repo ships an older `claude-code` than
the AUR does, that staleness is a Hashiru bug. That is a bad trade for a userbase
of one, so it moves to [Deferred](#deferred) with a trigger written down.

The real defect in the AUR path was never determinism. It is that the install
does not admit when a package didn't land — a day of work rather than a build
farm.

Which is where the milestone dissolved entirely. Once the package repo was out,
what remained was four items: a version in the release stamp, a `changelog`
subcommand, AUR failures reaching the banner, and an `aur.txt` audit. Four
patches. Naming that collection v1.8 would have been version-number theatre, so
it shipped as v1.7.2 instead, and there is no v1.8. A minor gets earned; it
doesn't get scheduled.

It was planned as two patches and shipped as one, for the same reason: the code
never separated. Quiet mode and the version stamp are both in `install.sh`, the
progress line and AUR batching are both in `lib/common.sh`. There was no commit
where half of it existed, so there was nothing for a first tag to point at.

The same counting kills v2.0. What sat here under that number was two items,
both of them writing: a piece on the Hyprland Lua config, and a line in the
README about the one-user policy. Neither changes a byte of what an install
produces. Every release so far earned an `## Upgrading` section with something
in it — v1.6 needed a monitor layout moved out of the repo before updating, v1.7
renamed stages, v1.7.2 landed new commands on replay. Two doc commits would have
to write "nothing to do" there, which is the tell. Spending a major on prose is
the theatre v1.8 avoided, with a larger number.

So there is no v2.0 either, and the version stops being a plan. For a system
definition the threshold worth a major is not an API break but the moment replay
stops being sufficient — when an existing machine cannot simply `hashiru update`
into the new one. The package repo is exactly that line, which is why it is the
one deferred item that would arrive as a major rather than a minor.

## v1.6 — Overrides *(done)*

The machine isn't singular. A monitor layout describes one desk, and `hashiru
update` refuses to run on a dirty checkout — so a tracked file that every machine
has to edit is a file that makes every machine un-updatable. That is exactly why
`hashiru.conf` was gitignored from the start; the reasoning had never been
extended past shell variables to config files, and `monitors.lua` shipped a
hardcoded ThinkPad panel as a result.

v1.6 closed that gap without reopening the layering question. What got rejected
before was two stow trees fighting over `$HOME` (see
[`internals.md`](internals.md#what-belongs-in-stow)); this seam sits one level
outside `stow/`, in `~/.config/hashiru/`, and uses each tool's own include
mechanism.

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
the milestone. Baking also only ever helped first boot, never `hashiru update`.

## v1.7.2 — Patches *(done)*

What used to be v1.8, plus the things that actually made first boot worse than
it needed to be. [`releases/v1.7.2.md`](releases/v1.7.2.md) lists what shipped;
this is why.

The console stopped being a flood:

- `HASHIRU_QUIET` puts child output (pacman, makepkg, git) in the log and a
  progress line on the console. Defaults to whatever `HASHIRU_UNATTENDED` is:
  on for first boot, off for the manual runs whose output you debug against.
- The console gets its own descriptor, fd 3, so redirecting a stage's stdout
  into the log doesn't take the log lines with it.
- Progress granularity stops where knowledge does. Stage count is real and so is
  the AUR loop's package index; a pacman transaction covers a whole manifest at
  once, so it gets a label and no fraction. Smoothing the bar out of guessed
  stage weights would only have been a nicer lie.
- `hashiru log` and `hashiru report` — hiding output is only acceptable if
  reaching it is a command rather than a path to remember. A failed stage also
  dumps the last 40 log lines, because a bar and nothing else is worse than the
  flood.
- The completion banner names the warning count, so an unattended run that lost
  an AUR package doesn't read like a clean one.

And the install stopped compiling things nobody asked for:

- AUR packages install in one batched `yay` call, falling back to the existing
  serial loop only on failure. A stock `aur.txt` was paying seven dependency
  resolutions and seven `--removemake` cycles over the same build deps. The
  isolation property is unchanged — it just isn't paid for when there is nothing
  to isolate.
- `HASHIRU_VERSION` from `git describe --tags` in `/etc/hashiru-release`, and
  `hashiru changelog` over `docs/releases/`.
- `update-system` guards `confetti` and `paplay`, both of which are optional.

**Downloads were already tuned**, which is why the install-time half is modest.
`ParallelDownloads = 10` and reflector mirror-ranking both run before the first
`-Syu`, so what was left was dependency resolution and compiles, not bandwidth.
The one compile that mattered was `sherlock-confetti`, and it is gone from
`aur.txt`. It built via cargo on every fresh install, and it was also why a
fresh install downloaded two Rust toolchains — it makedepends on `rust`, while
stage 99 runs `rustup default stable`. It existed to animate `update-system`,
which now guards the call, so a machine without it simply gets no confetti.
`sqls` went with it — a Go build on every fresh install, for a SQL language
server nothing in this repo configures. What is left in `aur.txt` is two npm
shims, a prebuilt binary, a binary repack and one small C build (`wrk`), so no
fresh install waits on a compiler for anything that matters.

Dropping a package from `aur.txt` does not uninstall it. Machines that already
have `sherlock-confetti` keep it, and keep the animation; it just stops being
part of what a new machine is.

## v1.7.3 — Clamshell *(done)*

A patch on paper, and the hardest release so far. Lid state turned out to be
unreadable from the switch event — libinput synthesises a lid-open out of typing
on this class of machine — so docking had to be rewritten around
`/proc/acpi/button/lid/LID/state`, a modeset wait, and a DPMS force with a layout
reload behind it. [`releases/v1.7.3.md`](releases/v1.7.3.md) has the detail.

None of that is a feature, and it is worth naming why it took the most work of
any release: it was hardware behaving differently from its documentation. That
is the category the rest of this document had no place to put, which is what
[Hardware](#hardware) now exists for.

`docs/keybinds.md` landed alongside it, and the personal site shortcuts moved out
of the repo into `keybinds.extra.lua` — the override system doing exactly the job
v1.6 built it for.

## What's left

One patch, and the observation behind it: replay is the update mechanism, and
nothing in the CLI helps when a replay goes wrong. It is not a release, and the
sections after this one say why there may not be another.

- `hashiru rollback`. The mechanism already exists and is undiscoverable:
  `snap-pac`, `snapper` and `grub-btrfs` are all in `base.txt`, so every pacman
  transaction is already bracketed by snapshots and they already appear in the
  GRUB menu. What is missing is a name for the pre-update one and a command that
  finds it, which is CLI surface rather than a subsystem.

  Two honest limits, because the entry is smaller than it first looks. The config
  half needs no snapshot — the checkout *is* the snapshot, and `hashiru install
  45` restores it. And `@home` has no snapper config at all, only `root`, which
  means the one thing genuinely unprotected is `~/.config/hashiru/` — the
  override tree, which is nothing's source of truth and which no stage writes.
  Whether that is worth a second snapper config or a line in the docs is the
  actual question, and the answer is probably the docs.

  **Moving the override tree somewhere snapshotted is rejected**, since it is the
  obvious next thought. `/usr/local/etc` or anywhere else under `@` would put it
  inside snap-pac's brackets, and it cannot go there: kitty's `globinclude
  ../hashiru/kitty/*.conf` resolves relative to `~/.config/kitty`, and kitty
  rejects absolute glob patterns outright, so that override can only ever reach a
  path relative to `~/.config`. waybar's `@import` has the same shape. Only the
  hypr loader, being Lua, could follow. A root-owned tree would also mean
  `sudoedit` for `monitors.lua`, which is the file v1.6 existed to make easy to
  edit.

  The deciding argument is that the coverage would be pointless anyway. Stage 45
  creates those directories and never touches what is in them — the one file it
  writes is guarded by `[[ ! -e ]]` precisely so an update cannot eat it — so a
  replay cannot destroy the override tree. Rollback undoes an update that broke
  the machine, and an update cannot reach this by construction. What the tree is
  actually exposed to is disk loss and `rm`, which is backup rather than
  rollback, and is not this project's job.

## Hardware

Not a milestone and not ordered — a standing list, because this is the work that
does not stop when the features do. v1.7.3 spent its entire budget here.

A system definition's real claim is the set of machines it boots correctly on.
That claim only ever grows by hitting a machine that behaves differently from its
documentation, so nothing in this section can be scheduled.

Known-good today: the ThinkPad this was built for, plus whatever the
`output = ""` monitor catch-all and the clamshell rewrite generalise to. The
catch-all is deliberate — `eDP-1` is the internal panel on every laptop, so a
hardcoded mode silently misconfigures every machine that isn't the one it was
written on.

Where the edges are known to be, in no order:

- **NVIDIA and hybrid graphics.** Untested. `wayland.txt` carries the mesa and
  vulkan side; the proprietary path, the KMS hook question and hybrid-mode
  handling are all unexercised.
- **Non-btrfs roots.** Stage 50 already skips itself, which is correct, but that
  means a non-btrfs machine silently has no snapshots and nothing says so. That
  interacts directly with `hashiru rollback` above.
- **systemd-boot.** Stage 15 skips itself. Same shape as the above: handled, but
  handled by absence.
- **External display brightness.** DDC/CI is the standard answer and nothing here
  does it; the brightness keys reach the internal panel only.
- **Multi-monitor beyond a dock.** The clamshell path is now well-tested. Three
  displays, mixed DPI and rotation are not.

The way this section grows is by a machine failing, not by planning. Entries get
added when something is found, and removed when it is fixed and released.

## Deferred

**The package repo.** Build every AUR dependency once in a clean chroot with
`pkgctl`, sign them, publish as a pacman repo, add it to `pacman.conf`. The
honest wins are that `yay` and `base-devel` leave the critical path and first
boot stops compiling anything. The cost is a signing key in CI, hosting, a
`repo-add` pipeline, and inheriting eight upstreams' release tracking — forever,
for one user. Build it when a second person is installing this regularly, or when
`aur.txt` has grown past what a first boot can build reliably; the v1.7.2 audit
should push that further out, not closer. This is the one entry here that would
land as v2.0 rather than a minor — it changes where the machine's software comes
from, which replay alone cannot carry an existing install across.

Shipping `hashiru` itself as a package rides along with that entry rather than
splitting out, and for the same reason config stays in `stow/`: it would cost
"edit the file, `hashiru install 45`, see it immediately," which is how this
project is actually developed.

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
