-- Minimal Hyprland Lua config tracked by arch-postinstall.
-- Hyprland 0.55+ uses Lua as the primary configuration format.

require("./gpu")

local terminal = "ghostty"

hl.config({
    general = {
        gaps_in = 5,
        gaps_out = 10,
        border_size = 2,
    },

    decoration = {
        rounding = 8,
    },

    input = {
        kb_layout = "us,ru",
        kb_options = "grp:alt_shift_toggle",
        follow_mouse = 1,
        touchpad = {
            natural_scroll = true,
        },
    },

    misc = {
        disable_hyprland_logo = true,
        disable_splash_rendering = true,
        -- 0x111111 is also Hyprland's default compositor background color.
        background_color = "0x111111",
    },
})

-- Authentication agent + idle/lock daemon.
hl.on("hyprland.start", function()
    hl.exec_cmd("systemctl --user start hyprpolkitagent.service")
    hl.exec_cmd("hypridle")
    hl.exec_cmd("sh -lc 'dbus-update-activation-environment --systemd --all && systemctl --user start vicinae.service'")
end)

-- Basic application/window controls.
hl.bind("SUPER + RETURN", hl.dsp.exec_cmd(terminal))
hl.bind("SUPER + Q", hl.dsp.window.close({}))
hl.bind("SUPER + SHIFT + E", hl.dsp.exit())
hl.bind("SUPER + F", hl.dsp.window.fullscreen({
    action = "toggle",
    mode = "fullscreen",
}))
hl.bind("SUPER + V", hl.dsp.window.float({ action = "toggle" }))
hl.bind("SUPER + L", hl.dsp.exec_cmd("loginctl lock-session"))

-- Vim-style focus.
hl.bind("SUPER + H", hl.dsp.focus({ direction = "l" }))
hl.bind("SUPER + J", hl.dsp.focus({ direction = "d" }))
hl.bind("SUPER + K", hl.dsp.focus({ direction = "u" }))
hl.bind("SUPER + semicolon", hl.dsp.focus({ direction = "r" }))

-- Workspaces 1..5.
for i = 1, 5 do
    local ws = tostring(i)
    hl.bind("SUPER + " .. ws, hl.dsp.focus({ workspace = ws }))
    hl.bind(
        "SUPER + SHIFT + " .. ws,
        hl.dsp.window.move({ workspace = ws, follow = true })
    )
end

-- Mouse move/resize.
hl.bind(
    "SUPER + mouse:272",
    hl.dsp.window.drag(),
    { mouse = true }
)
hl.bind(
    "SUPER + mouse:273",
    hl.dsp.window.resize(),
    { mouse = true }
)

-- The service is started after Hyprland has created the graphical session.
hl.on("hyprland.start", function()
end)

-- Spotlight-like launcher.
hl.bind("SUPER + SPACE", hl.dsp.exec_cmd("vicinae toggle"))

