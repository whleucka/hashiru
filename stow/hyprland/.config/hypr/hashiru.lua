-- hashiru.lua — the seam between what Hashiru ships and what this machine wants.
--
-- Every file in this directory belongs to Hashiru: `hashiru update` restows
-- them, so editing one in place is either reverted on the next update or, if
-- you edit it inside the checkout, leaves the tree dirty — and `hashiru update`
-- refuses to run on a dirty checkout. Machine-local config therefore lives
-- OUTSIDE the repo, under ~/.config/hashiru/hypr/, where nothing overwrites it:
--
--   monitors.lua          replaces ours outright (require'd module is skipped)
--   keybinds.extra.lua    runs after ours, adding to it
--   local.lua             runs last, after everything
--
-- Both forms work for any module hyprland.lua loads. Replace when our version
-- is actively wrong for this machine (monitors); extend when you just want a
-- few more of something (keybinds, autostart, window rules).
--
-- `local.lua` is the general-purpose hook, and it reaches the settings that
-- aren't in any module: Hyprland keeps config values in a flat map and
-- re-parses on every hl.config call, so a later call wins per leaf and leaves
-- untouched keys alone. That means local.lua can change one setting out of
-- hyprland.lua's block without restating the rest:
--
--   hl.config({ general = { gaps_in = 0, border_size = 1 } })
--
-- Nothing here is required. With no override files present this behaves exactly
-- as the plain `require` calls it replaced.

local M = {}

local config_home = os.getenv("XDG_CONFIG_HOME")
if not config_home or config_home == "" then
    config_home = (os.getenv("HOME") or "") .. "/.config"
end

local OVERRIDE_DIR = config_home .. "/hashiru/hypr/"

local function readable(path)
    local f = io.open(path, "r")
    if not f then return false end
    f:close()
    return true
end

-- Load a machine-local file, reporting failure instead of propagating it.
--
-- A syntax error in an override must not take the whole config down: Hyprland
-- would fall back to its emergency config, and a desktop with no keybinds is a
-- far worse outcome than a desktop missing one override. Errors land in the
-- Hyprland log (`hyprctl rollinglog`), and `hashiru doctor` syntax-checks these
-- files so a typo is findable before the next reload.
--
-- Returns true only if the file ran cleanly, which is what lets a failed
-- *replace* fall back to the shipped module below.
local function run(path)
    local ok, err = pcall(dofile, path)
    if not ok then
        print("[hashiru] override failed, ignoring: " .. path .. ": " .. tostring(err))
    end
    return ok
end

-- Load one of Hashiru's modules, honouring a machine-local replace and/or
-- extend for it.
---@param name string module name, as it appears in this directory
function M.load(name)
    local replacement = OVERRIDE_DIR .. name .. ".lua"

    -- A replacement that fails to run leaves us with no config for this module
    -- at all, so fall back to ours. This can double up whatever the override
    -- managed to apply before it died (duplicate binds, say) — acceptable next
    -- to the alternative, and doctor will have already flagged the file.
    if not (readable(replacement) and run(replacement)) then
        require(name)
    end

    local extra = OVERRIDE_DIR .. name .. ".extra.lua"
    if readable(extra) then
        run(extra)
    end
end

-- The catch-all hook, loaded after everything else so it gets the last word.
-- Machine-local only: Hashiru ships no local.lua of its own.
function M.load_local()
    local path = OVERRIDE_DIR .. "local.lua"
    if readable(path) then
        run(path)
    end
end

return M
