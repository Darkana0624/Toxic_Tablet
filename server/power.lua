---Charging (docs/PHASE2.md §3.1): power banks and charging stations.
---
---Power bank: an EXISTING inventory item that another resource (a phone)
---may also use. The tablet never registers the item's use; it only removes
---one when the player chooses "Use Power Bank" (or accepts the prompt on an
---empty tablet) and then charges gradually — the level is computed from the
---charge rate, nothing ticks. The charge still to deliver survives a restart.
---
---Stations: ox_target spots from config. Charging runs while the player
---stays within reach and keeps the tablet; one watcher thread (5 s) exists
---only while at least one tablet charges at a station.

local log = require 'server.log'

local power = {}

local cfg, device, session, inventory, itemNames, notify, pushDevice

---@type table<table, true> device records charging at a station
local stationCharges = {}
local watching = false

---@param deps table
function power.init(deps)
    cfg, device, session, inventory, itemNames = deps.config, deps.device, deps.session, deps.inventory, deps.itemNames
    notify, pushDevice = deps.notify, deps.pushDevice
end

---@return table?
local function stationsCfg()
    local st = cfg.shared.battery.stations
    if not cfg.shared.battery.enabled or not st or not st.enabled or type(st.points) ~= 'table' then return nil end
    return st
end

---@param rec table
---@return boolean
local function isFull(rec)
    return rec.batteryBp >= 9950
end

-- power bank ----------------------------------------------------------------

---Removes one power bank and starts charging `rec`. The caller holds the
---device lock (or the record is not open anywhere yet).
---@param rec table
---@param src integer
---@return boolean ok
---@return string? err
function power.startPowerBank(rec, src)
    local pb = device.powerBankCfg()
    if not pb.enabled then return false, 'bad_request' end
    device.settleBattery(rec)
    if rec.charge then return false, 'already_charging' end
    if isFull(rec) then return false, 'battery_full' end
    if inventory.count(src, pb.item) < 1 or not inventory.removeItem(src, pb.item, 1) then
        return false, 'no_powerbank'
    end
    device.setCharge(rec, { source = 'powerbank', perMinute = pb.perMinute, leftBp = math.floor(pb.percent * 100) })
    device.flushState(rec) -- the item is gone: persist the charge at once
    log.info('power', 'power bank used', { src = src, serial = rec.serial })
    return true
end

---Settings › Battery: what the player can do.
---@param s table IpadSession
---@return table
function power.info(s)
    local pb = device.powerBankCfg()
    device.settleBattery(s.device)
    return {
        ok = true,
        device = device.summary(s.device, s.isOwner),
        powerBank = pb.enabled and { count = inventory.count(s.src, pb.item), percent = pb.percent, perMinute = pb.perMinute } or nil,
        stations = stationsCfg() ~= nil,
    }
end

---@param s table
---@return table
function power.usePowerBank(s)
    local ok, err = power.startPowerBank(s.device, s.src)
    if not ok then return { ok = false, err = err } end
    pushDevice(s.device)
    return { ok = true, device = device.summary(s.device, s.isOwner), count = inventory.count(s.src, device.powerBankCfg().item) }
end

-- stations ------------------------------------------------------------------

---@param coords any vec3 or { x, y, z }
---@return vector3
local function vec(coords)
    return vector3(coords.x + 0.0, coords.y + 0.0, coords.z + 0.0)
end

---@param rec table
---@param reason 'user'|'left'|'dropped'|'full'
function power.stopStation(rec, reason)
    local c = rec.charge
    stationCharges[rec] = nil
    if not c or c.source ~= 'station' then return end
    device.setCharge(rec, nil)
    if reason ~= 'dropped' and reason ~= 'erased' then notify(c.src, reason == 'user' and 'station_stopped' or 'station_left', 'inform') end
    if rec.openCount == 0 and not rec.erased then device.flushState(rec) end -- keep what it gained
    pushDevice(rec)
end

local function watch()
    if watching then return end
    watching = true
    CreateThread(function()
        while next(stationCharges) do
            Wait(5000)
            local st = stationsCfg()
            for rec in pairs(stationCharges) do
                local c = rec.charge
                if not c or c.source ~= 'station' then
                    stationCharges[rec] = nil
                elseif not st or not GetPlayerName(c.src) then
                    power.stopStation(rec, 'dropped')
                else
                    local point = st.points[c.station]
                    local pos = session.coordsOf(c.src)
                    if not point or not pos or #(pos - vec(point.coords)) > st.radius + 3.0
                        or not inventory.findSerial(c.src, rec.serial, itemNames) then
                        power.stopStation(rec, 'left')
                    end
                end
            end
        end
        watching = false
    end)
end

---ox_target "Charge Tablet" at station `index` (toggles).
---@param src integer
---@param index any
function power.station(src, index)
    local st = stationsCfg()
    local point = st and math.tointeger(index) and st.points[index]
    if not point then return end
    local pos = session.coordsOf(src)
    if not pos or #(pos - vec(point.coords)) > st.radius + 3.0 then return notify(src, 'station_far') end

    -- the tablet in hand, else the first one carried
    local rec
    local s = session.get(src)
    if s then
        rec = s.device
    else
        local carried = inventory.findDevices(src, itemNames)
        local first = carried[1]
        if not first or type(first.metadata.serial) ~= 'string' then return notify(src, 'error.no_device') end
        rec = device.resolve(first.metadata.serial, first.name, nil, true)
        if not rec then return notify(src, 'error.no_device') end
    end

    device.settleBattery(rec)
    local c = rec.charge
    if c and c.source == 'station' then
        if c.src == src then power.stopStation(rec, 'user') end
        return
    end
    if c then return notify(src, 'error.already_charging') end
    if isFull(rec) then return notify(src, 'error.battery_full', 'inform') end

    device.setCharge(rec, { source = 'station', perMinute = st.perMinute or 3, station = index, src = src })
    stationCharges[rec] = true
    watch()
    pushDevice(rec)
    notify(src, 'station_started', 'success')
end

---A player left: stop the station charges they were standing at.
---@param src integer
function power.forget(src)
    for rec in pairs(stationCharges) do
        if rec.charge and rec.charge.src == src then power.stopStation(rec, 'dropped') end
    end
end

return power
