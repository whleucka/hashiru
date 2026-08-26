# Keybinds

`SUPER` is the modifier for everything below except lock and exit, which are
deliberately harder to hit by accident.

**Caps Lock is a second Super.** Hashiru ships `kb_options = "caps:super"`, so
the key under your left little finger is the modifier — every bind here is
reachable without moving your hand off home row. `Super+Q` is Caps Lock + Q.

The trade is that Caps Lock no longer locks anything: the key is a modifier now,
not a toggle, and nothing in the bar reports its state because there is no state
to report. Wanting shouting back is a one-line override — that setting lives in
`hyprland.lua`'s `input` block rather than in `keybinds.lua`, and a later
`hl.config` call wins per leaf, so `~/.config/hashiru/hypr/local.lua` can undo
just this one without restating the block:

```lua
hl.config({ input = { kb_options = "" } })
```

The binds themselves are in
[`stow/hyprland/.config/hypr/keybinds.lua`](../stow/hyprland/.config/hypr/keybinds.lua).
This file mirrors it; if the two disagree, the Lua is right.

## Super+/ — the list, on screen

`Super+/` pipes `hyprctl binds` through `fuzzel`, so it reads the binds the
*running* compositor actually has, not a static list. Anything you added in
`~/.config/hashiru/hypr/keybinds.extra.lua` shows up there too, and it's
type-to-filter — `Super+/`, then "screen", finds the screenshot binds.

It shows a bind only if that bind has a `description`, and skips submaps
entirely. That is a deliberate filter, not a bug: it keeps the list to things
worth naming. The cost is that four groups never appear on screen — the hold-to-
resize keys, the resize submap, the mouse binds, and the media keys. They're all
documented below, which is most of why this file exists.

## Applications

| Bind | Does |
|---|---|
| `Super+Return` | kitty |
| `Super+Shift+Return` | kitty running herdr |
| `Super+Space` | app launcher (fuzzel) |
| `Super+Shift+W` | browser (chromium) |
| `Super+Shift+F` | file manager (thunar) |
| `Super+Shift+Y` | yazi, in a terminal |
| `Super+Shift+N` | neovim, in a terminal |
| `Super+Shift+T` | btop |
| `Super+Shift+D` | lazydocker |
| `Super+Shift+C` | calculator |
| `Super+Shift+P` | color picker (hyprpicker, copies to clipboard) |
| `Super+Shift+V` | clipboard history (cliphist through fuzzel) |
| `Super+Shift+U` | `update-system`, in a centered floating terminal |
| `Super+B` | toggle waybar |

Terminal apps inherit `EDITOR=nvim VISUAL=nvim`.

## Websites

`Super+Alt+<letter>` opens a site as a chromium app window.

| | | | |
|---|---|---|---|
| `A` Amazon | `B` Bluesky | `E` Email | `F` Facebook |
| `G` GitHub | `I` Instagram | `M` Messages | `N` NHL |
| `R` Reddit | `Y` YouTube | | |

