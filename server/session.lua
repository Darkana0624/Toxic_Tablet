---Open sessions: which player holds which device, in which slot, and whether
---they unlocked it. A session is created ONLY by the item-use path
---(docs/ARCHITECTURE.md §4.1); every client request is resolved through it.

local device = require 'server.device'
local battery = require 'shared.battery'
local log = require 'server.log'

---@class IpadSession
---@field src integer
---@field serial string
---@field slot integer
---@field itemName string
---@field device IpadDevice
---@field identifier string?
---@field isOwner boolean
---@field unlocked boolean
---@field openedAt integer
---@field token integer          changes on every open; guards stale timers
---@field shutdownGen integer?   latest battery shutdown schedule

local session = {}

---@type table<integer, IpadSession>
local sessions = {}
local nextToken = 0
local cfg

---@type fun(src: integer, reason: string)?
local onForcedClose

---@param config table
---@param forcedClose fun(src: integer, reason: string)  tells the client to close
function session.init(config, forcedClose)
    cfg = config
    onForcedClose = forcedClose
end

---@param src integer
---@return IpadSession?
function session.get(src)
    return sessions[src]
end

---@return table<integer, IpadSession>
function session.all()
    return sessions
end

---Schedules the one-shot "battery empty" shutdown for this session.
---@param s IpadSession
function session.scheduleShutdown(s)
    if not cfg.shared.battery.enabled then return end
    local rec = s.device
    device.settleBattery(rec)
    -- a newer schedule (settings or a charge changed the rate) replaces this one
    s.shutdownGen = (s.shutdownGen or 0) + 1

    if rec.charge then
        -- no drain while charging; look again when a power bank runs out
        -- (a station charge is stopped explicitly, which reschedules)
        local untilEnd = battery.secondsUntilChargeEnds(rec.batteryBp, rec.charge)
        if not untilEnd then return end
        local token, gen = s.token, s.shutdownGen
        SetTimeout(math.floor(untilEnd * 1000) + 500, function()
            local current = sessions[s.src]
            if current ~= s or current.token ~= token or s.shutdownGen ~= gen then return end
            session.scheduleShutdown(s)
        end)
        return
    end

    local seconds = battery.secondsUntilEmpty(rec.batteryBp, cfg.shared.battery, rec.settings.battery.lowPower)
    if not seconds then return end
    local token, gen = s.token, s.shutdownGen
    SetTimeout(math.floor(seconds * 1000) + 500, function()
        local current = sessions[s.src]
        if current ~= s or current.token ~= token or s.shutdownGen ~= gen then return end
        device.settleBattery(rec)
        if rec.batteryBp <= 0 then
            session.close(s.src, 'battery_empty', true)
        else
            session.scheduleShutdown(s) -- settings changed the rate meanwhile
        end
    end)
end

---Where a player stands (OneSync), for Find My. nil when no ped.
---@param src integer
---@return vector3?
local function coordsOf(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    return GetEntityCoords(ped)
end
session.coordsOf = coordsOf

---@param src integer
---@param data { serial: string, slot: integer, itemName: string, device: IpadDevice, identifier: string? }
---@return IpadSession
function session.open(src, data)
    nextToken = nextToken + 1
    local s = {
        src = src,
        serial = data.serial,
        slot = data.slot,
        itemName = data.itemName,
        device = data.device,
        identifier = data.identifier,
        isOwner = data.identifier ~= nil and data.device.owner == data.identifier,
        unlocked = false,
        openedAt = os.time(),
        token = nextToken,
    }
    sessions[src] = s
    device.retain(s.device)
    device.seen(s.device, coordsOf(src))
    session.scheduleShutdown(s)
    log.debug('session', 'opened', { src = src, serial = s.serial, slot = s.slot, owner = s.isOwner })
    return s
end

---Ends a session. `notifyClient` is true when the server decided to close
---(item gone, battery empty, player unloaded) and the client must animate out.
---@param src integer
---@param reason string
---@param notifyClient? boolean
function session.close(src, reason, notifyClient)
    local s = sessions[src]
    if not s then return end
    sessions[src] = nil
    s.token = -1
    device.seen(s.device, coordsOf(src))
    device.release(s.device)
    log.debug('session', 'closed', { src = src, serial = s.serial, reason = reason })
    if notifyClient and onForcedClose then onForcedClose(src, reason) end
end

---Forgets every session on resource stop. Devices are written by
---device.flushAllNow(); clients clean up in their own onResourceStop.
function session.dropAll()
    for src, s in pairs(sessions) do
        s.token = -1
        sessions[src] = nil
    end
end

return session
