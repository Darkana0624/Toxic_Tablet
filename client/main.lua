---Toxic iPad — client device controller.
---
---Lua owns NUI focus (docs/UI_SYSTEM.md §8): the page never grabs or
---releases it. Every close path — Esc/power in the NUI, the server forcing a
---close, death, resource stop, a page that never answers — ends in
---closeDevice(), which releases focus FIRST and animates afterwards.

local constants = require 'shared.constants'
local shared = require 'config.shared'
local cfg = require 'config.client'
local holding = require 'client.holding'
local world = require 'client.world'
local camera = require 'client.camera'

local RESOURCE = cache.resource

---@type 'closed'|'opening'|'open'|'closing'
local state = 'closed'
local pageReady = false     -- the NUI finished loading and registered its listener
local pageInit = false      -- locale + static config sent once
local openToken = 0
local blurMode = cfg.worldBlur

---A fresh secret per open, known only to the tablet page (sent with the
---`open` message). Third-party app iframes inside the tablet can post to
---this resource's NUI callbacks too, but cannot read the page's memory, so
---`call` and `close` without the token are refused (docs/SECURITY.md).
local nuiToken = ''

---@return string
local function newToken()
    local chars = {}
    for i = 1, 24 do chars[i] = string.format('%x', math.random(0, 15)) end
    return table.concat(chars)
end

-- locale -----------------------------------------------------------------

---UI strings (keys starting with "ui.") for the active ox_lib locale,
---falling back to English for missing keys.
---@return string lang
---@return table<string, string> strings
local function loadUiStrings()
    local lang = GetConvar('ox:locale', 'en')
    local function read(code)
        local raw = LoadResourceFile(RESOURCE, ('locales/%s.json'):format(code))
        if not raw then return {} end
        local ok, data = pcall(json.decode, raw)
        return ok and type(data) == 'table' and data or {}
    end
    local strings = {}
    for key, value in pairs(read('en')) do
        if key:sub(1, 3) == 'ui.' then strings[key] = value end
    end
    if lang ~= 'en' then
        for key, value in pairs(read(lang)) do
            if key:sub(1, 3) == 'ui.' then strings[key] = value end
        end
    end
    return lang, strings
end

---@param action string
---@param data any
local function send(action, data)
    SendNUIMessage({ action = action, data = data })
end

local function initPage()
    if pageInit then return end
    local lang, strings = loadUiStrings()
    send('init', { lang = lang, strings = strings })
    pageInit = true
end

---@return table
local function clockSync()
    return {
        source = shared.clock.source,
        use24h = shared.clock.use24h,
        hours = GetClockHours(),
        minutes = GetClockMinutes(),
        msPerGameMinute = GetMillisecondsPerGameMinute(),
    }
end

-- close ------------------------------------------------------------------

---@param reason string
---@param fromServer? boolean the server already ended the session
local function closeDevice(reason, fromServer)
    if state == 'closed' or state == 'closing' then return end
    state = 'closing'
    openToken = openToken + 1
    nuiToken = ''
    camera.stop(true)

    SetNuiFocus(false, false)
    SetNuiFocusKeepInput(false)
    send('close', { reason = reason })
    world.disable(shared.display.animation.closeMs)

    if not fromServer then
        TriggerServerEvent('toxic_ipad:server:closed')
    end

    SetTimeout(shared.display.animation.closeMs, function()
        holding.stop()
        if state == 'closing' then state = 'closed' end
    end)
end

-- while open: cheap watcher (500 ms) + optional movement loop -------------

---@param token integer
local function watch(token)
    CreateThread(function()
        while state == 'open' and openToken == token do
            local ped = cache.ped
            if IsEntityDead(ped) or IsPedCuffed(ped) or IsPedRagdoll(ped) or IsPedSwimming(ped) then
                closeDevice('interrupted')
                break
            end
            Wait(500)
        end
    end)

    if not cfg.allowMovement then return end

    CreateThread(function()
        while state == 'open' and openToken == token do
            DisableControlAction(0, 1, true)    -- look left/right
            DisableControlAction(0, 2, true)    -- look up/down
            DisableControlAction(0, 24, true)   -- attack
            DisableControlAction(0, 25, true)   -- aim
            DisableControlAction(0, 199, true)  -- pause (P)
            DisableControlAction(0, 200, true)  -- pause (Esc) — Esc belongs to the tablet
            DisableControlAction(0, 257, true)  -- attack 2
            DisableControlAction(0, 263, true)  -- melee
            Wait(0)
        end
    end)
end

-- open -------------------------------------------------------------------

RegisterNetEvent('toxic_ipad:client:open', function(payload)
    -- Opened again during the close animation: wait for it to finish
    -- instead of ignoring the open (the server already has a session).
    if state == 'closing' then
        local waited = 0
        while state == 'closing' and waited < 1500 do
            Wait(50)
            waited = waited + 50
        end
    end
    if state ~= 'closed' then
        -- still busy: tell the server, so it does not keep a session we never show
        TriggerServerEvent('toxic_ipad:server:closed')
        return
    end
    if not pageReady then
        -- The page has not reported in yet (first seconds after joining).
        -- Try anyway: if it is not listening, the watchdog below gives
        -- focus back and tells the server.
        lib.notify({ title = locale('app_name'), description = locale('error.not_ready'), type = 'inform' })
    end

    state = 'opening'
    openToken = openToken + 1
    local token = openToken

    initPage()
    holding.start(cfg.holding)
    world.enable(blurMode, cfg, shared.display.animation.openMs)

    SetNuiFocus(true, true)
    SetNuiFocusKeepInput(cfg.allowMovement == true)

    payload.clock = clockSync()
    nuiToken = newToken()
    payload.token = nuiToken
    send('open', payload)

    -- Watchdog: the page must acknowledge within 3 s or we give focus back.
    SetTimeout(3000, function()
        if state == 'opening' and openToken == token then
            print('^1[toxic_ipad] the tablet page did not answer; closing to release the mouse.^7')
            closeDevice('watchdog')
        end
    end)
end)

RegisterNetEvent('toxic_ipad:client:forceClose', function(reason)
    closeDevice(reason, true)
    if reason == 'battery_empty' or reason == 'device_gone' or reason == 'device_lost' or reason == 'erased' then
        lib.notify({ title = locale('app_name'), description = locale('error.' .. reason), type = 'inform' })
    end
end)

RegisterNetEvent('toxic_ipad:client:notify', function(payload)
    -- Stored server-side either way; only an open tablet shows it live.
    if state == 'open' or state == 'opening' then
        send('notify', payload)
    end
end)

-- Live updates for an open tablet. The server already filtered each list
-- for this player; a closed tablet gets fresh lists on its next open.
local LIVE = {
    ['toxic_ipad:client:apps'] = 'apps',              -- an app resource started/stopped
    ['toxic_ipad:client:openApp'] = 'openApp',        -- exports.toxic_ipad:OpenApp
    ['toxic_ipad:client:filesChanged'] = 'filesChanged', -- exports.toxic_ipad:SaveFile
    ['toxic_ipad:client:widgetData'] = 'widgetData',     -- exports.toxic_ipad:UpdateWidget
    ['toxic_ipad:client:device'] = 'device',             -- a charge started / ended
}
for event, action in pairs(LIVE) do
    RegisterNetEvent(event, function(payload)
        if state == 'open' or state == 'opening' then
            send(action, payload)
        end
    end)
end

-- NUI callbacks --------------------------------------------------------------

RegisterNUICallback('ready', function(_, cb)
    pageReady = true
    cb({ ok = true })
end)

RegisterNUICallback('opened', function(_, cb)
    if state == 'opening' then
        state = 'open'
        watch(openToken)
    end
    cb({ ok = true })
end)

RegisterNUICallback('close', function(data, cb)
    cb({ ok = true })
    if type(data) ~= 'table' or data.token ~= nuiToken or nuiToken == '' then return end
    closeDevice(tostring(data.reason or 'nui'))
end)

---Relays a request to the server. Only names in constants.CALLBACKS are
---forwarded; the server checks everything again.
RegisterNUICallback('call', function(data, cb)
    if type(data) ~= 'table' or type(data.name) ~= 'string' or not constants.CALLBACKS[data.name] then
        return cb({ ok = false, err = constants.ERR.bad_request })
    end
    if nuiToken == '' or data.token ~= nuiToken then
        return cb({ ok = false, err = constants.ERR.bad_request })
    end
    if state ~= 'open' and state ~= 'opening' then
        return cb({ ok = false, err = constants.ERR.no_session })
    end
    local result = lib.callback.await(('toxic_ipad:server:%s'):format(data.name), false, data.payload or {})
    cb(result or { ok = false, err = constants.ERR.internal })
end)

-- camera mode -----------------------------------------------------------------

---Back from the camera to the tablet (the tablet may have closed meanwhile).
---@param reason string
local function exitCamera(reason)
    if not camera.isActive() then return end
    camera.stop(false)
    if state ~= 'open' then return end
    SetNuiFocus(true, true)
    SetNuiFocusKeepInput(cfg.allowMovement == true)
    holding.start(cfg.holding)
    world.enable(blurMode, cfg, 250)
end

local cameraHooks = { send = send, exit = exitCamera }
-- configs copied from before 0.5.0 have no camera block
local cameraCfg = cfg.camera or {
    fovDefault = 50.0, fovMin = 15.0, fovMax = 70.0, zoomStep = 5.0, sensitivity = 8.0, selfieDistance = 0.55, quality = 0.85,
}

---The Camera app asks to enter or leave camera mode. The server still
---decides whether a photo may be taken (photos:ticket).
RegisterNUICallback('camera', function(data, cb)
    if type(data) ~= 'table' or nuiToken == '' or data.token ~= nuiToken then
        return cb({ ok = false, err = constants.ERR.bad_request })
    end
    if data.action == 'stop' then
        exitCamera('nui')
        return cb({ ok = true })
    end
    if state ~= 'open' or camera.isActive() then return cb({ ok = false, err = constants.ERR.bad_request }) end
    if not camera.available() then return cb({ ok = false, err = constants.ERR.camera_unavailable }) end
    cb({ ok = true })
    SetNuiFocus(false, false)
    SetNuiFocusKeepInput(false)
    holding.stop()
    world.disable(200)
    if not camera.start(cameraCfg, { selfie = data.selfie == true }, cameraHooks) then
        -- could not start after all: give the tablet back
        SetNuiFocus(true, true)
        SetNuiFocusKeepInput(cfg.allowMovement == true)
        holding.start(cfg.holding)
        world.enable(blurMode, cfg, 0)
        send('camera', { active = false })
    end
end)

-- Find My helpers ---------------------------------------------------------------

---Street and area names for coordinates (the server sends numbers only).
RegisterNUICallback('streets', function(data, cb)
    if type(data) ~= 'table' or nuiToken == '' or data.token ~= nuiToken or type(data.points) ~= 'table' then
        return cb({ ok = false })
    end
    local out = {}
    for i = 1, math.min(#data.points, 10) do
        local p = data.points[i]
        if type(p) == 'table' and type(p.x) == 'number' and type(p.y) == 'number' and type(p.z) == 'number' then
            local street = GetStreetNameFromHashKey(GetStreetNameAtCoord(p.x, p.y, p.z))
            local zone = GetLabelText(GetNameOfZone(p.x, p.y, p.z))
            if zone == 'NULL' then zone = '' end
            out[i] = { street = street ~= '' and street or nil, zone = zone ~= '' and zone or nil }
        else
            out[i] = {}
        end
    end
    cb({ ok = true, names = out })
end)

---Find My › Directions: a GPS waypoint (never a teleport).
RegisterNUICallback('waypoint', function(data, cb)
    if type(data) ~= 'table' or nuiToken == '' or data.token ~= nuiToken
        or type(data.x) ~= 'number' or type(data.y) ~= 'number' or (shared.findMy and shared.findMy.waypoint == false) then
        return cb({ ok = false })
    end
    SetNewWaypoint(data.x + 0.0, data.y + 0.0)
    cb({ ok = true })
end)

-- power ----------------------------------------------------------------------

---The server found an empty tablet and a power bank in the inventory.
RegisterNetEvent('toxic_ipad:client:batteryEmpty', function(data)
    if type(data) ~= 'table' or type(data.slot) ~= 'number' then return end
    local answer = lib.alertDialog({
        header = locale('battery_empty_title'),
        content = locale('powerbank_prompt', tostring(data.label or 'Power Bank')),
        centered = true,
        cancel = true,
        labels = { confirm = locale('powerbank_use'), cancel = locale('cancel') },
    })
    if answer == 'confirm' then TriggerServerEvent('toxic_ipad:server:chargeEmpty', data.slot) end
end)

-- Charging stations (optional, ox_target).
do
    local stations = shared.battery.stations
    if shared.battery.enabled and stations and stations.enabled and type(stations.points) == 'table' and #stations.points > 0 then
        local target = require 'bridge.target.ox_target'
        local function setup()
            if not target.available() then return end
            target.addStations(stations.points, stations.radius or 1.2, locale('station_charge'), function(index)
                TriggerServerEvent('toxic_ipad:server:station', index)
            end)
        end
        CreateThread(setup)
        AddEventHandler('onClientResourceStart', function(resource)
            if resource == 'ox_target' then setup() end
        end)
        AddEventHandler('onResourceStop', function(resource)
            if resource == RESOURCE then target.clear() end
        end)
    end
end

---Errors from the page, printed to F8 (the NUI has no devtools in-game).
RegisterNUICallback('log', function(data, cb)
    cb({ ok = true })
    if type(data) == 'table' and type(data.message) == 'string' then
        print(('^1[toxic_ipad:nui] %s^7'):format(data.message:sub(1, 500)))
    end
end)

---Clock re-sync on request (e.g. after the page woke from sleep).
RegisterNUICallback('clock', function(_, cb)
    cb(clockSync())
end)

-- client exports (this player's own tablet) ---------------------------------

---@return boolean
exports('IsOpen', function()
    return state == 'open' or state == 'opening'
end)

---@return boolean closed
exports('Close', function()
    if state ~= 'open' and state ~= 'opening' then return false end
    closeDevice('export')
    return true
end)

---Opens an app (and the tablet, if it is put away). The server checks
---access, installation and that the player carries a tablet.
---@param appId string
---@param route? string
exports('OpenApp', function(appId, route)
    if type(appId) ~= 'string' then return false end
    TriggerServerEvent('toxic_ipad:server:openApp', appId, route)
    return true
end)

-- optional keybind -------------------------------------------------------

if cfg.keybind and cfg.keybind.enabled then
    lib.addKeybind({
        name = 'toxic_ipad_open',
        description = locale('keybind_open'),
        defaultKey = cfg.keybind.defaultKey,
        onPressed = function()
            if state == 'closed' then
                TriggerServerEvent('toxic_ipad:server:requestOpen')
            end
        end,
    })
end

-- debug: switch the world blur live to compare modes in-game -------------

if GetConvar('toxic_ipad:debug', 'false') == 'true' then
    RegisterCommand('ipad_blur', function(_, args)
        local mode = args[1]
        if mode == 'native' or mode == 'timecycle' or mode == 'none' then
            blurMode = mode
            print(('[toxic_ipad] world blur = %s (reopen the tablet to see it)'):format(mode))
        else
            print('[toxic_ipad] usage: ipad_blur native|timecycle|none')
        end
    end, false)
end

-- cleanup ----------------------------------------------------------------

AddEventHandler('onResourceStop', function(resource)
    if resource ~= RESOURCE then return end
    camera.stop(true)
    SetNuiFocus(false, false)
    SetNuiFocusKeepInput(false)
    world.disable(0)
    holding.stop()
end)
