-- Clamshell mode
--
-- The laptop panel is disabled only while the lid is shut AND a real external
-- monitor is present. Every other combination re-enables it, so Hyprland is
-- never left with zero outputs -- undocking with the lid down used to strand the
-- session with eDP-1 disabled and nothing able to bring it back.
--
-- This runs in-process on purpose. Driving it from a shell script via
-- `hyprctl eval 'hl.monitor(...)'` does not work: hl.monitor *accumulates*
-- configurations rather than replacing them, so repeated enable/disable calls
-- desync Hyprland's monitor state from DRM and the re-enable becomes a silent
-- no-op (returns "ok", changes nothing). In-process also means every check
-- below reads state that is already current, so nothing races a shell round
-- trip -- which is what used to let the undock suspend fire while the panel was
-- still coming back.
--
-- A disabled monitor is removed from the layout, so hl.get_monitor(PANEL) == nil
-- is the honest "is the panel off" check. `hyprctl monitors` is not: it happily
-- reports the panel as enabled, with an active workspace, while it is dark.

local PANEL = "eDP-1"

-- Must match the panel's rule in monitors.lua.
local PANEL_RULE = {
    output   = PANEL,
    mode     = "1920x1200@60",
    position = "0x1080",
    scale    = 1,
    disabled = false, -- explicit: omitting it leaves the panel disabled
}

-- How long to let a lid event settle before trusting /proc (see lid_closed),
-- and how long to let a modeset finish before suspending on an undock.
local LID_SETTLE_MS = 400
local MODESET_SETTLE_MS = 1500

local function log(msg)
    print("[clamshell] " .. msg)
end

-- Lid state comes from ACPI, never from the switch event.
--
-- libinput pairs the internal keyboard with the lid switch on this class of
-- machine -- "lid: keyboard paired with Lid Switch<->AT Translated Set 2
-- keyboard" shows up in the Hyprland log at startup -- and from then on it
-- synthesises a lid-OPEN out of keyboard traffic whenever it suspects the
-- switch is lying. logind, which reads the ACPI button directly, never sees
-- those: a session here recorded "Lid closed" once and nothing else for nine
-- hours, while Hyprland disabled the panel and re-enabled it a beat later.
-- Taking switch:off at face value is what re-lit the panel behind a shut lid.
--
-- Missing file means "no lid to worry about": report open, which keeps the
-- panel on rather than blanking a desktop that has no lid switch at all.
local function lid_closed()
    local f = io.open("/proc/acpi/button/lid/LID/state", "r")
    if not f then return false end
    local state = f:read("*a") or ""
    f:close()
    return state:match("closed") ~= nil
end

-- Is a real external monitor attached? `skip` excludes one that is being
-- removed but may still be listed while its event is handled.
--
-- When the last real output goes, Hyprland substitutes a placeholder output
-- named FALLBACK. It is not a monitor you can see, so it must not count as an
-- external -- otherwise undocking with the lid shut looks like "still docked"
-- and we disable the panel instead of bringing it back.
local function external_present(skip)
    for _, m in ipairs(hl.get_monitors()) do
        if m.name ~= PANEL and m.name ~= "FALLBACK" and m.name ~= skip then
            return true
        end
    end
    return false
end

local function panel_on()
    return hl.get_monitor(PANEL) ~= nil
end

-- Re-run this machine's monitor layout, the way hyprland.lua loads it.
--
-- Deliberately not a bare `require("monitors")`. hashiru.load() runs a
-- machine-local ~/.config/hashiru/hypr/monitors.lua through dofile() and never
-- require()s the shipped module at all, so requiring it here would apply
-- Hashiru's stock catch-all instead: the panel comes back, but at "auto"
-- position and with every named rule on this machine silently discarded.
-- Clearing the cache entry first covers the other case, where there is no
-- override and the shipped module really was require()d.
local function reload_monitors()
    package.loaded["monitors"] = nil
    local ok, err = pcall(function() require("hashiru").load("monitors") end)
    if not ok then
        log("monitor layout reload failed: " .. tostring(err))
    end
    return ok
end

-- Bring the panel back, and make sure it is actually lit.
--
-- Re-applying PANEL_RULE is not sufficient on its own for two separate reasons,
-- and both produce the same symptom -- a black panel that Hyprland insists is
-- fine. One: a rule identical to what is already in the config can be accepted
-- and do nothing, so the panel stays out of the layout. Two: a monitor can be
-- back in the layout and still be DPMS-off. This is the "open the lid, no
-- display, go fix it from another tty" case, so handle both here rather than
-- leaving either to be noticed by hand.
--
-- The dpms is unconditional. A sync only ever runs off a lid event, a monitor
-- appearing or vanishing, or a config reload -- all of them a person doing
-- something -- so waking the screen is the wanted answer even when hypridle
-- has just blanked it.
local function enable_panel()
    hl.monitor(PANEL_RULE)

    if not panel_on() then
        log("panel did not return from its rule; reloading the monitor layout")
        reload_monitors()
        hl.monitor(PANEL_RULE)
    end

    if panel_on() then
        hl.dispatch(hl.dsp.dpms({ action = "on", monitor = PANEL }))
    else
        log("panel still absent after a layout reload -- session has no output")
    end
end

-- Reconcile the panel against lid + external state.
--
-- Hyprland <= 0.55.x could not enable a monitor when no active monitor
-- remained, which needed a full config reload to escape; that was fixed
-- upstream in 0.56 (PR #14547) and the workaround is gone. enable_panel's
-- reload is now a fallback for a rule that did not take, not a routine path.
local function sync(skip)
    if lid_closed() and external_present(skip) then
        if panel_on() then
            hl.monitor({ output = PANEL, disabled = true })
        end
    else
        enable_panel()
    end
end

-- Undocking with the lid shut means "packing up": suspend. Wait until the panel
-- is genuinely back first, or the machine goes down mid modeset and resume is
-- black. Decide from live state at the end of the settle, not from a flag
-- captured when the event arrived -- by then the removed output is really gone,
-- so this needs no `skip`.
local function suspend_if_packing_up()
    hl.timer(function()
        if lid_closed() and not external_present() and panel_on() then
            log("undocked with the lid shut; suspending")
            hl.exec_cmd("systemctl suspend")
        end
    end, { timeout = MODESET_SETTLE_MS, type = "oneshot" })
end

-- logind's lid handling is inhibited (see autostart.lua), so the lid is ours to
-- act on entirely -- including the plain "shut the laptop" -> sleep.
--
-- Both directions run the same handler because the event only says "the lid
-- switch moved"; lid_closed() says which way. Reconciling twice is what makes
-- that safe: the immediate pass keeps it responsive, and the settled pass is
-- what rejects libinput's synthetic opens and catches a real close that /proc
-- had not caught up to yet.
local function lid_event()
    sync()

    hl.timer(function()
        sync()
        if lid_closed() and not external_present() and panel_on() then
            log("lid shut with no external display; suspending")
            hl.exec_cmd("systemctl suspend")
        end
    end, { timeout = LID_SETTLE_MS, type = "oneshot" })
end

hl.bind("switch:on:Lid Switch", lid_event, { locked = true })
hl.bind("switch:off:Lid Switch", lid_event, { locked = true })

hl.on("monitor.added", function(m)
    -- The panel coming back on its own means we just recovered from an undock.
    if m.name == PANEL then
        suspend_if_packing_up()
        return
    end
    sync()
end)

hl.on("monitor.removed", function(m)
    if m.name == PANEL then return end

    -- Bring the panel back, so we are never left with no usable output.
    sync(m.name)

    -- If it was already on, no monitor.added is coming to trigger the suspend.
    suspend_if_packing_up()
end)

-- A reload re-runs monitors.lua, which switches the panel back on regardless of
-- the lid. Reconcile, or a reload while docked and shut leaves it lit.
hl.on("config.reloaded", function() sync() end)
