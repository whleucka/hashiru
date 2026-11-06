-- layouts.lua — tiling layouts, and switching between them per workspace.
--
-- Hyprland 0.56 ships four layouts (dwindle, scrolling, master, monocle) and
-- lets Lua register more through hl.layout.register. The three extra ones here
-- are adapted from upstream's example/layouts (v0.56.2), with spiral's ratio
-- and rotation kept per workspace rather than in one table they all share.
--
-- Upstream's fourth example, manual, is left out on purpose: a linear chain of
-- fixed 50/50 halvings, with nothing to resize and windows shrinking fast. It
-- does nothing dwindle (preserve_split + SUPER+O) does not do better.
--
-- Switching is per workspace, i3/xmonad style. SUPER+A ("arrange") opens a
-- one-shot picker. Each layout's key is its first letter, or its second when
-- the first is taken:
--
--   d dwindle   s scrolling   m master   o monocle
--   c columns   g grid        p spiral
--
-- Picking a layout adds a workspace rule for the focused workspace, so it
-- outlives the workspace emptying and being recreated, but not a config reload.
-- Picking general.layout (dwindle, unless local.lua changes it) just drops the
-- rule again. To pin a layout permanently, put a rule in local.lua:
--
--   hl.workspace_rule({ workspace = "3", layout = "lua:grid" })
--
-- SUPER+O flips whatever the current layout has that can be flipped (see FLIP).

local mod = "SUPER"

local function key(...)
    return table.concat({ ... }, " + ")
end

-- -----------------------------------------------------------------------------
-- Lua layouts
-- -----------------------------------------------------------------------------

local function clamp(x, min, max)
    return math.max(min, math.min(max, x))
end

-- The workspace a layout context belongs to. ctx does not name it, but every
-- target's window does, and ctx only ever holds one workspace's targets.
local function workspace_of(ctx)
    for _, target in ipairs(ctx.targets) do
        local ws = target.window and target.window.workspace
        if ws then
            return ws.name
        end
    end
    return "?"
end

-- Per-workspace state, created on first use from `init`.
local function state_table(init)
    local by_workspace = {}
    return function(ctx)
        local name = workspace_of(ctx)
        local s = by_workspace[name]
        if not s then
            s = init()
            by_workspace[name] = s
        end
        return s
    end
end

-- columns: every window side by side, equal width.
hl.layout.register("columns", {
    recalculate = function(ctx)
        local n = #ctx.targets
        for i, target in ipairs(ctx.targets) do
            target:place(ctx:column(i, n))
        end
    end,
})

-- grid: as square as the window count allows.
hl.layout.register("grid", {
    recalculate = function(ctx)
        local n = #ctx.targets
        if n == 0 then
            return
        end
        local cols = math.ceil(math.sqrt(n))
        for i, target in ipairs(ctx.targets) do
            target:place(ctx:grid_cell(i, cols))
        end
    end,
})

