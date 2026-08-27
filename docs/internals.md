# Internals

The stuff that doesn't belong in the README. Read this when something breaks or
you're changing how Hashiru works.

## Run mechanics

Nine numbered scripts in `scripts/`, run in order by `install.sh`. Every stage can
run twice without breaking anything. That property is load-bearing, because it's
the entire update mechanism.

A failed stage stops the run and tells you how to resume (`./install.sh 45+`).
Things Hashiru doesn't control get demoted to warnings: an AUR package that won't
build, a stow conflict. Those get collected,
printed at the end, and shown again at first login via
`/etc/profile.d/hashiru-report.sh`, because nobody reads scrollback.

A full run stamps `/etc/hashiru-release` with the commit and date that built the
machine. Single stages don't, since one stage isn't a bootstrap. `hashiru update`
re-stamps either way.

The reboot lives at the end of `install.sh`, after the release stamp gets
written — a stage that rebooted first meant a full install could never record
which commit built it. It used to be stage `99-reboot.sh`, kept for a while
under a name it had stopped earning; it is now `99-apps.sh`, and `install.sh`
decides whether to offer a reboot from the *last* stage by position rather than
by filename, so the next rename can't quietly disable the prompt. Unattended
runs never prompt: the firstboot wrapper reboots after disabling its own unit,
and doing it any earlier produces a boot loop.

Stage 40 is gone. It created `~/Pictures/Screenshots` and nothing else, which is
not worth a permanent stage number; that line moved to stage 45.

`install.sh` checks connectivity once, before the stage loop, but only when a
selected stage needs it. A stage opts out by declaring `# hashiru: offline` in
its header — currently 15, 45 and 50. Unmarked means "needs network", so a new
stage that fetches something is covered by default. This is what makes
`./install.sh 45` instant instead of spending up to a minute on an HTTPS probe
it never uses. Stage 45 is marked offline even though it can install stow,
because that happens only on a machine that has never had it; the stage calls
`require_network` at that one point of need.

## Stages

| Stage | Script | What it does |
|-------|--------|--------------|
| 10 | `10-base.sh` | Base packages, microcode, firmware, NetworkManager, Bluetooth, TLP, cronie, zram, sysctl/udev |
| 15 | `15-grub.sh` | GRUB boot tune. Skips itself on systemd-boot |
| 20 | `20-aur.sh` | yay, then AUR packages one at a time so one bad build can't take down the run |
| 30 | `30-desktop.sh` | Wayland stack, PipeWire, fonts, terminal tools, zsh as login shell, TTY1 auto-login |
| 35 | `35-zsh.sh` | Oh My Zsh, Powerlevel10k, plugins |
| 45 | `45-config.sh` | Stows Hashiru's own config from `stow/`, creates the override tree, puts `hashiru` on PATH |
| 50 | `50-snapper.sh` | Snapper + grub-btrfs, btrfs only |
| 60 | `60-herdr.sh` | Installs the herdr binary |
| 99 | `99-apps.sh` | Dev tools, desktop apps, Rust, user groups, final verification |

Package lists live in `pacman/*.txt`. Everything else (Hyprland, waybar, kitty,
the shell, the prompt, aliases, helper scripts) is configured from `stow/`.

Stage selectors work the same on `install.sh` and `hashiru update`:

```
./install.sh            # everything, in order
./install.sh 45         # just stage 45
./install.sh 45+        # stage 45 onward, for resuming a failed run
./install.sh 30 45      # these two
./install.sh --list     # what stages exist
```

Three flags ride alongside them, on `install.sh` and `hashiru update` both:

```
./install.sh --no-confirm              # answer every prompt yes
./install.sh --no-reboot               # never reboot, never ask
./install.sh --no-reflector            # skip stage 10's mirror ranking
./install.sh --no-confirm --no-reboot  # unattended, machine stays up
```

`--no-confirm` sounds broader than it is. Package transactions were never
interactive — every `pacman` and `yay` call in `lib/common.sh` and the stages
already passes `--noconfirm` — so the reboot at the end of `install.sh` is the
only prompt a run still has, and answering it yes means rebooting. That is why
`--no-reboot` exists and why it is tested *first*: the combination anyone
actually wants from a script is both flags at once, and if "yes to everything"
won that tie the flag pair would be useless.

The parser peels both flags out before deciding `FULL_RUN`, which is the whole
reason they are handled there rather than left to the selector matcher. A bare
`./install.sh --no-confirm` is still a full run; leaving the flag among the
selectors would have set `FULL_RUN=0` and then failed with "no stages matching
'--no-confirm'". Unrecognised `-*` arguments are now rejected by name for the
same reason — as a selector, a typo'd flag could only ever be reported as a
missing stage.

Neither flag reaches the two things people expect them to. The dirty-checkout
refusal in `hashiru update` is a hard error rather than a question, and is meant
to stay one. The `sudo -v` at the top of a run wants a password, which no amount
of `y` will satisfy — an unattended update needs a warm sudo timestamp or
NOPASSWD. `HASHIRU_ASSUME_YES` is exported for stages, though nothing in
`scripts/` reads it yet; a stage that grows a prompt should use it instead of
adding a second flag.

`--no-reflector` is the one flag that reaches into a stage, via
`HASHIRU_NO_REFLECTOR`. Stage 10 ranks mirrors before the heaviest download of
the machine's life, on whatever mirrorlist archinstall left behind — that is an
argument about first install, and it stops applying the moment the machine has
been re-ranking weekly under `reflector.timer`. The flag buys back the minute on
an update. It does *not* opt the machine out of reflector: the timer is still
enabled at the bottom of the same stage, so the flag only skips doing the work
in the foreground.

It is also the only one of the three that `hashiru.conf` can set
(`HASHIRU_NO_REFLECTOR=1`), because it is the only one that reads as a standing
property of a machine. `--no-confirm` deliberately isn't: `--no-reboot` is not a
config knob either, so a machine that turned "yes to everything" on in config
would have no way to turn the resulting auto-reboot back off in config.
`HASHIRU_UNATTENDED` already exists for "never ask me anything here". Because
config gets its say first, `install.sh` only ever *raises* the reflector flag —
its absence on the command line must not clear a configured 1.

## Layout

```
install.sh          orchestrator
doctor.sh           read-only health check
bin/hashiru         the CLI, symlinked to /usr/local/bin/hashiru
scripts/NN-*.sh     stages, numeric prefix required
lib/common.sh       logging, package helpers, stow helpers
pacman/*.txt        package manifests
stow/               Hashiru's user config ($HOME), stow packages
config/             Hashiru's system config (/etc), copied not stowed
iso/                ISO build, archinstall config, firstboot units
examples/           machine-local config to copy, never loaded from here
docs/releases/      one file per tag; the release workflow uses it as the body
```

Only numbered scripts in `scripts/` are stages — anything else in there would
get swept into a full run, which happened once and was enough.

Scripts live with whatever invokes them, which is not always the desktop:

- `stow/hyprland/.config/{hypr,waybar}/scripts/` — the compositor's own:
  `focus`, `nav`, `keybinds`, `screenshot`, `screenshot-region`,
  `hypridle-battery`, `tahoe-wallpaper`, and waybar's module scripts. Every one
  is invoked from `keybinds.lua`, `autostart.lua`, `hyprlock.conf` or
  `config.jsonc`, and none means anything without Hyprland running.
- `stow/herdr/.config/herdr/scripts/` — `herdr-flip`, `-nav`, `-route`,
  `-split-run`, `-swap`, alongside `scrollback`. These are driven by
  `herdr/config.toml`, not by any hypr binding, so they belong to herdr. They
  reach back to `hypr/scripts/focus` to escalate out of herdr into the
  compositor — the one deliberate cross-package call, and the reason they set
  `hypr_scripts` explicitly.
- `stow/bin/.local/bin/` — things you type: `update-system`, `job-viewer`,
  `msync`, `sssh`, `usb`, `write-usb`, `installed-packages`. Call sites use a
  bare name, which relies on `~/.local/bin` being on PATH — and for the
  graphical session that is `stow/hyprland/.zprofile`'s doing, not `.zshrc`'s.
  Hyprland is exec'd from a *login* shell, which never reads `.zshrc`, so a
  keybind naming one of these would otherwise die with "command not found"
  while the same name worked fine in a terminal. Assets they need live in
  `~/.local/share/hashiru/`, not next to config.
- `~/.local/bin` is also deliberately kept a **real directory** by
  `45-config.sh`, never a stow tree-fold. Third-party installers write into it
  (stage 60's herdr, cargo, `pip --user`); if stow owned the directory itself
  those writes would land inside this checkout and leave it permanently dirty,
  which makes `hashiru update` refuse to run.
- `~/.claude/skills` is kept real for the same reason: Claude Code writes skills
  there itself, so the directory has to be a shared namespace. Both packages —
  `bin` and `claude` — are the only two stowed with `--no-folding`.

None carry a `.sh` extension: they are commands, and the extension leaked an
implementation detail into every call site.

## Config ownership

Split by ownership, not by directory:

- **`stow/`** is user config Hashiru owns. Symlinked into `$HOME` with stow.
- **`config/`** is system config Hashiru owns. Copied into `/etc`.
- **`~/.dotfiles`** is your editor config and nothing else. Hashiru doesn't
  own it, doesn't need it, and doesn't know it exists.

`stow/` has one package per area: `hyprland` (hypr, waybar, mako, swayosd,
fuzzel, gtk-3.0, xdg-desktop-portal, wallpapers), `kitty`, `herdr`, `thunar`,
`yazi`, `btop`, `chromium`, `bat`, `fzf`, `ripgrep`, `claude`, and the shell —
`zsh`, `alias`, `functions`, `p10k`, `bash`, `bin`.

The desktop hand-off belongs to Hashiru too: `stow/hyprland/.zprofile` starts
Hyprland on TTY1, and `10-hashiru.conf` under `environment.d` sets the session
environment. Stage 30 used to append both to files it didn't own.

### What belongs in `stow/`

The test is: **would you want this on a machine Hashiru didn't build?**

Almost nothing does. A prompt, a terminal theme, a file manager's colours, a set
of shell aliases — those describe *this* machine, and Hashiru owns them. What
passes the test is an editor config, because that is what you miss over ssh, so
`nvim` and `vim` are the only things kept in a personal repo. Hashiru does not
clone it, stow it, or have a setting naming it.

This replaced an earlier split along *ownership* — "Hashiru's config" versus
"personal config" — which sounded principled and cost real work. Config kept
ending up in one repo with the thing that activated it in the other. `stow/fzf`
shipped `fzfrc` while `FZF_DEFAULT_OPTS_FILE` was exported from a `.zshrc` in a
dotfiles checkout, so a fresh Hashiru install stowed a file nothing ever read,
and the dotfiles alone pointed at a file that didn't exist. Both halves now sit
in `stow/`.

`stow/claude` is the same call in a newer place. `~/.claude/skills/hashiru` is a
Claude Code skill describing *this repo* — the stage rules, where a change goes,
which overrides exist. It is worthless on a machine Hashiru did not build, so
Hashiru owns it and ships it beside the thing it documents.

The other cost was collisions. Two stow dirs writing into one `$HOME` fight over
`~/.zshrc`, and any attempt to layer them runs into stow folding a package into a
single directory symlink that a *different* stow dir then refuses to touch
(`existing target is not owned by stow`). Working around that needs
`--no-folding` plus a drop-in include directory per app. None of it is necessary
once one repo owns the machine.

## Machine-local overrides

Hashiru owns everything in `stow/`, and `hashiru update` restows all of it on
every run. So an edit to a stowed file is either reverted on the next update or —
if you edit it in the checkout — leaves the tree dirty, and `hashiru update`
refuses to run on a dirty checkout. Those two rules together mean there has to
be somewhere else to put config that describes one machine.

That place is **`~/.config/hashiru/`**. Nothing in the install replays into it,
so nothing overwrites it. `45-config.sh` creates the directories and then leaves
them alone.

Three tiers, split by what the underlying tool can actually support:

| Tier | How | Applies to |
|------|-----|------------|
| Hashiru owns | stowed, replayed, not negotiable | mako, fuzzel, gtk, thunar, yazi, btop, bat, fzf, ripgrep, waybar's `config.jsonc` |
| Ships + extends | the tool's own include mechanism | hypr (Lua), kitty (`globinclude`), waybar CSS (`@import`), zsh (`~/.zshrc.local`) |
| You own | fork the repo | anything in tier 1 you disagree with |

There is no per-file adopt/skip machinery, on purpose. It needs a manifest, a
carve-out inside stow's package model, and a drift report to stay honest — real
complexity for one user. Tier 1 stays "fork it" until somebody actually asks.

The whole surface, in one table:

| Put a file here | Effect |
|---|---|
| `~/.config/hashiru/hypr/<module>.lua` | replaces that Hyprland module outright |
| `~/.config/hashiru/hypr/<module>.extra.lua` | runs after it, adding to it |
| `~/.config/hashiru/hypr/local.lua` | runs last, changes any single setting from `hyprland.lua` |
| `~/.config/hashiru/kitty/*.conf` | read after `kitty.conf`, last-wins |
| `~/.config/hashiru/waybar/style.css` | cascades over the shipped bar styling |
| `~/.zshrc.local` | sourced by the shipped `.zshrc` |
| `~/.config/hashiru/hashiru.conf` | Hashiru's own settings |

Modules are `monitors`, `autostart`, `keybinds`, `windowrules`, `layerrules`,
`clamshell`. `hashiru doctor` lists what you have overridden and syntax-checks
the Lua.

Monitors are the common case, and the only override most people need:

```bash
cp /opt/hashiru/examples/hypr/monitors.thinkpad-t14s.lua \
   ~/.config/hashiru/hypr/monitors.lua      # then edit for your displays
hyprctl monitors all                        # names, descriptions, modes
```

### Hyprland

`hypr/hashiru.lua` is the loader; `hyprland.lua` runs every module through it
instead of calling `require` directly. For any module it loads, two files in
`~/.config/hashiru/hypr/` are honoured:

- `<module>.lua` — **replaces** ours. The `require` is skipped entirely.
- `<module>.extra.lua` — **runs after** ours, adding to it.

Plus `local.lua`, loaded dead last, after the `hl.config` block in
`hyprland.lua`. That one matters more than it looks: Hyprland keeps config
values in a flat map and re-parses on every `hl.config` call, so a later call
wins *per leaf* and leaves untouched keys alone. Which means `local.lua` can
change one setting without restating the block it came from:

```lua
hl.config({ general = { gaps_in = 0, border_size = 1 } })
```

A replacement that throws falls back to the shipped module rather than taking
the whole config down — Hyprland's fallback for an unparseable config is the
emergency config, and a desktop with no keybinds is worse than a desktop missing
one override. Errors go to `hyprctl rollinglog`, and `hashiru doctor` runs
`luac -p` over these files so a typo is findable before the next reload.

`monitors.lua` is the reason all of this exists. Monitor layout is the most
machine-specific config there is, and `eDP-1` is the internal panel on *every*
laptop — so the hardcoded ThinkPad mode and position that used to ship here
silently misconfigured every other machine, including the maintainer's next one.
Hashiru now ships only the `output = ""` catch-all, which is a working layout on
any hardware. Real layouts live in `examples/hypr/`, outside the load path, and
get copied to `~/.config/hashiru/hypr/monitors.lua`.

### kitty and waybar

Both use a relative include, and both are verified to resolve it against the
file's **symlink** location (`~/.config/kitty`, `~/.config/waybar`) rather than
its target in the checkout — which is what makes `../hashiru/...` land in
`~/.config/hashiru/...` at all. kitty additionally rejects absolute glob
patterns outright (`Non-relative patterns are unsupported`), so relative is the
only option there, not a preference.

`45-config.sh` creates `~/.config/hashiru/waybar/style.css` empty, because GTK
logs a CSS error for an `@import` that resolves to nothing. It is created once
and never overwritten.

waybar's `config.jsonc` stays tier 1. Styling is most of what anyone wants to
change and CSS cascades for free; the JSON has no include mechanism worth the
complexity.

### hashiru.conf

Same directory, same reasoning: `~/.config/hashiru/hashiru.conf`. The in-repo
`hashiru.conf` is still sourced for machines that predate the move, and loses to
`~/.config` when both exist.

## The zsh package

Stage 35 installs zsh, Oh My Zsh, Powerlevel10k and three plugins, makes zsh the
login shell, then clears the generated `.zshrc`. `stow/zsh` supplies the real
one, alongside `stow/alias`, `stow/functions` and `stow/p10k` that it sources.
Machine-local settings go in `~/.zshrc.local`, which it sources and updates never
touch.

It used to be `stow/zsh-fallback` — the one package stowed conditionally, via an
`ensure_zshrc` helper that checked whether a dotfiles checkout supplied a
`.zshrc` and stood down if so. With one repo owning the shell there is nothing to
detect, so it stows like everything else and that helper is gone.

An existing `~/.zshrc` gets backed up to `.zshrc.pre-hashiru`. Only an untouched
Oh My Zsh template is deleted outright.


## ISO

`iso/README.md` covers build internals, QEMU testing, and the parts most likely
to break (archinstall changes its schema whenever it feels like it).

The installed system keeps the repo at `/opt/hashiru`, owned by the user, with
`~/hashiru` and `/usr/local/bin/hashiru` pointing at it. First boot runs from a
systemd one-shot. If it dies, the unit stays enabled and retries next boot
instead of leaving half a machine.

## Contributing

Bug reports and fixes are welcome.

* Stages must be idempotent. Running one twice is normal and must not break.
* Scripts live with whatever invokes them, and carry no `.sh` extension:
  compositor scripts under `stow/hyprland/.config/{hypr,waybar}/scripts/`,
  herdr's helpers under `stow/herdr/.config/herdr/scripts/`, and anything you
  run yourself in `stow/bin/.local/bin/` (on PATH, so callers use a bare name).
* Release notes go in `docs/releases/`, one file per tag.
