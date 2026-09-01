---
name: hashiru
description: Working on the Hashiru repo (/opt/hashiru) — the Arch + Hyprland bootstrap that owns this machine. Use when editing stages in scripts/, config under stow/ or config/, package manifests in pacman/, the hashiru CLI, doctor.sh, the ISO, or release notes — whenever a change to this machine's desktop, shell, or system config is asked for, since Hashiru owns those files and editing them in $HOME is reverted on the next update — and whenever a release is cut, since the docs site in ~/.mount/hashiru has to be checked and updated in the same pass.
---

# Hashiru

Hashiru is an opinionated Arch + Hyprland bootstrap living at `/opt/hashiru`. It
installs the machine and then keeps owning its config. Replaying the install
*is* the update — there is no diffing engine and no migration system.

The repo path is load-bearing: stow bakes it into every symlink, so the checkout
cannot move after install.

## Before changing anything

Read [internals](https://hashiru.williamhleucka.com/docs/internals.html) on the site. It is the design
record, not a tutorial — most "obvious" improvements were already tried and are
documented as rejected there (per-file adopt/skip, layering inside `stow/`, a
`zsh-fallback` package, stage 40). Check before proposing one.

## Where a change goes

| Change | Goes in |
|---|---|
| User config ($HOME) | `stow/<pkg>/` — a stow package, symlinked into `$HOME` |
| System config (/etc) | `config/` — copied, not stowed |
| Packages | `pacman/*.txt` |
| Install/update logic | `scripts/NN-*.sh` |
| A command you type | `stow/bin/.local/bin/`, no `.sh` extension |
| A compositor script | `stow/hyprland/.config/{hypr,waybar}/scripts/` |
| Machine-specific values | **not the repo** — `~/.config/hashiru/`, or `examples/` |

Scripts live with whatever invokes them, and carry no `.sh` extension unless
they are a stage.

## Rules that actually bite

- **Stages are idempotent.** Every `scripts/NN-*.sh` must survive running twice.
  This is the entire update mechanism; breaking it breaks updates.
- **Stage numbers are permanent.** Do not renumber, do not reuse a retired
  number. Only numbered scripts in `scripts/` are stages — anything else there
  gets swept into a full run.
- **Never edit a stowed file in `$HOME`.** `~/.config/hypr/keybinds.lua` is a
  symlink into the checkout; editing it dirties the tree and `hashiru update`
  refuses to run on a dirty checkout. Edit `stow/…` and re-stow.
- **Never hardcode this machine.** Monitor layouts, hostnames, disk names and
  panel modes belong in `~/.config/hashiru/` or `examples/`, never in `stow/`.
  Hashiru ships the `output = ""` catch-all for monitors on purpose.
- **A stage that reaches the network is the default.** Only mark a stage
  `# hashiru: offline` in its header if it genuinely does not, so `install.sh`
  can skip the connectivity probe.
- **`~/.local/bin` and `~/.claude/skills` stay real directories.** They are
  shared namespaces that third-party tools write into, so `45-config.sh`
  pre-creates them and stows their packages with `--no-folding`. If stow folded
  them into a directory symlink, those writes would land inside the checkout.

## Does it belong in `stow/`?

The test: **would you want this on a machine Hashiru did not build?**

Almost nothing does. A prompt, a terminal theme, a file manager's colours,
shell aliases — all describe *this* machine, so Hashiru owns them outright.
What passes the test is an editor config, which is why `nvim` and `vim` are the
only things left in a personal dotfiles repo that Hashiru neither clones nor
stows.

Adding a package is just a new directory under `stow/` — stage 45 iterates the
tree, and `doctor.sh` discovers packages the same way. Nothing enumerates them
by name.

## Overrides, when a user wants a change Hashiru owns

Three tiers, and picking the wrong one is the usual mistake:

1. **Hashiru owns it** (mako, fuzzel, gtk, thunar, yazi, btop, bat, fzf,
   ripgrep, waybar's `config.jsonc`) — no override hook. Fork it.
2. **Ships and extends** — use the tool's own include mechanism:
   `~/.config/hashiru/hypr/<module>{,.extra}.lua` and `hypr/local.lua`,
   `~/.config/hashiru/kitty/*.conf`, `~/.config/hashiru/waybar/style.css`,
   `~/.zshrc.local`.
3. **`~/.config/hashiru/hashiru.conf`** for Hashiru's own settings.

`hypr/local.lua` runs last and wins *per leaf*, so it can change one setting
without restating the block it came from.

## Verify a change

```bash
./install.sh --list        # what stages exist
./install.sh 45            # run one stage WITHOUT pulling (update refuses on dirty)
./doctor.sh                # read-only health check; fixes nothing
git status                 # must be clean before `hashiru update` will run
```

`hashiru install` runs stages without pulling — that is the loop for iterating
on local changes. `hashiru update` pulls first and refuses on a dirty checkout.

## Docs

Release notes go in `docs/releases/`, one file per tag, short point form. That
directory is load-bearing twice over — the release workflow uses the file as the
body, and `hashiru changelog` reads it at runtime on every installed machine —
so it stays in the repo. `iso/README.md` covers the ISO build.

Everything else a *user* reads lives on the website, not here:

| | |
|---|---|
| Source | `~/.mount/hashiru/public/` |
| Deploy | `msync` → `williamhleucka.com:/opt/hashiru` |
| Live | <https://hashiru.williamhleucka.com> |

It is the source of truth for install, CLI, keybinds, configuration, internals
and roadmap. The repo has no markdown copies of any of it — a doc change is a
change to `public/`, not to a file here.

### Cutting a release means updating the site

The repo and the site are one change, not two. Before tagging, read the diff
back and ask what the site would now tell someone wrongly:

- a bind added, moved or dropped → `docs/keybinds.html`
- a new `hashiru` subcommand or flag → `docs/cli.html`
- a new `hashiru.conf` key or override path → `docs/configuration.html`
- a stage added, renumbered or retired → `docs/internals.html`, and the stage
  rail on the landing page (`public/index.html`)
- anything shipped → a row in `docs/changelog.html`
- the install one-liner changed → the `data-copy` on the landing page hero

Then `msync` it up. A release that changes behaviour without touching the site
ships stale docs, and the site is now the only place a user looks.

Adding a whole page means three things stay in sync: the sidebar nav (repeated
in every page), the `INDEX` array in `assets/js/search.js`, and `sitemap.xml`.
`~/.mount/hashiru/README.md` has the rest.
