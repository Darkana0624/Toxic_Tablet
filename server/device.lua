---Device records: load/create, in-memory cache, battery, passcode, flush.
---docs/ARCHITECTURE.md §5, docs/DATABASE.md §5.
---
---A record is shared by every session that opens the same serial (normally
---one). It stays cached `cacheSeconds` after the last close, so reopening a
---tablet costs no queries.

local storage = require 'server.storage.devices'
local settingsDoc = require 'shared.settings'
local battery = require 'shared.battery'
local lockout = require 'shared.lockout'
local log = require 'server.log'

---@class IpadDevice
---@field id integer
---@field serial string
---@field model string
---@field owner string?
---@field capacityMb integer
---@field usedBytes integer
---@field batteryBp integer
---@field batteryStamp integer        unix seconds of batteryBp
---@field batteryState 'open'|'closed'
---@field batteryHealth integer
---@field charging boolean
---@field passcodeHash string?
---@field passcodeLength integer?
---@field failedAttempts integer
---@field lockedUntil integer?
---@field settings table
---@field settingsDirty boolean
---@field flushTimer boolean
---@field openCount integer
---@field expiresAt integer?
---@field expiryTimer boolean?
---@field locked boolean?         a request is working on this device (device.withLock)
---@field charge IpadCharge?       charging now (power bank or station)
---@field lost boolean             Lost Mode (Find My)
---@field lostMessage string?
---@field lastSeen { x: number, y: number, z: number, at: integer }?
---@field erased boolean?          wiped: never write this record again

---@class IpadCharge : BatteryCharge
---@field source 'powerbank'|'station'
---@field station integer?         config index (station)
---@field src integer?             the player standing at the station

local device = {}

---@type table<string, IpadDevice>
local cache = {}

local cfg -- set by device.init

---@type fun(rec: IpadDevice)?
local onChargeEnded

---@param config { shared: table, server: table }
---@param hooks? { chargeEnded: fun(rec: IpadDevice) }
function device.init(config, hooks)
    cfg = config
    onChargeEnded = hooks and hooks.chargeEnded
end

---Power bank settings with defaults (configs from before 0.6.0 have none).
---@return { enabled: boolean, item: string, percent: number, perMinute: number }
function device.powerBankCfg()
    local pb = cfg.shared.battery.powerBank or {}
    return {
        enabled = cfg.shared.battery.enabled and pb.enabled ~= false and pb.item ~= nil,
        item = pb.item,
        percent = pb.percent or 100,
        perMinute = pb.perMinute or 5,
    }
end

local function now()
    return os.time()
end

---@param row table
---@return IpadDevice
local function fromRow(row)
    local stored = nil
    if row.settings then
        local ok, decoded = pcall(json.decode, row.settings)
        if ok then stored = decoded end
    end
    local doc, repaired = settingsDoc.load(stored, cfg.shared.clock.use24h)

    return {
        id = math.tointeger(row.id) or row.id,
        serial = row.serial,
        model = row.model,
        owner = row.owner_identifier,
        capacityMb = math.tointeger(row.storage_capacity_mb) or 0,
        usedBytes = math.tointeger(row.storage_used_bytes) or 0,
        batteryBp = math.tointeger(row.battery_bp) or battery.FULL,
        batteryStamp = math.tointeger(row.battery_stamp) or now(),
        batteryState = 'closed',
        batteryHealth = math.tointeger(row.battery_health) or 100,
        charging = row.charging == 1 or row.charging == true,
        passcodeHash = row.passcode_hash,
        passcodeLength = math.tointeger(row.passcode_length),
        failedAttempts = math.tointeger(row.failed_attempts) or 0,
        lockedUntil = math.tointeger(row.locked_until),
        settings = doc,
        lost = row.lost == 1 or row.lost == true,
        lostMessage = row.lost_message,
        lastSeen = row.last_seen and { x = tonumber(row.last_x) or 0.0, y = tonumber(row.last_y) or 0.0, z = tonumber(row.last_z) or 0.0, at = math.tointeger(row.last_seen) or 0 } or nil,
        charge = cfg.shared.battery.enabled and (math.tointeger(row.charge_bp) or 0) > 0
            and { source = 'powerbank', perMinute = device.powerBankCfg().perMinute, leftBp = math.tointeger(row.charge_bp) }
            or nil,
        settingsDirty = repaired or row.settings == nil,
        flushTimer = false,
        openCount = 0,
        expiresAt = nil,
    }
end

---@param rec IpadDevice
function device.flushSettings(rec)
    if not rec.settingsDirty or rec.erased then return end
    rec.settingsDirty = false
    local ok, err = pcall(storage.saveSettings, rec.id, settingsDoc.VERSION, json.encode(rec.settings))
    if not ok then
        rec.settingsDirty = true
        log.error('device', 'could not save settings', { serial = rec.serial, err = tostring(err) })
    end
end

---Debounced settings write (one timer per device, merged).
---@param rec IpadDevice
function device.markSettingsDirty(rec)
    rec.settingsDirty = true
    if rec.flushTimer then return end
    rec.flushTimer = true
    SetTimeout(cfg.server.settingsFlushMs, function()
        rec.flushTimer = false
        device.flushSettings(rec)
    end)
end

---Brings the battery level up to now for the state it has been in
---(including a charge; a power bank that ran out ends here).
---@param rec IpadDevice
function device.settleBattery(rec)
    local t = now()
    if cfg.shared.battery.enabled then
        local level, left, ended = battery.advanceCharging(rec.batteryBp, t - rec.batteryStamp, rec.batteryState,
            cfg.shared.battery, rec.settings.battery.lowPower, rec.charge)
        rec.batteryBp = level
        if rec.charge then
            rec.charge.leftBp = left
            if ended then
                rec.charge = nil
                rec.chargeDirty = true
                -- after this settle is complete (the hook settles again)
                if onChargeEnded then
                    local hook = onChargeEnded
                    SetTimeout(0, function() hook(rec) end)
                end
            end
        end
    elseif rec.charge then
        rec.charge = nil -- battery simulation off: nothing charges
        rec.chargeDirty = true
    end
    rec.charging = rec.charge ~= nil
    rec.batteryStamp = t
end

---Starts charging (settles the old rate first). Replaces a running charge.
---@param rec IpadDevice
---@param charge IpadCharge?  nil stops charging
function device.setCharge(rec, charge)
    device.settleBattery(rec)
    rec.charge = charge
    rec.charging = charge ~= nil
    rec.chargeDirty = true
end

---Power bank charge still to deliver (what survives a restart).
---@param rec IpadDevice
---@return integer
local function storedCharge(rec)
    return rec.charge and rec.charge.source == 'powerbank' and (rec.charge.leftBp or 0) or 0
end

---@param rec IpadDevice
---@param state 'open'|'closed'
function device.setBatteryState(rec, state)
    device.settleBattery(rec)
    rec.batteryState = state
end

---@param rec IpadDevice
function device.flushState(rec)
    if rec.erased then return end
    device.settleBattery(rec)
    local ok, err = pcall(storage.saveState, rec.id, rec.batteryBp, rec.batteryStamp, rec.charging, rec.usedBytes)
    if ok and (rec.chargeDirty or storedCharge(rec) > 0) then
        rec.chargeDirty = false
        ok, err = pcall(storage.saveCharge, rec.id, storedCharge(rec))
    end
    if not ok then
        log.error('device', 'could not save device state', { serial = rec.serial, err = tostring(err) })
    end
end

---Records where the tablet is (Find My). Never yields.
---@param rec IpadDevice
---@param coords vector3|{ x: number, y: number, z: number }
function device.seen(rec, coords)
    if rec.erased or not coords then return end
    local x, y, z = coords.x + 0.0, coords.y + 0.0, coords.z + 0.0
    if x == 0.0 and y == 0.0 and z == 0.0 then return end -- no ped (dropped player)
    rec.lastSeen = { x = x, y = y, z = z, at = now() }
    storage.seenNow(rec.id, x, y, z)
end

---Serials being erased right now: they cannot be opened or loaded.
---@type table<string, true>
local erasing = {}

---@param serial string
---@param on boolean
function device.setErasing(serial, on)
    erasing[serial] = on or nil
end

---@param serial string
---@return boolean
function device.isErasing(serial)
    return erasing[serial] == true
end

---Drops a record from the cache for good (after an erase): nothing it
---still holds is written back.
---@param rec IpadDevice
function device.evict(rec)
    rec.erased = true
    rec.settingsDirty = false
    if cache[rec.serial] == rec then cache[rec.serial] = nil end
end

---Drops an idle device from the cache after `cacheSeconds` unless it is
---opened (or touched) again in the meantime. One timer per record: a touch
---only moves `expiresAt`, and the timer re-arms itself for the remainder.
---@param rec IpadDevice
local function scheduleExpiry(rec)
    if rec.openCount > 0 then return end
    rec.expiresAt = now() + cfg.server.cacheSeconds
    if rec.expiryTimer then return end
    rec.expiryTimer = true

    local function check()
        if cache[rec.serial] ~= rec or rec.openCount > 0 or not rec.expiresAt then
            rec.expiryTimer = false
            return
        end
        -- a charging tablet stays in memory until the charge ends
        if rec.charge then
            device.settleBattery(rec)
            if rec.charge then
                SetTimeout(60000, check)
                return
            end
            device.flushState(rec)
        end
        local left = rec.expiresAt - now()
        if left > 0 then
            SetTimeout(left * 1000 + 1000, check)
            return
        end
        rec.expiryTimer = false
        device.flushSettings(rec)
        if rec.chargeDirty then device.flushState(rec) end -- a station charge that ended while put away
        cache[rec.serial] = nil
    end
    SetTimeout(cfg.server.cacheSeconds * 1000 + 1000, check)
end

---Runs `fn` while no other request works on the same device. Requests of
---one device are serialised so that checks and writes separated by a
---database wait (quotas, limits, folder moves) cannot be raced.
---Must run in a coroutine.
---@param rec IpadDevice
---@param fn fun(): any, any
---@param timeoutMs? integer default 5000
---@return boolean acquired
---@return any result
---@return any result2
function device.withLock(rec, fn, timeoutMs)
    local deadline = GetGameTimer() + (timeoutMs or 5000)
    while rec.locked do
        if GetGameTimer() > deadline then return false end
        Wait(0)
    end
    rec.locked = true
    local ok, a, b = pcall(fn)
    rec.locked = false
    if not ok then error(a, 0) end
    return true, a, b
end

---Loads (or creates) the device for a serial. Must run in a coroutine.
---@param serial string
---@param itemName string?   the model key (required to create)
---@param owner string?      identifier of the first user, used only on creation
---@param mustExist? boolean never create (e.g. a Notify by serial)
---@return IpadDevice?
function device.resolve(serial, itemName, owner, mustExist)
    if erasing[serial] then return nil end
    local rec = cache[serial]
    if rec then
        scheduleExpiry(rec)
        return rec
    end

    local row = storage.find(serial)
    if not row then
        if mustExist or not itemName or not cfg.shared.models[itemName] then return nil end
        local model = cfg.shared.models[itemName]
        row = storage.create(serial, itemName, owner, model.storageGB * 1024)
        if not row then return nil end
        log.info('device', 'new device registered', { serial = serial, model = itemName })
    end

    -- another coroutine may have loaded it while we waited on SQL
    if cache[serial] then return cache[serial] end
    if erasing[serial] then return nil end -- an erase started meanwhile

    rec = fromRow(row)
    if not rec.owner and owner then
        if storage.claimOwner(rec.id, owner) then rec.owner = owner end
        -- claimOwner waited on SQL: another coroutine may have cached it
        if cache[serial] then return cache[serial] end
    end
    cache[serial] = rec
    scheduleExpiry(rec)
    return rec
end

