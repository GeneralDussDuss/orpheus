-- Orpheus: window rules and keys for Hyprland.
--
-- install.sh links this file to ~/.config/hypr/orpheus.lua and adds
-- require("hypr.orpheus") to hyprland.lua, so a `git pull` updates it.
-- To keep the rules but bring your own keys, put this in hyprland.lua
-- above the require:
--
--   orpheus_bindings = false

-- The player: a centered floating window.
o.window({ class = "org.quickshell", title = "^Orpheus$" }, {
  float = true,
  center = true,
  size = { "monitor_w*0.72", "monitor_h*0.8" },
  tag = "-default-opacity",
  opacity = "1 1",
})
-- The desktop widget: "Orpheus Widget" tiles into the layout; the [float] variant floats.
o.window({ class = "org.quickshell", title = "^Orpheus Widget" }, { tag = "-default-opacity", opacity = "1 1" })
o.window({ class = "org.quickshell", title = "^Orpheus Widget \\[float\\]$" }, { float = true, size = { 520, 420 } })
-- Video: its mpv runs as app id orpheus.video, so it skips Omarchy's generic
-- mpv rule and opens as a centered 16:9 screen.
o.window("^orpheus\\.video$", {
  float = true,
  center = true,
  size = { "(monitor_h*0.62*16/9)", "(monitor_h*0.62)" },
  tag = "-default-opacity",
  opacity = "1 1",
})

if _G.orpheus_bindings ~= false then
  -- Super+Shift+M is Omarchy's music key (Spotify by default); Orpheus takes it.
  pcall(hl.unbind, "SUPER + SHIFT + M")
  o.bind("SUPER + SHIFT + M", "Music", "omarchy-shell -q orpheus library")
  o.bind("SUPER + CTRL + M", "Music visualizer", "omarchy-shell -q orpheus toggle")
  o.bind("SUPER + ALT + M", "Music widget", "omarchy-shell -q orpheus widget enabled toggle")
  o.bind("CTRL + SHIFT + O", "Orpheus sign-in", "omarchy-shell -q orpheus login")
end
