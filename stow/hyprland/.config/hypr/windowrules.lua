-- Window Rules
-- https://wiki.hypr.land/Configuring/Basics/Window-Rules/

-- Chromium titles its PiP window "Picture in Picture"; Firefox hyphenates it.
local pip = "^Picture(-| )in(-| )Picture$"

-- Electron/Chromium apps (discord, spotify, bitwarden, steam) ask to be
-- maximized on map, which fights dwindle. Deny the request everywhere; mod+M
-- still maximizes by hand.
hl.window_rule({ match = { class = ".*" }, suppress_event = "maximize" })

-- Floating windows
-- pavucontrol 6.x (GTK4) uses app_id org.pulseaudio.pavucontrol, not "pavucontrol"
hl.window_rule({ match = { class = "org\\.pulseaudio\\.pavucontrol" }, float = true, center = true, persistent_size = true })
hl.window_rule({ match = { class = "nm-connection-editor" }, float = true })
hl.window_rule({ match = { class = "blueman-manager" }, float = true })
hl.window_rule({ match = { class = "thunar" }, float = true, center = true, persistent_size = true })
hl.window_rule({ match = { class = "org.gnome.Calculator" }, float = true })
hl.window_rule({ match = { class = "imv" }, float = true })
hl.window_rule({ match = { class = "^[Gg]imp.*" }, float = true })
hl.window_rule({ match = { class = "satty" }, float = true })
hl.window_rule({ match = { class = "tlpui" }, float = true })

-- Portal screen-share picker (xdg-desktop-portal-hyprland). Tiles by default,
-- so "share your screen" reflows whatever layout you were about to share.
hl.window_rule({ match = { class = "^hyprland-share-picker$" }, float = true, center = true, size = { 700, 450 } })

-- Transmission's dialogs share its class, so the file-dialog titles below miss them
hl.window_rule({ match = { class = "^transmission-gtk$", title = "^(Open Torrent|Torrent Properties|Preferences|Statistics)$" }, float = true })

-- Generic app dialogs (libreoffice, inkscape, thunar, transmission, GTK apps)!!
hl.window_rule({ match = { title = "^(Preferences|Properties|Settings)$" }, float = true })

-- Picture-in-Picture: float, pin above workspaces, keep the video's aspect ratio
hl.window_rule({ match = { title = pip }, float = true, pin = true, size = { 480, 270 } })
hl.window_rule({ match = { title = pip }, keep_aspect_ratio = true, border_size = 0 })

hl.window_rule({ match = { class = "btop" }, float = true, center = true, size = { 1400, 900 } })

-- Google Calendar as a chromium app window; waybar's clock launches it. Matched
-- by its exact class, not the ^chrome-.*-Default$ PWA pattern below, so it
-- floats without dragging every other chromium app window along with it.
hl.window_rule({ match = { class = "^chrome-calendar\\.google\\.com__-Default$" }, float = true, center = true, size = { 1400, 900 } })

-- File dialogs (matches Open/Save/Export across GTK apps, GIMP, Inkscape, browsers)
hl.window_rule({ match = { title = "^(Open|Save|Export|Import)( As)?( File| Image| Folder| Document)?\\.?\\.?\\.?$" }, float = true })
hl.window_rule({ match = { title = "^(Select|Choose) (File|Folder|Image|Directory).*" }, float = true })

-- Polkit
hl.window_rule({ match = { class = "polkit-gnome-authentication-agent-1" }, float = true })

-- Steam. Runs under XWayland; its utility windows share the main class, so they
-- tile as full siblings unless named. Games get their own steam_app_<id> class.
hl.window_rule({ match = { class = "^steam$", title = "^(Friends List|Steam Settings|Special Offers|Screenshot Uploader)$" }, float = true })
hl.window_rule({ match = { class = "^steam_app_\\d+$" }, idle_inhibit = "focus" })
-- Tearing for games only: general:allow_tearing gates it, this opts games in.
hl.window_rule({ match = { class = "^steam_app_\\d+$" }, immediate = true })

-- Idle inhibit (prevent screen lock)
hl.window_rule({ match = { class = "chromium" }, idle_inhibit = "fullscreen" })
hl.window_rule({ match = { class = "^[Gg]oogle-chrome.*" }, idle_inhibit = "fullscreen" })
hl.window_rule({ match = { class = "mpv" }, idle_inhibit = "fullscreen" })
-- Chromium PWAs report as chrome-<app-id>-Default, not "chromium"
hl.window_rule({ match = { class = "^chrome-.*-Default$" }, idle_inhibit = "fullscreen" })

-- Keep drawing on inactive workspaces, so screen-sharing a hidden window (or a
-- PiP that lost focus) doesn't hand the viewer a frozen frame.
hl.window_rule({ match = { class = "^[Ss]potify$" }, render_unfocused = true })
hl.window_rule({ match = { class = "mpv" }, render_unfocused = true })
hl.window_rule({ match = { title = pip }, render_unfocused = true })

-- Never let the vault into a screencast (OBS, Discord share, portal capture)
hl.window_rule({ match = { class = "^Bitwarden$" }, no_screen_share = true })

-- NOTE: no "smart gaps" rule. A w[t1]/w[tv1] single-window-no-gaps rule counts
-- a whole group as one tile, so a lone group goes edge-to-edge and its groupbar
-- jams against the waybar. It also makes mod+M maximize look like a no-op and
-- makes float/unfloat snap the remaining window. Consistent gaps everywhere
-- avoids all three. There is no selector/match that excludes groups from it.

-- XWayland
hl.window_rule({ match = { xwayland = true }, no_anim = true })
-- Steam and Java/Electron installers map empty placeholder windows that take
-- focus and then never draw. Leave focus where it was.
hl.window_rule({ match = { class = "^$", title = "^$", xwayland = true }, no_focus = true })
