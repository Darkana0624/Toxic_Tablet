---Find My and erasing (docs/PHASE2.md §3.2).
---
---Everything is keyed by the owner identifier of the SESSION (server
---side): a player only ever sees and controls tablets their character owns.
---Where a tablet is:
---  with_you — in the requester's inventory
---  online   — open right now by someone (their position)
---  last     — where it was last opened or put away
---Street names are resolved by the viewer's client from the coordinates.

local battery = require 'shared.battery'
local storage = require 'server.storage.devices'
local log = require 'server.log'

local findmy = {}

findmy.MAX_MESSAGE = 120

local cfg, device, session, inventory, itemNames, onErase

---@param deps table
function findmy.init(deps)
    cfg, device, session, inventory, itemNames = deps.config, deps.device, deps.session, deps.inventory, deps.itemNames
    onErase = deps.onErase -- (rec?, deviceId): stop station charges, drop photo tickets
end

---@param value any
---@return string?
function findmy.cleanMessage(value)
    if type(value) ~= 'string' or not utf8.len(value) then return nil end
    value = value:gsub('%c', ' '):gsub('%s%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if value == '' then return nil end
    if utf8.len(value) > findmy.MAX_MESSAGE then
        value = value:sub(1, utf8.offset(value, findmy.MAX_MESSAGE + 1) - 1)
    end
    return value
end

---@param v vector3?
---@return table?
local function point(v)
    if not v then return nil end
    return { x = math.floor(v.x * 10) / 10, y = math.floor(v.y * 10) / 10, z = math.floor(v.z * 10) / 10 }
end

---Every session that has this device id open.
---@param deviceId integer
---@return table[]
local function sessionsOf(deviceId)
    local out = {}
    for _, s in pairs(session.all()) do
        if s.device.id == deviceId then out[#out + 1] = s end
    end
    return out
end

-- callbacks ---------------------------------------------------------------------

---@param s table IpadSession
---@return table
function findmy.list(s)
    if not s.identifier then return { ok = true, devices = {} } end
    local carried = {}
    for _, item in ipairs(inventory.findDevices(s.src, itemNames)) do
        if item.metadata.serial then carried[item.metadata.serial] = true end
    end

    local out, now = {}, os.time()
    for _, row in ipairs(storage.owned(s.identifier)) do
        local id = math.tointeger(tonumber(row.id))
        local rec = device.cached(row.serial)
        local level, charging, lost, message, seen
        if rec then
            device.settleBattery(rec)
            level, charging, lost, message, seen = rec.batteryBp, rec.charge ~= nil, rec.lost, rec.lostMessage, rec.lastSeen
        else
            local bp = math.tointeger(tonumber(row.battery_bp)) or 0
            local stamp = math.tointeger(tonumber(row.battery_stamp)) or now
            local chargeBp = math.tointeger(tonumber(row.charge_bp)) or 0
            local charge = chargeBp > 0 and { perMinute = device.powerBankCfg().perMinute, leftBp = chargeBp } or nil
            local ended
            if cfg.shared.battery.enabled then
                local _
                level, _, ended = battery.advanceCharging(bp, now - stamp, 'closed', cfg.shared.battery, false, charge)
            else
                level = bp
            end
            charging = charge ~= nil and not ended and cfg.shared.battery.enabled
            lost = row.lost == 1 or row.lost == true
            message = row.lost_message
            seen = row.last_seen and { x = tonumber(row.last_x), y = tonumber(row.last_y), z = tonumber(row.last_z), at = math.tointeger(row.last_seen) } or nil
        end

        local where
        local holders = sessionsOf(id)
        if carried[row.serial] then
            where = { kind = 'with_you', coords = point(session.coordsOf(s.src)), at = now }
        elseif holders[1] and session.coordsOf(holders[1].src) then
            where = { kind = 'online', coords = point(session.coordsOf(holders[1].src)), at = now }
        elseif seen and seen.x then
            where = { kind = 'last', coords = point(vector3(seen.x, seen.y, seen.z)), at = seen.at }
        else
            where = { kind = 'unknown' }
        end

        local model = cfg.shared.models[row.model] or {}
        out[#out + 1] = {
            serial = row.serial,
            name = model.label or row.model,
            isThis = id == s.device.id,
            battery = battery.percent(level),
            charging = charging,
            lost = lost,
            lostMessage = lost and message or nil,
            where = where,
        }
    end
    return { ok = true, devices = out, waypoint = cfg.shared.findMy == nil or cfg.shared.findMy.waypoint ~= false }
end

---@param s table
---@param payload { serial: string, lost: boolean, message: string? }
---@return table
function findmy.setLost(s, payload)
    if not s.identifier then return { ok = false, err = 'not_owner' } end
    local id = storage.ownedId(payload.serial, s.identifier)
    if not id then return { ok = false, err = 'not_found' } end
    local message = payload.lost and findmy.cleanMessage(payload.message) or nil
    storage.saveLost(id, payload.lost, message)

    local rec = device.cached(payload.serial)
    if rec then
        rec.lost, rec.lostMessage = payload.lost, message
        if payload.lost then
            -- whoever else holds it right now is locked out at once
            for _, other in ipairs(sessionsOf(id)) do
                if not other.isOwner then session.close(other.src, 'device_lost', true) end
            end
        end
    end
    log.info('findmy', payload.lost and 'lost mode on' or 'lost mode off', { serial = payload.serial, by = s.src })
    return { ok = true }
end

---Wipes a tablet's content (notes, files, photos, app data and installs,
---notifications, settings, passcode). Sessions of it are closed first.
---@param serial string
---@param deviceId integer
---@param removeOwner boolean
---@param lockHeld boolean the caller already holds this record's lock
---@return boolean ok
---@return string? err
function findmy.erase(serial, deviceId, removeOwner, lockHeld)
    if device.isErasing(serial) then return false, 'busy' end
    local rec = device.cached(serial)
    local function run()
        -- nobody can open or load this serial until the erase is done
        device.setErasing(serial, true)
        local ok, committed = pcall(function()
            if rec then
                for _, s in ipairs(sessionsOf(deviceId)) do session.close(s.src, 'erased', true) end
                device.flushState(rec) -- keep the battery level
            end
            if onErase then onErase(rec, deviceId) end
            local done = storage.erase(deviceId, removeOwner)
            if rec then device.evict(rec) end
            -- a copy loaded while we waited (should not happen: resolve refuses)
            local late = device.cached(serial)
            if late then
                for _, s in ipairs(sessionsOf(deviceId)) do session.close(s.src, 'erased', true) end
                device.evict(late)
            end
            return done
        end)
        device.setErasing(serial, false)
        if not ok then error(committed, 0) end
        return committed
    end

    local committed
    if rec and not lockHeld then
        local acquired, result = device.withLock(rec, run)
        if not acquired then return false, 'busy' end
        committed = result
    else
        committed = run()
    end
    if not committed then return false, 'internal' end
    log.info('findmy', 'tablet erased', { serial = serial, removeOwner = removeOwner })
    return true
end

---Find My › Erase This Tablet.
---@param s table
---@param payload { serial: string }
---@return table
function findmy.eraseRemote(s, payload)
    if not s.identifier then return { ok = false, err = 'not_owner' } end
    local id = storage.ownedId(payload.serial, s.identifier)
    if not id then return { ok = false, err = 'not_found' } end
    local ok, err = findmy.erase(payload.serial, id, false, id == s.device.id)
    if not ok then return { ok = false, err = err } end
    return { ok = true, self = id == s.device.id }
end

---Settings › General › Transfer or Reset.
---@param s table
---@param payload { removeOwner: boolean, pin: string? }
---@return table
function findmy.eraseSelf(s, payload)
    local rec = s.device
    if not s.isOwner then return { ok = false, err = 'not_owner' } end
    if rec.passcodeHash then
        local remaining = device.lockoutRemaining(rec)
        if remaining > 0 then return { ok = false, err = 'lockout', seconds = remaining } end
        if type(payload.pin) ~= 'string' then return { ok = false, err = 'wrong_passcode' } end
        local ok, lockSeconds = device.checkPasscode(rec, payload.pin)
        if not ok then return { ok = false, err = lockSeconds and 'lockout' or 'wrong_passcode', seconds = lockSeconds } end
    end
    local ok, err = findmy.erase(rec.serial, rec.id, payload.removeOwner == true, true)
    if not ok then return { ok = false, err = err } end
    return { ok = true }
end

return findmy