-- spiral: each window takes `ratio` of what is left, turning a quarter each time.
do
    local sides    = { "left", "top", "right", "bottom" }
    local opposite = { left = "right", right = "left", top = "bottom", bottom = "top" }
    local state    = state_table(function() return { ratio = 0.58, offset = 0 } end)

    hl.layout.register("spiral", {
        recalculate = function(ctx)
            local n = #ctx.targets
            if n == 0 then
                return
            end
            local s    = state(ctx)
            local area = ctx.area
            for i, target in ipairs(ctx.targets) do
                if i == n then
                    target:place(area)
                else
                    local side = sides[((i - 1 + s.offset) % #sides) + 1]
                    target:place(ctx:split(area, side, s.ratio))
                    area = ctx:split(area, opposite[side], 1.0 - s.ratio)
                end
            end
        end,

        layout_msg = function(ctx, msg)
            local s = state(ctx)
            local command, arg = msg:match("^(%S+)%s*(.*)$")
            if command == "ratio" then
                s.ratio = clamp(tonumber(arg) or s.ratio, 0.1, 0.9)
            elseif command == "grow" then
                s.ratio = clamp(s.ratio + 0.05, 0.1, 0.9)
            elseif command == "shrink" then
                s.ratio = clamp(s.ratio - 0.05, 0.1, 0.9)
            elseif command == "rotate" then
                s.offset = (s.offset + 1) % #sides
            else
                return "spiral: expected ratio <0.1..0.9>, grow, shrink, or rotate"
            end
            return true
        end,
    })
end

-- -----------------------------------------------------------------------------
-- Switching
-- -----------------------------------------------------------------------------

-- Picker order, and each layout's key in the SUPER+A submap. `symbol` is what
-- waybar shows, after dwm's: []= tile, [M] monocle, [@] spiral, [\] dwindle.
-- `id` is what
-- Hyprland calls it: hl.layout.register files Lua layouts under "lua:<name>",
-- and that prefixed form is what a workspace rule and tiled_layout use. A rule
-- naming an unknown layout falls back to dwindle without a word, so the prefix
-- matters.
local LAYOUTS = {
    { key = "D", name = "dwindle",   id = "dwindle",     label = "[d]windle",   symbol = "[\\]" },
    { key = "S", name = "scrolling", id = "scrolling",   label = "[s]crolling", symbol = "<=>" },
    { key = "M", name = "master",    id = "master",      label = "[m]aster",    symbol = "[]=" },
    { key = "O", name = "monocle",   id = "monocle",     label = "m[o]nocle",   symbol = "[M]" },
    { key = "C", name = "columns",   id = "lua:columns", label = "[c]olumns",   symbol = "|||" },
    { key = "G", name = "grid",      id = "lua:grid",    label = "[g]rid",      symbol = "###" },
    { key = "P", name = "spiral",    id = "lua:spiral",  label = "s[p]iral",    symbol = "[@]" },
}

local BY_ID = {}
for i, l in ipairs(LAYOUTS) do
    l.index = i
    BY_ID[l.id] = l
end

-- What SUPER+O does in each layout. Layouts missing from here (monocle,
-- columns, grid) have nothing to flip, and the key does nothing.
local FLIP = {
    ["dwindle"]    = "togglesplit",     -- this split: side by side <-> stacked
    ["master"]     = "orientationnext", -- master area: left -> top -> right -> bottom
    ["scrolling"]  = "colresize +conf", -- column width: next of scrolling:explicit_column_widths
    ["lua:spiral"] = "rotate",          -- start the spiral a quarter turn later
}

-- One notice on screen at a time, so cycling through layouts replaces it
-- instead of stacking them up.
local notice
local function notify(text, timeout)
    if notice then
        pcall(notice.dismiss, notice)
    end
    notice = hl.notification.create({ text = text, timeout = timeout or 1500 })
end

local function dismiss_notice()
    if notice then
        pcall(notice.dismiss, notice)
        notice = nil
    end
end

-- The workspace SUPER+A acts on: the scratchpad while it is open, since that is
-- where focus is, otherwise the monitor's active workspace.
local function focused_workspace()
    return hl.get_active_special_workspace() or hl.get_active_workspace()
end

-- A workspace rule's selector for `ws`: special and numbered workspaces go by
-- name ("special:magic", "3"), any other named one needs the name: prefix.
local function selector(ws)
    if ws.special or ws.name == tostring(ws.id) then
        return ws.name
    end
    return "name:" .. ws.name
end

-- Rule handles we created, by selector, so a second pick replaces the first
-- rather than piling up behind it.
local rules = {}

-- waybar's custom/layout shares signal 8 with the workspace buttons, which
-- ws-listener already sends on every workspace switch. A layout change is not
-- a Hyprland event, so it has to be sent from here.
local function refresh_bar()
    hl.exec_cmd("pkill -RTMIN+8 waybar")
end

local function set_layout(layout)
    local ws = focused_workspace()
    if not ws then
        return
    end
    local sel = selector(ws)

    if rules[sel] then
        rules[sel]:set_enabled(false)
        rules[sel] = nil
    end
    if layout.id ~= hl.get_config("general.layout") then
        rules[sel] = hl.workspace_rule({ workspace = sel, layout = layout.id })
    end

    notify("Layout: " .. layout.name)
    refresh_bar()
end

local function flip()
    local ws  = focused_workspace()
    local msg = ws and FLIP[ws.tiled_layout]
    if msg then
        hl.dispatch(hl.dsp.layout(msg))
    end
end

-- -----------------------------------------------------------------------------
-- Binds
-- -----------------------------------------------------------------------------

local labels = {}
for _, l in ipairs(LAYOUTS) do
    table.insert(labels, l.label)
end
local legend = "Layout: " .. table.concat(labels, "  ")

hl.bind(key(mod, "A"), function()
    notify(legend, 5000)
    hl.dispatch(hl.dsp.submap("arrange"))
end, { description = "Arrange: pick this workspace's layout" })

-- "reset": leave the submap after any bind fires, so the picker is one-shot.
hl.define_submap("arrange", "reset", function()
    for _, l in ipairs(LAYOUTS) do
        hl.bind(l.key, function()
            set_layout(l)
            hl.dispatch(hl.dsp.submap("reset"))
        end, { description = "Layout: " .. l.name })
    end

    -- Anything else, Escape included, closes the picker without changing the
    -- layout. A stray key must not leave the keyboard stuck in a submap.
    local function cancel()
        dismiss_notice()
        hl.dispatch(hl.dsp.submap("reset"))
    end
    hl.bind("Escape", cancel)
    hl.bind("catchall", cancel)
end)

hl.bind(key(mod, "O"), flip, { description = "Flip layout (split / orientation / width)" })

-- A reload drops every rule set_layout made, so the bar is stale until told.
hl.on("config.reloaded", refresh_bar)

-- -----------------------------------------------------------------------------
-- Waybar
-- -----------------------------------------------------------------------------

-- waybar/scripts/layout reaches these through `hyprctl repl`, which runs in this
-- config's Lua state. It looks them up in package.loaded rather than calling
-- require, so a missing or replaced module just hides the indicator instead of
-- loading this file a second time.
local M = {}

local function json_string(str)
    return '"' .. str:gsub('[\\"]', '\\%0'):gsub("\n", "\\n") .. '"'
end

--- Waybar's return-type json for the focused workspace's layout.
function M.bar()
    local ws = focused_workspace()
    if not ws then
        return '{"text": ""}'
    end
    local l = BY_ID[ws.tiled_layout]
    local name = l and l.name or ws.tiled_layout
    return string.format('{"text": %s, "class": %s, "tooltip": %s}',
        json_string(l and l.symbol or name),
        json_string((name:gsub("^lua:", ""))),
        json_string("Layout: " .. name .. "\nClick: next  ·  Right-click: previous  ·  SUPER+A: pick"))
end

--- Step through LAYOUTS from the focused workspace's current layout.
---@param step integer 1 for next, -1 for previous
function M.cycle(step)
    local ws = focused_workspace()
    if not ws then
        return
    end
    local current = BY_ID[ws.tiled_layout]
    local i = current and current.index or 0
    set_layout(LAYOUTS[(i - 1 + step) % #LAYOUTS + 1])
end

return M
