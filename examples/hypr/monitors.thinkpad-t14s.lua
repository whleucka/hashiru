-- ThinkPad T14s, optionally docked to a BenQ GL2780 above it.
--
-- Copy to ~/.config/hashiru/hypr/monitors.lua to use. Replaces Hashiru's
-- monitors.lua outright, so keep the catch-all at the bottom: without it, any
-- display not named here gets no layout at all.

-- The BenQ sits above, so the panel starts 1080px down.
hl.monitor({ output = "eDP-1", mode = "1920x1200@60", position = "0x1080", scale = 1 })

-- Matched by description, not by output name. On the Thunderbolt dock the
-- display arrives on a connector that is created when the dock is plugged in
-- and destroyed when it is pulled (DP-8/9/10 here, the BenQ on DP-9), and the
-- number it lands on can move between plug-ins -- so a rule naming a port is a
-- rule that stops firing. Matching the description also means a different
-- monitor on the same port falls through to the catch-all, which is what you
-- want.
--
-- "preferred" rather than a pinned mode, and deliberately. Through the dock's
-- tunnel this display's EDID offers only 60Hz at 1920x1080; the 75Hz the
-- GL2780 is sold on shows up at 1280x1024 and below. So the obvious-looking
-- mode = "1920x1080@74.97" asks for something that does not exist while docked,
-- which is exactly when this file is in use.
hl.monitor({ output = "desc:BNQ BenQ GL2780 ETN7L07855SL0", mode = "preferred", position = "0x0", scale = 1 })

hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })
