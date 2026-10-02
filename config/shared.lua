---Toxic iPad — shared configuration (read by the server and the client).
---Values a server owner is expected to change. Server-only limits live in
---config/server.lua; visuals and controls in config/client.lua.

return {
    ---Framework bridge: 'auto' | 'qbox' | 'toxic_core'
    ---'auto' picks toxic_core when its API is available, otherwise qbx_core.
    framework = 'auto',

    ---Tablet models. The KEY is the ox_inventory item name; each item is a
    ---separate model. Every visible name is text you can change freely.
    models = {
        toxic_ipad = {
            label = 'Toxic Tab Pro',          -- device name shown in Settings › About and in inventory
            chip = 'M5-class',                -- fictional hardware label, shown in About
            os = 'ToxicOS 27',                -- OS name shown on the lock screen footer and About
            storageGB = 512,                  -- 128 | 256 | 512 | 1024 | 2048 (virtual capacity)
            systemGB = 12,                    -- shown as "ToxicOS" in Settings › Storage (virtual)
        },
    },

    display = {
        ---Size of the device on screen, as a fraction of the constraining screen
        ---axis. 0.75 – 0.90; 0.80 is the default and the recommended value.
        size = 0.80,
        ---Outer device aspect ratio (landscape). 1.307 ≈ a 13-inch pro tablet.
        aspect = 1.307,
        ---Players can turn the tablet to portrait (Control Center). false = landscape only.
        portrait = true,
        overlay = {
            enabled = true,
            opacity = 0.15,                   -- scrim over the game world (0 – 0.6)
        },
        animation = {
            openMs = 450,
            closeMs = 350,
        },
    },

    lock = {
        passcodeLengths = { 4, 6 },
        faceId = true,                        -- simulated face unlock for the device owner
    },

    battery = {
        enabled = true,
        drainPerMinuteOpen = 0.35,            -- % per real minute with the screen on
        ---% per real hour while the tablet is put away. Positive = it charges
        ---(players are assumed to charge it off-screen); negative = it drains;
        ---0 = keeps its level. Use 0 or a negative value when players should
        ---charge with power banks / stations below.
        closedPerHour = 20,
        lowPowerMultiplier = 0.6,             -- Low Power Mode drains at this fraction
        lowWarningAt = 20,                    -- %

        ---Power bank: an EXISTING inventory item (it may also be used by a
        ---phone resource — the tablet only removes one, it never registers
        ---the item's use). Settings › Battery › Use Power Bank, or the prompt
        ---when an empty tablet is opened. Charges gradually; no drain meanwhile.
        powerBank = {
            enabled = true,
            item = 'powerbank',               -- ox_inventory item name
            percent = 100,                    -- total charge one power bank gives (stops at 100 %)
            perMinute = 5,                    -- % per real minute while it charges
        },

        ---Charging stations (needs ox_target): "Charge Tablet" at these spots
        ---charges the tablet you hold (or the first one you carry) while you stay there.
        stations = {
            enabled = false,
            perMinute = 3,                    -- % per real minute
            radius = 1.2,                     -- metres (the player must stay within radius + 3 m)
            points = {
                -- { coords = vec3(-1082.9, -247.5, 37.8), label = 'Lifeinvader' },
            },
        },
    },

    ---Find My: every tablet a character owns, where it was last seen, Lost
    ---Mode and remote erase. waypoint = "Directions" sets a GPS waypoint.
    findMy = { enabled = true, waypoint = true },

    clock = {
        source = 'game',                      -- 'game' (in-game clock) | 'real' (server's real time)
        use24h = true,
    },

    ---Brand accent used by the OS (tint colour). Any CSS colour.
    accent = '#0a84ff',
}