These are the generic ones. Personal shortcuts — your own hosts — belong
in `~/.config/hashiru/hypr/keybinds.extra.lua`, not here; see
[Changing them](#changing-them).

## Windows

| Bind | Does |
|---|---|
| `Super+Q` | close |
| `Super+F` | fullscreen |
| `Super+M` | maximize |
| `Super+T` | toggle floating |
| `Super+O` | toggle split direction |
| `Super+Backspace` | focus last window |

### Focus — `Super+H/J/K/L`

One keychain across three programs. In a kitty window the bind doesn't move
Hyprland focus directly: it injects `Ctrl+Alt+hjkl` into the terminal, which
drives tmux, which drives neovim's splits — and at the outermost edge the chain
escalates back out to the next Hyprland window. In any other window it's a plain
directional focus.

So `Super+L` walks you out of a neovim split, out of the tmux pane, and into the
browser beside it, without your ever thinking about which layer you're in.

`Ctrl+Alt+hjkl` is injection-only plumbing — you never press it. It's that
combination rather than bare `Ctrl+hjkl` so the shell keeps backspace and
kill-line.

### Move — `Super+Shift+H/J/K/L`

Moves the window itself in that direction.

### Resize

Two ways, neither of which appears in `Super+/`:

| Bind | Does |
|---|---|
| `Super+-` / `Super+=` | narrower / wider, hold to repeat |
| `Super+Shift+-` / `Super+Shift+=` | shorter / taller, hold to repeat |
| `Super+R` | resize mode |

Resize mode is a submap: `H/J/K/L` resize (hold to repeat), `Escape` leaves. Use
it when one nudge isn't enough. While it's active, other binds are inert — if
the keyboard seems dead, you're still in it, so press `Escape`.

### Mouse

`Super+LeftDrag` moves a window, `Super+RightDrag` resizes it.

## Workspaces

| Bind | Does |
|---|---|
| `Super+1`…`9`, `Super+0` | switch to workspace 1–10 |
| `Super+Shift+1`…`9`, `Super+Shift+0` | send window to that workspace |

Sending a window doesn't follow it — you stay where you are.

The scratchpad is a special workspace that floats over whatever's below it:

| Bind | Does |
|---|---|
| `Super+Home` | toggle the scratchpad |
| `Super+Insert` | send this window into it |
| `Super+Delete` | drop it back to the current workspace |

## Groups (tabs)

Grouped windows stack into one tabbed frame.

| Bind | Does |
|---|---|
| `Super+G` | group / ungroup |
| `Super+N` / `Super+P` | next / previous tab |
| `Super+D` | pull the active window out |
| `Super+Ctrl+H/J/K/L` | pull the neighbour in that direction into the group |
| `Super+Ctrl+G` | lock the group, so new windows don't join it |

## Screenshots

| Bind | Does |
|---|---|
| `Print` | select a region |
| `Super+Print` | whole screen |

## Notifications

| Bind | Does |
|---|---|
| `Super+,` | dismiss the top notification |
| `Super+Shift+,` | dismiss all |
| `Super+.` | restore the last dismissed |

## Media and hardware keys

The laptop's own keys, wired to swayosd so they draw an on-screen indicator.
None carry a description, so none appear in `Super+/`.

| Key | Does |
|---|---|
| Volume up / down | output volume, hold to repeat |
| Mic mute | toggle input mute |
| Brightness up / down | backlight, hold to repeat |
| Play / pause, next, previous, stop | playerctl, whichever player has focus |

Closing the lid is handled in
[`clamshell.lua`](../stow/hyprland/.config/hypr/clamshell.lua), next to the
docked/undocked state it has to reason about — it suspends or blanks the panel
depending on whether a real external monitor is attached.

## Session

| Bind | Does |
|---|---|
| `Ctrl+Alt+L` | lock (hyprlock) |
| `Ctrl+Alt+Delete` | exit Hyprland |

Both drop `Super` on purpose: they're the two binds where a slip is expensive.

## Changing them

Don't edit `keybinds.lua` in the repo — `hashiru update` refuses to run on a
dirty checkout, so a local edit there costs you updates. Machine-local binds go
in `~/.config/hashiru/hypr/`:

| File | Effect |
|---|---|
| `keybinds.extra.lua` | runs after the shipped binds — add your own |
| `keybinds.lua` | replaces the shipped module outright |
| `local.lua` | runs last, after everything |

Adding is the common case, and `extra.lua` covers it — it runs after the shipped
module, so a new bind on a free key just lands.

*Changing* a shipped bind is the case to be careful with. The "later call wins"
property that makes `local.lua` work belongs to `hl.config`, which re-parses
into a flat map per leaf; nothing documents the same guarantee for `hl.bind` on
a key that is already bound. If you want a shipped bind gone rather than
supplemented, take the reliable route: drop a full `keybinds.lua` in, which
skips ours entirely, and start from a copy of the shipped file.

```lua
-- ~/.config/hashiru/hypr/keybinds.extra.lua
hl.bind("SUPER + ALT + C", hl.dsp.exec_cmd("chromium --app=https://cnn.com"),
  { description = "CNN" })
```

Give it a `description` and it shows up in `Super+/` alongside the rest.

`hashiru doctor` lists which overrides are active and runs `luac -p` over them,
so a syntax error there gets caught before it silently costs you every bind in
the file.
