-- Desktop: dual LG ultrawides, left landscape and right rotated to portrait.
--
-- Copy to ~/.config/hashiru/hypr/monitors.lua to use. Replaces Hashiru's
-- monitors.lua outright, so keep the catch-all at the bottom.
--
-- Both are matched by description rather than by output name: the two panels
-- are the same model, and the serial in the description is the only thing that
-- reliably tells them apart across reboots and cable swaps.

-- Left, landscape.
hl.monitor({ output = "desc:LG Electronics LG ULTRAWIDE 0x0001D52A", mode = "2560x1080@60", position = "0x0", scale = 1 })

-- Right, rotated 90°.
hl.monitor({ output = "desc:LG Electronics LG ULTRAWIDE 0x0004F527", mode = "2560x1080@60", position = "2560x0", scale = 1, transform = 1 })

hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })
