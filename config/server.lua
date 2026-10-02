---Toxic iPad — server-only configuration. Never sent to clients.

return {
    ---Log level for the console: 'debug' | 'info' | 'warn' | 'error'.
    ---The convar `toxic_ipad:debug true` forces 'debug'.
    logLevel = 'info',

    ---Passcode brute-force protection. Attempts are counted per device,
    ---so dropping and picking the tablet up again does not reset them.
    lockout = {
        maxAttempts = 5,
        ---Lockout length after each further failure past maxAttempts (seconds).
        steps = { 60, 300, 900 },
    },

    ---Players who send more than this are rate limited (per player, per minute).
    rateLimits = {
        unlock = 10,
        passcode = 3,
        power = 30,
        settings = 60,
        notes = 120,
        notif = 60,
        apps = 30,       -- App Store installs, uninstalls, permission answers
        appdata = 120,   -- third-party app storage (SDK ipad.storage)
        files = 90,
        storage = 20,    -- Settings › Storage usage
        camera = 20,     -- Camera upload tickets + saves (photos.perMinute limits photos)
        photos = 90,     -- Photos library: list, delete, favourite, Save to Files
        findmy = 20,     -- Find My: list, Lost Mode, remote erase
        default = 60,
    },

    ---Keep a device in memory this long after the tablet was closed, so
    ---reopening it costs no database queries (seconds).
    cacheSeconds = 600,

    ---Debounce for writing settings changes to the database (milliseconds).
    settingsFlushMs = 5000,

    ---Allow the optional open-keybind (config/client.lua keybind.enabled).
    ---Keep both in sync: with false, the server ignores the key even if a
    ---client turns it on.
    allowKeybindOpen = false,

    ---Files app limits (virtual files: names, sizes and references, no binary data).
    files = {
        maxEntries = 2000,   -- files + folders per device
        maxDepth = 8,        -- folder nesting below Documents / Downloads (max 12)
    },

    ---Camera & Photos (docs/INSTALLATION.md › Camera).
    photos = {
        maxPerDevice = 500,  -- photos a tablet can keep
        perMinute = 6,       -- photos a tablet can take per minute
        perHour = 60,        -- upload tickets per tablet per hour (each one is an upload on your account)
        sizeKB = 2400,       -- virtual size of one photo (counts toward storage)
        recordStreet = true, -- store the street name where a photo was taken
    },

    ---Where photos are uploaded. The Camera app is hidden when this is 'none',
    ---when the provider is not configured, or when neither screencapture nor
    ---screenshot-basic is started.
    ---  'fivemanage' — recommended. Put your API token in `fivemanage.token` below.
    ---  'custom'     — your own endpoint (it must not need a secret: the URL reaches clients)
    ---  'none'       — no Camera app
    uploader = {
        provider = 'fivemanage',
        fivemanage = {
            ---Your Fivemanage API token (dashboard › API tokens). This file stays on
            ---the server: clients never receive it. Do not share this file (or
            ---screenshots of it). If the convar `set toxic_ipad:fivemanage_token "..."`
            ---is set in server.cfg, it is used instead.
            token = '',
            hosts = { 'r2.fivemanage.com' },   -- where Fivemanage serves uploaded files
            ---With the `screencapture` resource started, the server captures and
            ---uploads photos itself (recommended: nothing upload-related reaches
            ---clients). false = always use client uploads through presigned URLs.
            serverCapture = true,
            ---Server capture photo format. 'webp' is several times smaller than
            ---'png' at the same look, so photos upload faster. 'webp' · 'jpg' · 'png'
            encoding = 'webp',
            quality = 0.8,                     -- 0.1 – 1.0 (bigger, slower files above 0.9)
            maxWidth = 1280,                   -- photo size; larger = slower uploads
            maxHeight = 720,
        },
        custom = {
            url = '',                          -- e.g. 'https://img.example.com/upload'
            field = 'file',                    -- multipart field of the image
            urlPath = 'url',                   -- where the image URL is in the JSON answer ('data.url', …)
            hosts = {},                        -- e.g. { 'img.example.com' }
        },
    },

    ---ACE permission for admin commands (/ipadgive, /ipadnotify, /ipadpin, /ipadwipe).
    adminAce = 'group.admin',
}
