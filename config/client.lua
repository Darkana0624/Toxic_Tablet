---Toxic iPad — client configuration (visuals, controls, animation).

return {
    ---Optional keybind that opens the first tablet in your inventory.
    ---Set to false to allow opening only from the inventory.
    keybind = { enabled = false, defaultKey = 'F10' },

    ---What happens to the game world behind the tablet.
    ---'native'    — GTA screen blur (strongest, cheapest)
    ---'timecycle' — soft blur via a timecycle modifier (strength below)
    ---'none'      — no blur, only the scrim from config/shared.lua
    worldBlur = 'native',
    timecycle = { modifier = 'hud_def_blur', strength = 0.6 },

    ---The prop and animation played while holding the tablet.
    holding = {
        enabled = true,
        prop = 'prop_cs_tablet',
        bone = 60309,                                   -- SKEL_L_Hand
        offset = vec3(0.03, 0.002, -0.0),
        rotation = vec3(10.0, 160.0, 0.0),
        dict = 'amb@code_human_in_bus_passenger_idles@female@tablet@base',
        clip = 'base',
        flag = 49,                                      -- upper body + loop + keep controllable
    },

    ---Camera app (needs screenshot-basic and an uploader, see config/server.lua).
    ---Controls: mouse aim · left click / Enter shutter · E flip · wheel zoom · Backspace / Esc / right click exit
    camera = {
        fovDefault = 50.0,
        fovMin = 15.0,        -- most zoomed in
        fovMax = 70.0,        -- widest
        zoomStep = 5.0,
        sensitivity = 8.0,
        selfieDistance = 0.55,-- metres in front of the face
        quality = 0.8,        -- WebP quality 0.1 – 1.0 for client uploads (bigger, slower files above 0.9)
    },

    ---false: the player stands still while the tablet is open (no per-frame cost).
    ---true: the player can walk; costs one per-frame loop while open.
    allowMovement = false,
}
