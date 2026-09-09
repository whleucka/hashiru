-- Hashiru Hyprland Configuration (Lua, 0.55+)
-- https://wiki.hypr.land/

-- Each module can be replaced or extended per-machine from
-- ~/.config/hashiru/hypr/ — see hashiru.lua for the rules.
local hashiru = require("hashiru")

for _, module in ipairs({
    "monitors",
    "autostart",
    "keybinds",
    "windowrules",
    "layerrules",
    "clamshell",
}) do
    hashiru.load(module)
end

-- -----------------------------------------------------------------------------
-- Environment
-- -----------------------------------------------------------------------------

hl.env("XCURSOR_THEME",     "Adwaita")
hl.env("XCURSOR_SIZE",      "24")
hl.env("HYPRCURSOR_THEME",  "Adwaita")
hl.env("HYPRCURSOR_SIZE",   "24")
hl.env("GTK_THEME",         "Adwaita-dark")
hl.env("QT_STYLE_OVERRIDE", "Adwaita-Dark")

-- -----------------------------------------------------------------------------
-- General / Input / Decoration / Layouts / Misc
-- -----------------------------------------------------------------------------

hl.config({
    general = {
        gaps_in     = 5,
        gaps_out    = 10,
        border_size = 2,
        col = {
            active_border   = { colors = { "rgba(7aa2f7ee)", "rgba(9ece6aee)" }, angle = 45 },
            inactive_border = "rgba(414868aa)",
        },
        resize_on_border = true,
        -- Gate only. Tearing needs a per-window `immediate` rule too, and the
        -- only one is steam_app_* in windowrules.lua, so the desktop is unaffected.
        allow_tearing    = true,
        layout           = "dwindle",
    },

    input = {
        kb_layout    = "us",
        kb_options   = "caps:super",
        repeat_rate  = 80,
        repeat_delay = 200,
        follow_mouse = 1,
        sensitivity  = 0,
        touchpad = {
            natural_scroll       = true,
            tap_to_click         = true,
            drag_lock            = true,
            disable_while_typing = true,
        },
    },

    gestures = {
        workspace_swipe_distance     = 300,
        workspace_swipe_cancel_ratio = 0.5,
    },

    decoration = {
        rounding = 2,
        blur = {
            enabled    = true,
            size       = 3,
            passes     = 2,
            noise      = 0.0117,
            brightness = 0.8,
            contrast   = 1,
        },
    },

    animations = {
        enabled = true,
    },

    dwindle = {
        preserve_split = true,
        smart_split    = false,
        smart_resizing = true,
        force_split    = 2,
    },

    master = {
        new_status = "master",
    },

    group = {
        col = {
            -- Was a hand-mixed 4a7fcf that matched nothing. A focused group is
            -- still a focused window, so it takes the same accent and alpha as
            -- general:col.active_border's first stop.
            border_active   = "rgba(7aa2f7ee)",
            border_inactive = "rgba(0d1f3caa)",
        },
        groupbar = {
            enabled              = true,
            font_size            = 12,
            font_family          = "monospace",
            font_weight_active   = "ultraheavy",
            font_weight_inactive = "normal",
            indicator_height     = 0,
            indicator_gap        = 5,
            height               = 22,
            gaps_in              = 5,
            gaps_out             = 0,
            -- The active tab is the accent, not a shade of the inactive one.
            -- Both states used to be the same translucent black, which read as
            -- one featureless stripe above a grouped window with no way to tell
            -- which tab had focus. blue0 rather than the brighter blue: a tab
            -- strip sits under the eyeline all day and should not glare.
            text_color           = "rgb(c0caf5)",
            text_color_inactive  = "rgba(c0caf5aa)",
            col = {
                active   = "rgba(3d59a1cc)",
                inactive = "rgba(1e2130cc)",
            },
            gradients                 = true,
            gradient_rounding         = 0,
            gradient_round_only_edges = false,
        },
    },

    misc = {
        force_default_wallpaper    = 0,
        disable_hyprland_logo      = true,
        disable_splash_rendering   = true,
        mouse_move_enables_dpms    = true,
        key_press_enables_dpms     = true,
        on_focus_under_fullscreen  = 1,
        focus_on_activate          = true,
    },

    xwayland = {
        force_zero_scaling = true,
    },

    cursor = {
        no_hardware_cursors = true,
    },
})

-- -----------------------------------------------------------------------------
-- Gestures
-- -----------------------------------------------------------------------------

hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })

-- -----------------------------------------------------------------------------
-- Animations (macOS-style)
-- -----------------------------------------------------------------------------

-- macOS-style beziers
hl.curve("easeOutExpo",    { type = "bezier", points = { { 0.16, 1 },  { 0.3, 1 }  } }) -- fast start, smooth deceleration
hl.curve("easeOutQuart",   { type = "bezier", points = { { 0.25, 1 },  { 0.5, 1 }  } }) -- gentler ease-out for fades/close
hl.curve("easeInOutCubic", { type = "bezier", points = { { 0.65, 0 },  { 0.35, 1 } } }) -- balanced for workspace slides

-- Window open/close/move
hl.animation({ leaf = "windowsIn",   enabled = true, speed = 4, bezier = "easeOutExpo",  style = "popin 85%" })
hl.animation({ leaf = "windowsOut",  enabled = true, speed = 3, bezier = "easeOutQuart", style = "popin 85%" })
hl.animation({ leaf = "windowsMove", enabled = true, speed = 4, bezier = "easeOutExpo" })

-- Workspace transitions
hl.animation({ leaf = "workspaces", enabled = true, speed = 4, bezier = "easeInOutCubic", style = "slide" })

-- Fade for popups, tooltips, etc.
hl.animation({ leaf = "fade", enabled = true, speed = 3, bezier = "easeOutQuart" })

-- Layers (waybar, rofi, notifications)
hl.animation({ leaf = "layers",    enabled = true, speed = 3, bezier = "easeOutExpo",  style = "slide" })
hl.animation({ leaf = "layersOut", enabled = true, speed = 2, bezier = "easeOutQuart", style = "fade" })

-- -----------------------------------------------------------------------------
-- Machine-local overrides
-- -----------------------------------------------------------------------------

-- ~/.config/hashiru/hypr/local.lua, if it exists. Loaded last on purpose: a
-- later hl.config call wins per leaf, so this is where a single setting from
-- the block above gets changed without restating any of it.
hashiru.load_local()
