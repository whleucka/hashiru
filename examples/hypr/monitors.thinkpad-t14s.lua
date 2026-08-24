-- ThinkPad T14s, optionally docked to a BenQ GL2780 above it.
--
-- Copy to ~/.config/hashiru/hypr/monitors.lua to use. Replaces Hashiru's
-- monitors.lua outright, so keep the catch-all at the bottom: without it, any
-- display not named here gets no layout at all.

-- The BenQ sits above, so the panel starts 1080px down.
hl.monitor({ output = "eDP-1", mode = "1920x1200@60", position = "0x1080", scale = 1 })

-- Matched by description, not port: this only fires on the actual BenQ, so a
-- different monitor on the same HDMI port falls through to the catch-all.
hl.monitor({ output = "desc:BNQ BenQ GL2780 ETN7L07855SL0", mode = "1920x1080@74.97", position = "0x0", scale = 1 })

hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })
