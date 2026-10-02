---Toxic iPad — server boot, item use, device callbacks and exports.
---docs/ARCHITECTURE.md §4 (flows) and §7 (public API).
---
---Boot either completes or aborts with a clear console error. An aborted
---boot registers no callbacks: the item then does nothing instead of doing
---something half-initialised.

local constants = require 'shared.constants'
local validate = require 'shared.validate'
local serialGen = require 'shared.serial'
local settingsDoc = require 'shared.settings'
local log = require 'server.log'

local ERR = constants.ERR
local RESOURCE = cache.resource

local config = {
    shared = require 'config.shared',
    server = require 'config.server',
    apps = require 'config.apps',
}

local ready = false
local framework, inventory, device, session, guard, notifications, notes, files, targets, photos, power, findmy
local itemNames = {}   ---@type table<string, true>
local hookIds = {}     ---@type integer[]

-- The app registry is built at load time (it is pure), so other resources
-- can call RegisterApp / RegisterWidget even while the boot below is still
-- waiting for the framework or the database.
local apps = require 'server.apps'
local appProblems = apps.init(config.apps.builtin, config.apps.defaultDock)

local openApp -- defined with the exports below

---OpenApp on a closed tablet: opened first, then launched after unlock.
---@type table<integer, { app: string, route: string?, at: integer }>
local pendingLaunch = {}

-- helpers ------------------------------------------------------------------

---@param src integer
---@param key string
---@param kind? 'error'|'inform'|'success'
local function notify(src, key, kind)
    TriggerClientEvent('ox_lib:notify', src, { title = locale('app_name'), description = locale(key), type = kind or 'error' })
end

---@param itemName string
---@param serial string
---@param metadata table
---@return table
local function itemMetadata(itemName, serial, metadata)
    local model = config.shared.models[itemName] or {}
    metadata.serial = serial
    metadata.description = locale('item_description', model.label or itemName, model.storageGB or 0, serial)
    return metadata
end

---Last UpdateWidget values this player may see on this device.
---@param s IpadSession
---@return table<string, any>?
local function widgetDataFor(s)
    local stored = s.device.widgetData
    if not stored then return nil end
    local out, any = {}, false
    for id, entry in pairs(stored) do
        -- data from an earlier registration (the resource restarted) is stale
        local def = apps.getWidget(id)
        if def and def.gen == entry.gen and apps.widgetVisible(s.src, s.device, id) then
            out[id] = entry.data
            any = true
        end
    end
    return any and out or nil
end

---The data the NUI needs to render the device on open.
---@param s IpadSession
---@return table
local function bootPayload(s)
    local shared = config.shared
    local launch = pendingLaunch[s.src]
    pendingLaunch[s.src] = nil
    if launch and (os.time() - launch.at > 15 or not apps.canUse(s.src, launch.app) or not apps.isInstalled(s.device, launch.app)) then
        launch = nil
    end
    return {
        device = device.summary(s.device, s.isOwner),
        settings = s.device.settings,
        apps = apps.visibleFor(s.src, s.device),
        widgets = apps.widgetsFor(s.src, s.device),
        defaultDock = apps.defaultDock(),
        launch = launch and { app = launch.app, route = launch.route } or nil,
        notifications = notifications.forSession(s),
        widgetData = widgetDataFor(s),
        -- Lost Mode: someone else holds the owner's lost tablet
        lost = (s.device.lost and not s.isOwner) and { message = s.device.lostMessage } or nil,
        powerBank = device.powerBankCfg().enabled or nil,
        display = shared.display,
        accent = shared.accent,
        clock = shared.clock,
        lock = { faceId = shared.lock.faceId, lengths = shared.lock.passcodeLengths },
        battery = {
            enabled = shared.battery.enabled,
            drainPerMinuteOpen = shared.battery.drainPerMinuteOpen,
            lowPowerMultiplier = shared.battery.lowPowerMultiplier,
            lowWarningAt = shared.battery.lowWarningAt,
        },
    }
end

-- open flow (ARCHITECTURE §4.1) -----------------------------------------

---@param src integer
---@param slot integer
---@param rated? boolean the caller already took a rate token
---@return boolean ok
---@return string? err
local function openDevice(src, slot, rated)
    if not ready then return false, ERR.internal end
    if session.get(src) then return false, ERR.already_open end
    if not rated and not guard.rate(src, 'open') then return false, ERR.rate_limited end
    if not framework.isLoaded(src) then return false, ERR.not_loaded end
    if not framework.canUseDevice(src) then return false, ERR.cannot_use end

    local slotData = inventory.getSlot(src, slot)
    if not slotData or not itemNames[slotData.name] then return false, ERR.no_device end

    local metadata = type(slotData.metadata) == 'table' and slotData.metadata or {}
    local serial = metadata.serial
    if serial and device.isErasing(serial) then return false, ERR.busy end

    if not serialGen.isValid(serial) then
        -- a tablet created before toxic_ipad was installed (no createItem hook)
        serial = serialGen.generate()
        inventory.setMetadata(src, slot, itemMetadata(slotData.name, serial, metadata))
    end

    local identifier = framework.getIdentifier(src)
    local rec = device.resolve(serial, slotData.name, identifier)
    if not rec then
        if device.isErasing(serial) then return false, ERR.busy end
        log.error('device', 'could not load or create device', { serial = serial })
        return false, ERR.internal
    end
    apps.loadDevice(rec)

    -- the player may have dropped the item or opened twice while we waited on SQL
    if session.get(src) then return false, ERR.already_open end
    if not inventory.slotHoldsSerial(src, slot, serial, itemNames) then return false, ERR.device_gone end

    -- Two items carrying the same serial (metadata copied by another script
    -- or a duplication bug) must never be open at the same time.
    for otherSrc, other in pairs(session.all()) do
        if other.device == rec and otherSrc ~= src then
            log.security('device', 'serial already open by another player', { serial = serial, src = src, other = otherSrc })
            return false, ERR.in_use
        end
    end

    device.settleBattery(rec)
    if config.shared.battery.enabled and rec.batteryBp <= 0 and not rec.charge then
        return false, ERR.battery_empty
    end

    local s = session.open(src, {
        serial = serial, slot = slot, itemName = slotData.name, device = rec, identifier = identifier,
    })

    TriggerClientEvent('toxic_ipad:client:open', src, bootPayload(s))
    return true
end

---@param src integer
---@param slot integer
---@param rated? boolean
local function openAndReport(src, slot, rated)
    local ok, err = openDevice(src, slot, rated)
    if ok or err == ERR.already_open then return end
    -- an empty tablet and a power bank in the pocket: offer to use it
    if err == ERR.battery_empty then
        local pb = device.powerBankCfg()
        if pb.enabled and inventory.count(src, pb.item) > 0 then
            TriggerClientEvent('toxic_ipad:client:batteryEmpty', src, { slot = slot, label = inventory.itemLabel(pb.item) })
            return
        end
    end
    notify(src, 'error.' .. err)
end

---ox_inventory item callback: items.lua `server = { export = 'toxic_ipad.useItem' }`.
---Called as (event, item, inventory, slot) — RESEARCH F4. Returning false on
---'usingItem' cancels ox_inventory's own use flow (nothing is consumed and
---no item animation plays); the open runs in its own thread because this
---export must not yield.
---@param event string
---@param item table
---@param inv table
---@param slot integer
---@return boolean?
local function useItem(event, item, inv, slot)
    if event ~= 'usingItem' then return end
    local src = inv and inv.id
    if type(src) ~= 'number' or type(slot) ~= 'number' then return false end
    CreateThread(function() openAndReport(src, slot) end)
    return false
end
exports('useItem', useItem)

-- device callbacks -------------------------------------------------------

local PIN_SCHEMA = { type = 'string', minLength = 4, maxLength = 6, pattern = '%d+' }

---@param s IpadSession
---@param payload table
---@return table
local function unlock(s, payload)
    local rec = s.device
    if s.unlocked then return { ok = true } end
    -- Lost Mode: only the owner can unlock (and doing so turns it off)
    if rec.lost and not s.isOwner then return { ok = false, err = ERR.lost } end
    local function unlocked()
        s.unlocked = true
        if rec.lost and s.isOwner then
            findmy.setLost(s, { serial = rec.serial, lost = false })
            return { ok = true, lostCleared = true }
        end
        return { ok = true }
    end

    if payload.method == 'swipe' then
        if rec.passcodeHash then return { ok = false, err = ERR.passcode_required } end
        return unlocked()
    end

    local remaining = device.lockoutRemaining(rec)
    if remaining > 0 then return { ok = false, err = ERR.lockout, seconds = remaining } end
    if not rec.passcodeHash then return { ok = false, err = ERR.no_passcode } end

    if payload.method == 'face' then
        -- Simulated biometrics: succeeds only for the recorded owner.
        if not config.shared.lock.faceId or not s.isOwner then
            return { ok = false, err = ERR.face_unavailable }
        end
        return unlocked()
    end

    -- method == 'pin'
    if type(payload.pin) ~= 'string' or #payload.pin ~= rec.passcodeLength then
        return { ok = false, err = ERR.wrong_passcode }
    end
    local ok, lockSeconds = device.checkPasscode(rec, payload.pin)
    if ok then return unlocked() end
    if lockSeconds then
        log.security('device', 'passcode lockout', { src = s.src, serial = s.serial, attempts = rec.failedAttempts })
        return { ok = false, err = ERR.lockout, seconds = lockSeconds }
    end
    return { ok = false, err = ERR.wrong_passcode, attemptsLeft = math.max(0, config.server.lockout.maxAttempts - rec.failedAttempts) }
end

---@param s IpadSession
---@param payload table
---@return table
local function setPasscode(s, payload)
    local rec = s.device
    if not s.isOwner then return { ok = false, err = ERR.not_owner } end

    if payload.new then
        local allowed = false
        for _, length in ipairs(config.shared.lock.passcodeLengths) do
            if #payload.new == length then allowed = true end
        end
        if not allowed then return { ok = false, err = ERR.bad_request } end
    end

    if rec.passcodeHash then
        local remaining = device.lockoutRemaining(rec)
        if remaining > 0 then return { ok = false, err = ERR.lockout, seconds = remaining } end
        if type(payload.current) ~= 'string' then return { ok = false, err = ERR.wrong_passcode } end
        local ok, lockSeconds = device.checkPasscode(rec, payload.current)
        if not ok then
            return { ok = false, err = lockSeconds and ERR.lockout or ERR.wrong_passcode, seconds = lockSeconds }
        end
    end

    device.setPasscode(rec, payload.new)
    log.info('device', payload.new and 'passcode set' or 'passcode removed', { serial = s.serial })
    return { ok = true, device = device.summary(rec, s.isOwner) }
end

---@param s IpadSession
---@param payload table
---@return table
local function patchSettings(s, payload)
    local rec = s.device
    local lowPowerBefore = rec.settings.battery.lowPower

    -- settle at the old rate before a rate-changing setting flips
    device.settleBattery(rec)

    local ok = settingsDoc.apply(rec.settings, payload.patch)
    if not ok then return { ok = false, err = ERR.bad_request } end

    device.markSettingsDirty(rec)
    if rec.settings.battery.lowPower ~= lowPowerBefore then
        session.scheduleShutdown(s)
    end
    return { ok = true, settings = rec.settings }
end

---Settings › Storage: what uses the virtual disk. Computed on request.
---@param s IpadSession
---@return table
local function storageUsage(s)
    local rec = s.device
    local model = config.shared.models[rec.model] or {}
    local notesBytes = files.notesBytes(rec)
    local fileCount, fileBytes = files.usage(rec)
    local photoCount, photoBytes = photos.usage(rec)
    local perApp, appBytes = {}, 0
    for appId, bytes in pairs(apps.dataUsage(rec)) do
        if bytes > 0 then
            perApp[#perApp + 1] = { id = appId, bytes = bytes }
            appBytes = appBytes + bytes
        end
    end
    table.sort(perApp, function(a, b) return a.bytes > b.bytes end)
    rec.usedBytes = notesBytes + fileBytes + photoBytes + appBytes
    return {
        ok = true,
        capacity = rec.capacityMb * 1024 * 1024,
        system = (model.systemGB or 12) * 1024 * 1024 * 1024,
        notes = notesBytes,
        files = fileBytes,
        fileCount = fileCount,
        photos = photoBytes,
        photoCount = photoCount,
        apps = perApp,
        appsTotal = appBytes,
    }
end

local function registerCallbacks()
    guard.register('device:unlock', {
        unlocked = false,
        schema = {
            type = 'table',
            fields = {
                method = { type = 'string', enum = { 'swipe', 'pin', 'face' } },
                pin = { type = 'string', optional = true, minLength = 4, maxLength = 6, pattern = '%d+' },
            },
        },
    }, unlock)

    guard.register('device:lock', {
        unlocked = false,
        schema = { type = 'table', fields = {} },
    }, function(s)
        s.unlocked = false
        return { ok = true }
    end)

    guard.register('device:setPasscode', {
        schema = {
            type = 'table',
            fields = {
                current = { type = 'string', optional = true, minLength = 4, maxLength = 6, pattern = '%d+' },
                new = { type = 'string', optional = true, minLength = PIN_SCHEMA.minLength, maxLength = PIN_SCHEMA.maxLength, pattern = PIN_SCHEMA.pattern },
            },
        },
    }, setPasscode)

    guard.register('settings:patch', {
        schema = { type = 'table', fields = { patch = { type = 'table', strict = false } } },
    }, patchSettings)

    local ID = { type = 'integer', min = 1, max = 9007199254740991 }

    guard.register('notes:list', { schema = { type = 'table', fields = {} } }, notes.list)
    guard.register('notes:save', {
        schema = {
            type = 'table',
            fields = {
                id = { type = 'integer', optional = true, min = 1, max = ID.max },
                -- byte limits here; character limits are checked in server/notes.lua
                title = { type = 'string', maxLength = notes.MAX_TITLE * 4 },
                body = { type = 'string', maxLength = notes.MAX_BODY * 4 },
                pinned = { type = 'boolean', optional = true },
            },
        },
    }, notes.save)
    guard.register('notes:delete', { schema = { type = 'table', fields = { id = ID } } }, notes.delete)

    guard.register('notif:read', {
        schema = { type = 'table', fields = { ids = { type = 'array', optional = true, min = 1, max = 100, items = ID } } },
    }, notifications.markRead)
    guard.register('notif:list', { schema = { type = 'table', fields = {} } }, notifications.list)
    guard.register('notif:clear', {
        schema = { type = 'table', fields = { id = { type = 'integer', optional = true, min = 1, max = ID.max } } },
    }, notifications.clear)

    -- App Store and permissions
    local APP_ID = { type = 'string', minLength = 3, maxLength = 32, pattern = '[a-z0-9_]+' }
    guard.register('apps:store', { schema = { type = 'table', fields = {} } }, apps.store)
    guard.register('apps:install', { schema = { type = 'table', fields = { id = APP_ID } } }, apps.install)
    guard.register('apps:uninstall', { schema = { type = 'table', fields = { id = APP_ID } } }, apps.uninstall)
    guard.register('apps:permission', {
        schema = {
            type = 'table',
            fields = {
                id = APP_ID,
                permission = { type = 'string', enum = apps.PERMISSIONS },
                state = { type = 'string', enum = { 'granted', 'denied', 'prompt' } },
            },
        },
    }, apps.setPermission)

    -- SDK storage of third-party apps. The app id is the window's app,
    -- resolved by the OS; the server checks it is installed and allowed.
    guard.register('appdata:get', { schema = { type = 'table', fields = { app = APP_ID, key = apps.KEY_SCHEMA } } }, apps.dataGet)
    guard.register('appdata:set', {
        schema = { type = 'table', fields = { app = APP_ID, key = apps.KEY_SCHEMA, value = { type = 'any' } } },
    }, apps.dataSet)
    guard.register('appdata:remove', { schema = { type = 'table', fields = { app = APP_ID, key = apps.KEY_SCHEMA } } }, apps.dataRemove)

    -- Files
    local NAME = { type = 'string', minLength = 1, maxLength = files.MAX_NAME * 4 }
    guard.register('files:list', { schema = { type = 'table', fields = { folder = { type = 'integer', optional = true, min = 1, max = ID.max } } } }, files.list)
    guard.register('files:recents', { schema = { type = 'table', fields = {} } }, files.recents)
    guard.register('files:mkdir', {
        schema = { type = 'table', fields = { parent = ID, name = NAME, unique = { type = 'boolean', optional = true } } },
    }, files.mkdir)
    guard.register('files:rename', { schema = { type = 'table', fields = { id = ID, name = NAME } } }, files.rename)
    guard.register('files:move', { schema = { type = 'table', fields = { id = ID, parent = ID } } }, files.move)
    guard.register('files:delete', { schema = { type = 'table', fields = { id = ID } } }, files.delete)
    guard.register('files:saveNote', { schema = { type = 'table', fields = { id = ID } } }, files.saveNote)

    guard.register('device:storage', { schema = { type = 'table', fields = {} } }, storageUsage)

    -- Camera & Photos. The Camera and Photos apps must be usable by this
    -- player (access groups) and installed on this tablet.
    local function needsApp(appId, handler)
        return function(s, payload)
            if not apps.canUse(s.src, appId) or not apps.isInstalled(s.device, appId) then
                return { ok = false, err = appId == 'camera' and ERR.camera_unavailable or ERR.not_installed }
            end
            return handler(s, payload)
        end
    end
    local TICKET = { type = 'string', minLength = 24, maxLength = 24, pattern = '%x+' }
    -- no device lock: it waits on the uploader's HTTP answer (up to 10 s)
    guard.register('photos:ticket', {
        lock = false,
        schema = { type = 'table', fields = { selfie = { type = 'boolean', optional = true } } },
    }, needsApp('camera', photos.ticket))
    guard.register('photos:save', {
        schema = {
            type = 'table',
            fields = {
                ticket = TICKET,
                url = { type = 'string', minLength = 12, maxLength = photos.MAX_URL },
                location = { type = 'string', optional = true, maxLength = photos.MAX_LOCATION * 4 },
            },
        },
    }, needsApp('camera', photos.save))
    -- server capture: no device lock while screencapture and Fivemanage work
    -- (photos.capture takes the lock itself for the final write)
    guard.register('photos:capture', {
        lock = false,
        schema = {
            type = 'table',
            fields = {
                ticket = TICKET,
                location = { type = 'string', optional = true, maxLength = photos.MAX_LOCATION * 4 },
            },
        },
    }, needsApp('camera', photos.capture))
    guard.register('photos:list', {
        schema = { type = 'table', fields = { before = { type = 'integer', optional = true, min = 1, max = ID.max } } },
    }, needsApp('photos', photos.list))
    guard.register('photos:get', { schema = { type = 'table', fields = { id = ID } } }, needsApp('photos', photos.get))
    guard.register('photos:delete', {
        schema = { type = 'table', fields = { ids = { type = 'array', min = 1, max = 100, items = ID } } },
    }, needsApp('photos', photos.delete))
    guard.register('photos:favorite', {
        schema = { type = 'table', fields = { id = ID, favorite = { type = 'boolean' } } },
    }, needsApp('photos', photos.favorite))
    guard.register('photos:toFiles', { schema = { type = 'table', fields = { id = ID } } }, needsApp('photos', photos.toFiles))

    -- Power
    guard.register('battery:info', { schema = { type = 'table', fields = {} } }, power.info)
    guard.register('battery:powerbank', { schema = { type = 'table', fields = {} } }, power.usePowerBank)

    -- Find My and erasing
    local SERIAL = { type = 'string', minLength = 5, maxLength = 16, pattern = constants.SERIAL_PATTERN }
    guard.register('findmy:list', { schema = { type = 'table', fields = {} } }, needsApp('findmy', findmy.list))
    guard.register('findmy:lost', {
        schema = {
            type = 'table',
            fields = {
                serial = SERIAL,
                lost = { type = 'boolean' },
                message = { type = 'string', optional = true, maxLength = findmy.MAX_MESSAGE * 4 },
            },
        },
    }, needsApp('findmy', findmy.setLost))
    guard.register('findmy:erase', { schema = { type = 'table', fields = { serial = SERIAL } } }, needsApp('findmy', findmy.eraseRemote))
    guard.register('device:erase', {
        schema = {
            type = 'table',
            fields = {
                removeOwner = { type = 'boolean' },
                pin = { type = 'string', optional = true, minLength = 4, maxLength = 6, pattern = '%d+' },
            },
        },
    }, findmy.eraseSelf)
end

---Sends the device summary again to everyone who has it open and re-plans
---their battery shutdown (a charge started or ended).
---@param rec table
local function pushDevice(rec)
    for src, s in pairs(session.all()) do
        if s.device == rec then
            TriggerClientEvent('toxic_ipad:client:device', src, device.summary(rec, s.isOwner))
            session.scheduleShutdown(s)
        end
    end
end

---Camera is offered only when uploads are configured AND screenshot-basic
---runs (it may start after us, or be restarted).
local function refreshCamera()
    -- screencapture (Fivemanage) also provides the screenshot-basic exports
    local capture = GetResourceState('screencapture') == 'started' or GetResourceState('screenshot-basic') == 'started'
    local ok = photos ~= nil and photos.uploaderReady() and capture
    apps.setAvailable('camera', ok)
    return ok
end

---Pushes the app/widget lists again to every open tablet (an app resource
---started, stopped or re-registered). Debounced: a resource usually
---registers an app and a widget together.
local pushQueued = false
local function queueRegistryPush()
    if pushQueued or not ready then return end
    pushQueued = true
    SetTimeout(250, function()
        pushQueued = false
        for src, s in pairs(session.all()) do
            TriggerClientEvent('toxic_ipad:client:apps', src, {
                apps = apps.visibleFor(src, s.device),
                widgets = apps.widgetsFor(src, s.device),
            })
        end
    end)
end

-- events -----------------------------------------------------------------

local function registerEvents()
    -- The client finished closing (any close path). Idempotent.
    RegisterNetEvent('toxic_ipad:server:closed', function()
        session.close(source --[[@as integer]], 'client', false)
    end)

    -- Optional keybind (config/client.lua): open the first carried tablet.
    -- Goes through the same checks and rate limit as the inventory.
    RegisterNetEvent('toxic_ipad:server:requestOpen', function()
        local src = source --[[@as integer]]
        if not config.server.allowKeybindOpen then return end
        if session.get(src) or not guard.rate(src, 'open') then return end
        local carried = inventory.findDevices(src, itemNames)
        if #carried == 0 then return notify(src, 'error.no_device') end
        openAndReport(src, carried[1].slot, true)
    end)

    -- "Use a power bank?" on an empty tablet → charge it and open it.
    RegisterNetEvent('toxic_ipad:server:chargeEmpty', function(slot)
        local src = source --[[@as integer]]
        if type(slot) ~= 'number' or session.get(src) or not guard.rate(src, 'open') then return end
        -- the same checks as opening, before the power bank is spent
        if not framework.isLoaded(src) or not framework.canUseDevice(src) then return notify(src, 'error.cannot_use') end
        local slotData = inventory.getSlot(src, slot)
        if not slotData or not itemNames[slotData.name] then return end
        local serial = type(slotData.metadata) == 'table' and slotData.metadata.serial
        if not serialGen.isValid(serial) then return end
        local rec = device.resolve(serial, slotData.name, framework.getIdentifier(src))
        if not rec then return end
        local acquired, ok, err = device.withLock(rec, function()
            device.settleBattery(rec)
            if rec.charge or rec.batteryBp > 0 then return true end
            return power.startPowerBank(rec, src)
        end)
        if not acquired then return notify(src, 'error.busy') end
        if not ok then return notify(src, 'error.' .. (err or 'internal')) end
        openAndReport(src, slot, true)
    end)

    -- ox_target "Charge Tablet" at a charging station.
    RegisterNetEvent('toxic_ipad:server:station', function(index)
        local src = source --[[@as integer]]
        if not guard.rate(src, 'power') then return end
        power.station(src, index)
    end)

    -- Client export OpenApp (the player's own tablet): same rules as the server export.
    RegisterNetEvent('toxic_ipad:server:openApp', function(appId, route)
        local src = source --[[@as integer]]
        if not guard.rate(src, 'open') then return end
        if type(appId) ~= 'string' or #appId > 32 then return end
        if route ~= nil and (type(route) ~= 'string' or #route > 128) then return end
        openApp(src, appId, route, true)
    end)

    AddEventHandler('playerDropped', function()
        local src = source --[[@as integer]]
        session.close(src, 'dropped', false)
        guard.forget(src)
        if photos then photos.forget(src) end
        power.forget(src)
        pendingLaunch[src] = nil
    end)

    apps.onChange(queueRegistryPush)

    framework.onUnloaded(function(src)
        session.close(src, 'unloaded', true)
    end)

    -- Follow the tablet when it moves inside the inventory; end the
    -- session when it leaves the player (drop, give, stash).
    hookIds[#hookIds + 1] = inventory.onMoved(itemNames, function(src)
        local s = session.get(src)
        if s and not guard.holding(s) then
            session.close(src, 'device_gone', true)
        end
    end)

    hookIds[#hookIds + 1] = inventory.registerSerialHook(itemNames, function(itemName, metadata)
        return itemMetadata(itemName, serialGen.generate(), metadata)
    end)
end

-- exports (ARCHITECTURE §7) -------------------------------------------------

---Opens an app on the player's tablet (docs/APP_SDK.md §6). A closed
---tablet is opened first; the app launches once the player unlocks it.
---@param src integer
---@param appId string
---@param route? string
---@param rated boolean the caller already took an 'open' rate token
---@return boolean ok
---@return string? err
openApp = function(src, appId, route, rated)
    if not ready then return false, ERR.internal end
    if type(src) ~= 'number' or type(appId) ~= 'string' or not apps.exists(appId) then return false, ERR.not_found end
    if route ~= nil and (type(route) ~= 'string' or #route > 128) then return false, ERR.bad_request end
    if not apps.canUse(src, appId) then return false, ERR.cannot_use end

    local s = session.get(src)
    if s then
        if not apps.isInstalled(s.device, appId) then return false, ERR.not_installed end
        TriggerClientEvent('toxic_ipad:client:openApp', src, { app = appId, route = route })
        return true
    end

    local carried = inventory.findDevices(src, itemNames)
    if #carried == 0 then return false, ERR.no_device end
    pendingLaunch[src] = { app = appId, route = route, at = os.time() }
    CreateThread(function() openAndReport(src, carried[1].slot, rated) end)
    return true
end

---Opens the first tablet the player carries. Asynchronous: returns whether
---the request was accepted; failures are shown to the player.
---@param src integer
---@return boolean ok
---@return string? err
exports('Open', function(src)
    if not ready then return false, ERR.internal end
    if session.get(src) then return false, ERR.already_open end
    local carried = inventory.findDevices(src, itemNames)
    if #carried == 0 then return false, ERR.no_device end
    CreateThread(function() openAndReport(src, carried[1].slot) end)
    return true
end)

---@param src integer
---@return boolean
exports('Close', function(src)
    if not session.get(src) then return false end
    CreateThread(function() session.close(src, 'export', true) end)
    return true
end)

---@param src integer
---@return boolean
exports('IsOpen', function(src)
    return session.get(src) ~= nil
end)

---The open device, else nil. Plain data only.
---@param src integer
---@return table?
exports('GetDevice', function(src)
    local s = session.get(src)
    if not s then return nil end
    return device.summary(s.device, s.isOwner)
end)

---Sends a notification to a player's tablet(s) (docs/ARCHITECTURE.md §7).
---target: player source | { serial = 'TXP-…' } | { identifier = '<citizenid>' }
---data: { app, title, message, priority? ('info'|'normal'|'success'|'warning'|'critical'), route? }
---Stored even when the tablet is closed; shown live when it is open.
---Uses the database: call it from a thread or an event handler (like any
---oxmysql-backed export, e.g. qbx_core's GetOfflinePlayer).
---@return boolean ok
---@return string? err
exports('Notify', function(target, data)
    if not ready then return false, ERR.internal end
    local ok, result, err = pcall(notifications.notify, target, data)
    if not ok then
        log.error('notify', 'Notify failed', { err = tostring(result) })
        return false, ERR.internal
    end
    return result, err
end)

exports('SdkVersion', function()
    return constants.SDK_VERSION
end)

---Registers a third-party app (docs/APP_SDK.md §2). Call it from your
---resource's server side; it may be called before toxic_ipad finished
---booting. Re-registering the same id from the same resource updates it.
---@param def table
---@return boolean ok
---@return string? err
exports('RegisterApp', function(def)
    local resource = GetInvokingResource()
    local ok, err, problems = apps.register(def, resource)
    if not ok then
        log.error('apps', ('RegisterApp from %s refused (%s)'):format(tostring(resource), err))
        for _, problem in ipairs(problems or {}) do log.error('apps', '  ' .. problem) end
        return false, err
    end
    log.info('apps', 'app registered', { app = def.id, resource = resource })
    return true
end)

---@param id string
---@return boolean
exports('UnregisterApp', function(id)
    return apps.unregister(id, GetInvokingResource())
end)

---Registers a home-screen widget whose UI lives in the calling resource.
---@param def table
---@return boolean ok
---@return string? err
exports('RegisterWidget', function(def)
    local resource = GetInvokingResource()
    local ok, err, problems = apps.registerWidget(def, resource)
    if not ok then
        log.error('apps', ('RegisterWidget from %s refused (%s)'):format(tostring(resource), err))
        for _, problem in ipairs(problems or {}) do log.error('apps', '  ' .. problem) end
        return false, err
    end
    return true
end)

---Opens an app on the player's tablet, optionally at a route. A closed
---tablet is opened first; the app launches once the player unlocks it.
---@param src integer
---@param appId string
---@param route? string
---@return boolean ok
---@return string? err
exports('OpenApp', function(src, appId, route)
    return openApp(src, appId, route, false)
end)

---Whether the player's open tablet granted an app a permission
---('location', 'camera', 'photos', 'contacts', 'microphone').
---@param src integer
---@param appId string
---@param permission string
---@return boolean
exports('HasPermission', function(src, appId, permission)
    local s = session.get(src)
    if not s or type(appId) ~= 'string' or type(permission) ~= 'string' then return false end
    return apps.permissionState(s.device, appId, permission) == 'granted'
end)

---Saves a (virtual) file into a tablet's Documents or Downloads folder.
---target: like Notify. data: { name, folder? ('Downloads'), mime?, sizeBytes?, ref? }
---Uses the database: call it from a thread or an event handler.
---@return boolean ok
---@return string? err
exports('SaveFile', function(target, data)
    if not ready then return false, ERR.internal end
    local valid, problems = validate.schema(data, files.SAVE_SCHEMA, 'SaveFile')
    if not valid then
        log.warn('files', 'rejected SaveFile call', { resource = GetInvokingResource() or RESOURCE, problem = problems[1] })
        return false, ERR.bad_request
    end
    local ok, result, err = pcall(function()
        local recs = targets.resolve(target)
        if #recs == 0 then return false, ERR.no_device end
        local lastErr
        for _, rec in ipairs(recs) do
            local acquired, entry, saveErr = device.withLock(rec, function() return files.saveFor(rec, data) end)
            if not acquired then entry, saveErr = nil, ERR.busy end
            if entry then
                for _, viewer in ipairs(targets.viewers(rec)) do
                    TriggerClientEvent('toxic_ipad:client:filesChanged', viewer, entry)
                end
            else
                lastErr = saveErr
            end
        end
        if lastErr then return false, lastErr end
        return true
    end)
    if not ok then
        log.error('files', 'SaveFile failed', { err = tostring(result) })
        return false, ERR.internal
    end
    return result, err
end)

---Recent photos of a player's tablet(s), newest first (docs/APP_SDK.md §6).
---target: like Notify. limit: 1–50 (default 10).
---Returns { id, url, selfie, location, time, serial }[]. Uses the database:
---call it from a thread or an event handler.
---@return table[]
exports('GetPhotos', function(target, limit)
    if not ready then return {} end
    limit = math.tointeger(limit) or 10
    limit = math.max(1, math.min(50, limit))
    local ok, result = pcall(function()
        local out = {}
        for _, rec in ipairs(targets.resolve(target)) do
            for _, p in ipairs(photos.recentFor(rec, limit)) do out[#out + 1] = p end
        end
        table.sort(out, function(a, b) return a.time > b.time or (a.time == b.time and a.id > b.id) end)
        while #out > limit do out[#out] = nil end
        return out
    end)
    if not ok then
        log.error('photos', 'GetPhotos failed', { err = tostring(result) })
        return {}
    end
    return result
end)

local WIDGET_DATA_MAX = 8192

---Pushes JSON data to a widget on OPEN tablets (docs/APP_SDK.md §5.2).
---Only the resource that registered the widget may update it. The last
---value is kept with the DEVICE (not the player) while it stays in memory
---and is sent again when the tablet opens — to whoever holds it, so do not
---push data meant for one player only to a tablet others may pick up.
---Forgotten when the widget's resource restarts. Never touches the
---database — safe to call often.
---target: player source | { serial = '…' } | { identifier = '…' }
---@return boolean ok
---@return string? err
exports('UpdateWidget', function(target, widgetId, data)
    if not ready then return false, ERR.internal end
    local resource = GetInvokingResource()
    local def = type(widgetId) == 'string' and apps.getWidget(widgetId) or nil
    if not def or def.builtin or def.owner ~= resource then return false, ERR.not_found end
    local okEncode, encoded = pcall(json.encode, data)
    if not okEncode or type(encoded) ~= 'string' or #encoded > WIDGET_DATA_MAX then return false, ERR.bad_request end

    local recs = {}
    if type(target) == 'number' then
        local s = session.get(target)
        if s then recs[1] = s.device end
    elseif type(target) == 'table' and type(target.serial) == 'string' then
        recs[1] = device.cached(target.serial)
    elseif type(target) == 'table' and type(target.identifier) == 'string' then
        local seen = {}
        for _, s in pairs(session.all()) do
            if s.device.owner == target.identifier and not seen[s.device] then
                seen[s.device] = true
                recs[#recs + 1] = s.device
            end
        end
    else
        return false, ERR.bad_request
    end

    for _, rec in ipairs(recs) do
        rec.widgetData = rec.widgetData or {}
        rec.widgetData[widgetId] = { gen = def.gen, data = data }
        for _, viewer in ipairs(targets.viewers(rec)) do
            if apps.widgetVisible(viewer, rec, widgetId) then
                TriggerClientEvent('toxic_ipad:client:widgetData', viewer, { id = widgetId, data = data })
            end
        end
    end
    return true
end)

-- admin ------------------------------------------------------------------

local function registerCommands()
    lib.addCommand('ipadgive', {
        help = locale('cmd_give_help'),
        params = {
            { name = 'target', type = 'playerId', help = locale('cmd_param_target') },
            { name = 'model', type = 'string', optional = true, help = locale('cmd_param_model') },
        },
        restricted = config.server.adminAce,
    }, function(src, args)
        local itemName = args.model or next(config.shared.models)
        if not itemNames[itemName] then
            if src > 0 then notify(src, 'error.no_device') end
            return
        end
        local ok, err = inventory.addItem(args.target, itemName, 1)
        log.info('admin', 'ipadgive', { by = src, target = args.target, item = itemName, ok = ok, err = err })
        if src > 0 then notify(src, ok and 'cmd_give_done' or 'error.internal', ok and 'success' or 'error') end
    end)

    -- Test tool: send a notification to a player's tablet.
    lib.addCommand('ipadnotify', {
        help = locale('cmd_notify_help'),
        params = {
            { name = 'target', type = 'playerId', help = locale('cmd_param_target') },
            { name = 'message', type = 'longString', help = locale('cmd_param_message') },
        },
        restricted = config.server.adminAce,
    }, function(src, args)
        local ok, err = notifications.notify(args.target, {
            app = 'settings', title = locale('app_name'), message = args.message:sub(1, 500), priority = 'normal',
        })
        if src > 0 then notify(src, ok and 'cmd_notify_done' or ('error.' .. (err or 'internal')), ok and 'success' or 'error') end
    end)

    -- Support tool: erase a tablet by serial (a player sold it, or lost access).
    lib.addCommand('ipadwipe', {
        help = locale('cmd_wipe_help'),
        params = {
            { name = 'serial', type = 'string', help = locale('cmd_param_serial') },
            { name = 'owner', type = 'string', optional = true, help = locale('cmd_param_wipe_owner') },
        },
        restricted = config.server.adminAce,
    }, function(src, args)
        local serial = tostring(args.serial):upper()
        local id = serialGen.isValid(serial) and require('server.storage.devices').idOf(serial) or nil
        if not id then
            if src > 0 then notify(src, 'error.not_found') end
            return
        end
        local ok, err = findmy.erase(serial, id, args.owner == 'owner', false)
        log.info('admin', 'ipadwipe', { by = src, serial = serial, removeOwner = args.owner == 'owner', ok = ok, err = err })
        if src > 0 then notify(src, ok and 'cmd_wipe_done' or ('error.' .. (err or 'internal')), ok and 'success' or 'error') end
    end)

    -- Test / support tool: set the battery of the tablet a player has open.
    lib.addCommand('ipadbattery', {
        help = locale('cmd_battery_help'),
        params = {
            { name = 'target', type = 'playerId', help = locale('cmd_param_target') },
            { name = 'percent', type = 'number', help = locale('cmd_param_percent') },
        },
        restricted = config.server.adminAce,
    }, function(src, args)
        local s = session.get(args.target)
        if not s then
            if src > 0 then notify(src, 'error.no_session') end
            return
        end
        local rec = s.device
        device.settleBattery(rec)
        rec.batteryBp = math.floor(math.max(0, math.min(100, args.percent)) * 100)
        rec.batteryStamp = os.time()
        pushDevice(rec)
        log.info('admin', 'ipadbattery', { by = src, target = args.target, serial = s.serial, percent = args.percent })
        if src > 0 then notify(src, 'cmd_battery_done', 'success') end
    end)

    -- Support tool: set or clear the passcode of the tablet a player has
    -- open (a player who forgot it, or testing before the Settings app).
    lib.addCommand('ipadpin', {
        help = locale('cmd_pin_help'),
        params = {
            { name = 'target', type = 'playerId', help = locale('cmd_param_target') },
            { name = 'pin', type = 'string', optional = true, help = locale('cmd_param_pin') },
        },
        restricted = config.server.adminAce,
    }, function(src, args)
        local s = session.get(args.target)
        if not s then
            if src > 0 then notify(src, 'error.no_session') end
            return
        end
        local pin = args.pin
        if pin and not (pin:match('^%d+$') and (#pin == 4 or #pin == 6)) then
            if src > 0 then notify(src, 'error.bad_request') end
            return
        end
        device.setPasscode(s.device, pin)
        log.info('admin', 'ipadpin', { by = src, target = args.target, serial = s.serial, cleared = pin == nil })
        if src > 0 then notify(src, 'cmd_pin_done', 'success') end
    end)
end

-- boot -------------------------------------------------------------------

local CONFIG_SCHEMA = {
    type = 'table',
    strict = false,
    fields = {
        framework = { type = 'string', enum = { 'auto', 'qbox', 'toxic_core' } },
        models = {
            type = 'map', min = 1,
            keys = { type = 'string', pattern = '[%w_]+' },
            values = {
                type = 'table',
                fields = {
                    label = { type = 'string', minLength = 1, maxLength = 48 },
                    chip = { type = 'string', maxLength = 32 },
                    os = { type = 'string', maxLength = 32 },
                    storageGB = { type = 'integer', enum = { 128, 256, 512, 1024, 2048 } },
                    systemGB = { type = 'integer', optional = true, min = 0, max = 64 },
                },
            },
        },
        display = {
            type = 'table', strict = false,
            fields = {
                size = { type = 'number', min = 0.75, max = 0.90 },
                aspect = { type = 'number', min = 1.2, max = 1.5 },
                portrait = { type = 'boolean', optional = true },
            },
        },
        lock = {
            type = 'table',
            fields = {
                passcodeLengths = { type = 'array', min = 1, max = 2, items = { type = 'integer', enum = { 4, 6 } } },
                faceId = { type = 'boolean' },
            },
        },
        battery = {
            type = 'table',
            fields = {
                enabled = { type = 'boolean' },
                drainPerMinuteOpen = { type = 'number', min = 0, max = 10 },
                closedPerHour = { type = 'number', min = -100, max = 100 },
                lowPowerMultiplier = { type = 'number', min = 0, max = 1 },
                lowWarningAt = { type = 'number', min = 0, max = 100 },
                powerBank = {
                    type = 'table', optional = true,
                    fields = {
                        enabled = { type = 'boolean' },
                        item = { type = 'string', minLength = 1, maxLength = 64 },
                        percent = { type = 'number', min = 1, max = 100 },
                        perMinute = { type = 'number', min = 0.1, max = 100 },
                    },
                },
                stations = {
                    type = 'table', optional = true,
                    fields = {
                        enabled = { type = 'boolean' },
                        perMinute = { type = 'number', min = 0.1, max = 100 },
                        radius = { type = 'number', min = 0.5, max = 10 },
                        points = {
                            type = 'array', max = 100,
                            items = {
                                type = 'table',
                                fields = {
                                    coords = { type = 'any', check = function(v)
                                        local t = type(v)
                                        if t == 'vector3' or (t == 'table' and type(v.x) == 'number' and type(v.y) == 'number' and type(v.z) == 'number') then return true end
                                        return false, 'must be vec3(x, y, z)'
                                    end },
                                    label = { type = 'string', optional = true, maxLength = 48 },
                                },
                            },
                        },
                    },
                },
            },
        },
        findMy = {
            type = 'table', optional = true,
            fields = { enabled = { type = 'boolean' }, waypoint = { type = 'boolean' } },
        },
        clock = {
            type = 'table',
            fields = {
                source = { type = 'string', enum = { 'game', 'real' } },
                use24h = { type = 'boolean' },
            },
        },
        accent = { type = 'string', maxLength = 32 },
    },
}

---@param step string
---@param problems string[]
local function abort(step, problems)
    log.error('boot', ('boot aborted at "%s" — toxic_ipad is NOT running. Fix the problems below and restart it.'):format(step))
    for i = 1, #problems do log.error('boot', problems[i]) end
end

---Frameworks may start after toxic_ipad; wait up to 20 s for one.
---@return table? adapter
---@return string? err
local function waitForFramework()
    local selector = require 'bridge.framework.init'
    local adapter, err
    for _ = 1, 40 do
        adapter, err = selector.select(config.shared.framework)
        if adapter then return adapter end
        Wait(500)
    end
    return nil, err
end

CreateThread(function()
    log.init(config.server.logLevel)

    local okConfig, configErrors = validate.schema(config.shared, CONFIG_SCHEMA, 'config/shared.lua')
    if not okConfig then return abort('config', configErrors) end

    for name in pairs(config.shared.models) do itemNames[name] = true end

    local fw, fwErr = waitForFramework()
    if not fw then return abort('framework', { fwErr }) end
    framework = fw

    inventory = require 'bridge.inventory.ox_inventory'
    if not inventory.available() then
        return abort('inventory', { 'ox_inventory is not started. Add "ensure ox_inventory" before "ensure toxic_ipad".' })
    end
    local itemProblems = {}
    for name in pairs(itemNames) do
        for _, problem in ipairs(inventory.checkItem(name)) do itemProblems[#itemProblems + 1] = problem end
    end
    if #itemProblems > 0 then return abort('items', itemProblems) end

    local db = require 'server.storage.mysql'
    local migrate = require 'server.storage.migrate'
    db.ready()
    local okMigrate, report = migrate.run(db, require 'migrations.index', {
        load = function(file) return LoadResourceFile(RESOURCE, 'migrations/' .. file) end,
        modules = {},
        owner = ('%s:%d'):format(RESOURCE, math.random(1, 1 << 30)),
        wait = Wait,
    })
    if not okMigrate then return abort('database migrations', report.errors) end
    if #report.applied > 0 then
        log.info('storage', 'database migrations applied', { versions = table.concat(report.applied, ',') })
    end

    device = require 'server.device'
    session = require 'server.session'
    guard = require 'server.guard'

    notifications = require 'server.notifications'
    notes = require 'server.notes'
    files = require 'server.files'
    targets = require 'server.targets'

    if #appProblems > 0 then return abort('apps', appProblems) end
    apps.bind({ framework = framework, storage = require 'server.storage.apps', device = device, json = json })

    device.init(config, { chargeEnded = function(rec) pushDevice(rec) end })
    session.init(config, function(src, reason)
        TriggerClientEvent('toxic_ipad:client:forceClose', src, reason)
    end)
    guard.init(config, inventory, itemNames)
    targets.init({ session = session, device = device, inventory = inventory, itemNames = itemNames })
    notifications.init({ targets = targets })
    -- configs copied from before 0.5.0 have no photos/uploader blocks
    local photoDefaults = { maxPerDevice = 500, perMinute = 6, perHour = 60, sizeKB = 2400, recordStreet = true }
    config.server.photos = config.server.photos or {}
    for k, v in pairs(photoDefaults) do
        if config.server.photos[k] == nil then config.server.photos[k] = v end
    end
    if not config.server.uploader then
        log.warn('photos', 'config/server.lua has no "uploader" block (added in 0.5.0): Camera is off. Copy it from the new config file.')
        config.server.uploader = { provider = 'none' }
    end

    photos = require 'server.photos'
    local uploaderAdapter, uploaderProblem = require('bridge.uploader.init').select(config.server.uploader)
    photos.init({
        storage = require 'server.storage.photos', uploader = uploaderAdapter, files = files, config = config,
        withLock = function(rec, fn) return device.withLock(rec, fn) end,
    })
    if uploaderAdapter and uploaderAdapter.serverCaptureReady and uploaderAdapter.serverCaptureReady() then
        log.info('photos', 'Camera: server capture through screencapture + Fivemanage')
    end
    files.init(config, {
        notes = notes,
        otherBytes = function(rec)
            local _, bytes = photos.usage(rec)
            return bytes
        end,
    })
    if uploaderProblem then log.warn('photos', uploaderProblem) end
    if not refreshCamera() and uploaderAdapter then
        log.warn('photos', 'Camera is off until screencapture (recommended) or screenshot-basic is started (ensure it before toxic_ipad).')
    end

    power = require 'server.power'
    power.init({ config = config, device = device, session = session, inventory = inventory, itemNames = itemNames, notify = notify, pushDevice = pushDevice })
    findmy = require 'server.findmy'
    findmy.init({
        config = config, device = device, session = session, inventory = inventory, itemNames = itemNames,
        onErase = function(rec, deviceId)
            if rec then power.stopStation(rec, 'erased') end
            photos.forgetDevice(deviceId)
        end,
    })
    apps.setAvailable('findmy', config.shared.findMy == nil or config.shared.findMy.enabled ~= false)
    for _, id in ipairs({ 'camera', 'photos', 'findmy' }) do
        if not apps.exists(id) then
            log.warn('apps', ('config/apps.lua has no "%s" app: copy the new entries from the %s config file'):format(id, GetResourceMetadata(RESOURCE, 'version', 0) or 'current'))
        end
    end
    local pb = device.powerBankCfg()
    if pb.enabled and not inventory.itemExists(pb.item) then
        log.warn('power', ('power bank item "%s" is not defined in ox_inventory: Use Power Bank is off'):format(pb.item))
        config.shared.battery.powerBank.enabled = false
    end

    registerCallbacks()
    registerEvents()
    registerCommands()

    ready = true
    local models = {}
    for name in pairs(itemNames) do models[#models + 1] = name end
    log.info('boot', ('toxic_ipad %s ready'):format(GetResourceMetadata(RESOURCE, 'version', 0) or '?'), {
        framework = framework.name, items = table.concat(models, ','),
    })
    -- App resources that started before us can (re)register on this event.
    TriggerEvent('toxic_ipad:server:ready')
end)

AddEventHandler('onResourceStart', function(resource)
    -- the state may still read 'starting' inside this event
    if (resource == 'screenshot-basic' or resource == 'screencapture') and ready then SetTimeout(1000, refreshCamera) end
end)

-- An app resource stopped: its apps and widgets disappear from every tablet.
AddEventHandler('onResourceStop', function(resource)
    if resource == RESOURCE then return end
    if (resource == 'screenshot-basic' or resource == 'screencapture') and ready then
        -- GetResourceState still says 'stopping' here
        SetTimeout(1000, refreshCamera)
    end
    local removed = apps.unregisterResource(resource)
    if removed > 0 then
        log.info('apps', 'resource stopped; its apps were removed', { resource = resource, count = removed })
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= RESOURCE or not ready then return end
    ready = false
    for _, id in ipairs(hookIds) do pcall(inventory.removeHook, id) end
    session.dropAll()
    device.flushAllNow()
end)
