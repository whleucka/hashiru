-- Layer Rules
-- https://wiki.hypr.land/Configuring/Basics/Window-Rules/#layer-rules
--
-- decoration:blur only reaches *windows*. Layer surfaces (waybar, fuzzel, mako,
-- swayosd) render unblurred until a layer rule opts each namespace in, so
-- without this file the blur config is half-applied and it shows.
--
-- ignore_alpha skips blurring pixels below that alpha, which keeps a
-- translucent panel's fully-transparent gaps from smearing the wallpaper.
--
-- Namespaces verified against `hyprctl layers` on 0.56.2: waybar -> "waybar",
-- swayosd -> "swayosd", mako -> "notifications", and fuzzel -> "launcher"
-- (fuzzel's default, NOT "fuzzel" -- see fuzzel(1) --namespace).

hl.layer_rule({ match = { namespace = "waybar" }, blur = true, ignore_alpha = 0.4 })
hl.layer_rule({ match = { namespace = "launcher" }, blur = true, ignore_alpha = 0.3 })
hl.layer_rule({ match = { namespace = "notifications" }, blur = true, ignore_alpha = 0.3 })
hl.layer_rule({ match = { namespace = "swayosd" }, blur = true, ignore_alpha = 0.3 })

-- Notifications leak into recordings and shares. Mako is where 2FA codes,
-- message previews and mail subjects land, so keep it out of screencasts.
hl.layer_rule({ match = { namespace = "notifications" }, no_screen_share = true })
