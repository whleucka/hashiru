# Internals

The stuff that doesn't belong in the README. Read this when something breaks or
you're changing how Hashiru works.

## Run mechanics

Ten numbered scripts in `scripts/`, run in order by `install.sh`. Every stage can
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

Stage 99 does not reboot, despite the name. Renaming it would change the
ordering. The reboot moved to the end of `install.sh`, after the release stamp
gets written, since a stage that reboots first means a full install can never
record which commit built it. Unattended runs never prompt: the firstboot wrapper
reboots after disabling its own unit, and doing it any earlier produces a boot
loop.

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
`yazi`, `bpytop`, `chromium`, `bat`, `fzf`, `ripgrep`, and the shell — `zsh`,
`alias`, `functions`, `p10k`, `bash`, `scripts`.

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

The other cost was collisions. Two stow dirs writing into one `$HOME` fight over
`~/.zshrc`, and any attempt to layer them runs into stow folding a package into a
single directory symlink that a *different* stow dir then refuses to touch
(`existing target is not owned by stow`). Working around that needs
`--no-folding` plus a drop-in include directory per app. None of it is necessary
once one repo owns the machine.

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