---Every device owned by a character (for Notify { identifier = ... }).
---@param identifier string
---@return IpadDevice[]
function device.byOwner(identifier)
    local out = {}
    for _, serial in ipairs(storage.serialsByOwner(identifier)) do
        local rec = device.resolve(serial, nil, nil, true)
        if rec then out[#out + 1] = rec end
    end
    return out
end

---@param serial string
---@return IpadDevice?
function device.cached(serial)
    return cache[serial]
end

---A session opened this device.
---@param rec IpadDevice
function device.retain(rec)
    rec.openCount = rec.openCount + 1
    rec.expiresAt = nil
    device.setBatteryState(rec, 'open')
end

---A session closed this device: write everything, keep it cached a while.
---@param rec IpadDevice
function device.release(rec)
    rec.openCount = math.max(0, rec.openCount - 1)
    if rec.openCount > 0 then return end

    device.setBatteryState(rec, 'closed')
    device.flushSettings(rec)
    device.flushState(rec)
    rec.notes = nil -- the notes cache lives only while the tablet is open
    scheduleExpiry(rec)
end

---Writes every cached device on resource stop, without yielding (a
---yielding query inside onResourceStop may never resume).
function device.flushAllNow()
    for _, rec in pairs(cache) do
        onChargeEnded = nil -- no events while stopping
        device.settleBattery(rec)
        if rec.openCount > 0 then rec.batteryState = 'closed' end
        if rec.settingsDirty then
            rec.settingsDirty = false
            storage.saveSettingsNow(rec.id, settingsDoc.VERSION, json.encode(rec.settings))
        end
        if not rec.erased then
            storage.saveStateNow(rec.id, rec.batteryBp, rec.batteryStamp, rec.charging, rec.usedBytes)
            if rec.chargeDirty or storedCharge(rec) > 0 then storage.saveChargeNow(rec.id, storedCharge(rec)) end
        end
    end
end

-- passcode ---------------------------------------------------------------

---@param rec IpadDevice
---@return integer seconds remaining lockout
function device.lockoutRemaining(rec)
    return lockout.remaining(rec.lockedUntil, now())
end

---Checks a PIN and applies the lockout policy. Must run in a coroutine
---(VerifyPasswordHash is a blocking native, but storage writes yield).
---@param rec IpadDevice
---@param pin string
---@return boolean ok
---@return integer? lockoutSeconds  set when the device is now locked out
function device.checkPasscode(rec, pin)
    if not rec.passcodeHash then return false end

    if VerifyPasswordHash(pin, rec.passcodeHash) then
        if rec.failedAttempts ~= 0 or rec.lockedUntil then
            rec.failedAttempts, rec.lockedUntil = 0, nil
            storage.saveAttempts(rec.id, 0, 0)
        end
        return true
    end

    rec.failedAttempts = rec.failedAttempts + 1
    local seconds = lockout.seconds(rec.failedAttempts, cfg.server.lockout.maxAttempts, cfg.server.lockout.steps)
    rec.lockedUntil = seconds > 0 and (now() + seconds) or nil
    storage.saveAttempts(rec.id, rec.failedAttempts, rec.lockedUntil or 0)
    return false, seconds > 0 and seconds or nil
end

---@param rec IpadDevice
---@param pin string?  nil removes the passcode
function device.setPasscode(rec, pin)
    if pin then
        rec.passcodeHash = GetPasswordHash(pin)
        rec.passcodeLength = #pin
    else
        rec.passcodeHash, rec.passcodeLength = nil, nil
    end
    rec.failedAttempts, rec.lockedUntil = 0, nil
    storage.savePasscode(rec.id, rec.passcodeHash, rec.passcodeLength)
end

-- payloads ---------------------------------------------------------------

---What the NUI may know about a device. Never includes the hash.
---@param rec IpadDevice
---@param isOwner boolean
---@return table
function device.summary(rec, isOwner)
    local model = cfg.shared.models[rec.model] or {}
    return {
        serial = rec.serial,
        name = model.label or rec.model,
        chip = model.chip,
        os = model.os,
        storageGB = math.floor(rec.capacityMb / 1024),
        usedBytes = rec.usedBytes,
        battery = battery.percent(rec.batteryBp),
        batteryHealth = rec.batteryHealth,
        charging = rec.charge ~= nil,
        charge = rec.charge and {
            source = rec.charge.source,
            perMinute = rec.charge.perMinute,
            leftPercent = rec.charge.leftBp and battery.percent(rec.charge.leftBp) or nil,
        } or nil,
        lost = isOwner and rec.lost or nil,
        isOwner = isOwner,
        hasPasscode = rec.passcodeHash ~= nil,
        passcodeLength = rec.passcodeLength,
        lockout = device.lockoutRemaining(rec),
    }
end

return device
