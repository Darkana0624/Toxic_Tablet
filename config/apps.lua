---Toxic iPad — built-in apps and home screen defaults (server-only).
---
---`name` / `description` are locale keys (locales/*.json), so every app is
---translated. Optional fields:
---  access    = { groups = { police = 0 } }  who may see the app (job/gang → min grade)
---  install   = 'preinstalled' (default) | 'store' (the player gets it from the App Store)
---  removable = false keeps the app on every tablet (Settings and App Store must stay)
---
---Third-party apps are NOT listed here: their resource registers them with
---exports.toxic_ipad:RegisterApp (docs/APP_SDK.md).

return {
    builtin = {
        { id = 'settings', name = 'app.settings', icon = 'settings', category = 'utilities', order = 1, removable = false },
        { id = 'appstore', name = 'app.appstore', icon = 'appstore', category = 'utilities', order = 2, removable = false },
        { id = 'files', name = 'app.files', icon = 'files', category = 'utilities', order = 3, description = 'store.desc_files' },
        { id = 'notes', name = 'app.notes', icon = 'notes', category = 'utilities', order = 4, description = 'store.desc_notes' },
        { id = 'calculator', name = 'app.calculator', icon = 'calculator', category = 'utilities', order = 5, description = 'store.desc_calculator' },
        { id = 'clock', name = 'app.clock', icon = 'clock', category = 'utilities', order = 6, description = 'store.desc_clock' },
        -- Camera is hidden automatically until photo uploads are set up (config/server.lua uploader)
        { id = 'camera', name = 'app.camera', icon = 'camera', category = 'utilities', order = 7, removable = false },
        { id = 'photos', name = 'app.photos', icon = 'photos', category = 'utilities', order = 8, removable = false },
        -- hidden when config/shared.lua findMy.enabled = false
        { id = 'findmy', name = 'app.findmy', icon = 'findmy', category = 'utilities', order = 9, removable = false },
    },

    ---Apps in the dock on a new device (max 6). Players can change it later.
    defaultDock = { 'settings', 'files', 'notes', 'appstore' },
}
