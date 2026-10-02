---Simulated battery with no ticking: the level is stored with a timestamp
---and recomputed only when something happens (open, close, a setting that
---changes the drain rate). docs/PERFORMANCE.md §4.
---
---Levels are basis points: 10000 = 100.00 %.

local battery = {}

battery.FULL = 10000

---@class BatteryRates
---@field drainPerMinuteOpen number   percent per minute with the screen on
---@field closedPerHour number         percent per hour while put away: positive charges
---                                   (the player charges it off-screen), negative drains
---@field lowPowerMultiplier number   0..1

---@param value number
---@return integer
local function clampBp(value)
    if value ~= value then return 0 end
    if value < 0 then return 0 end
    if value > battery.FULL then return battery.FULL end
    return math.floor(value + 0.5)
end

---Level after `seconds` in a given state.
---@param levelBp integer   level at the start of the period
---@param seconds number     elapsed real seconds (negative is treated as 0)
---@param state 'open'|'closed'
---@param rates BatteryRates
---@param lowPower? boolean
---@return integer levelBp
function battery.advance(levelBp, seconds, state, rates, lowPower)
    if not seconds or seconds <= 0 then return clampBp(levelBp) end

    if state ~= 'open' then
        return clampBp(levelBp + rates.closedPerHour * (seconds / 3600) * 100)
    end

    local percent = rates.drainPerMinuteOpen * (seconds / 60)
    if lowPower then
        percent = percent * rates.lowPowerMultiplier
    end

    return clampBp(levelBp - percent * 100)
end

---Seconds until the level reaches 0 in the open state (for the one-shot
---shutdown timer). Returns nil when the level cannot drain.
---@param levelBp integer
---@param rates BatteryRates
---@param lowPower? boolean
---@return number?
function battery.secondsUntilEmpty(levelBp, rates, lowPower)
    local perMinute = rates.drainPerMinuteOpen * (lowPower and rates.lowPowerMultiplier or 1)
    if perMinute <= 0 then return nil end
    return (levelBp / 100) / perMinute * 60
end

---@class BatteryCharge
---@field perMinute number   percent per minute while charging
---@field leftBp integer?    power bank charge still to deliver; nil = unlimited (charging station)

---Level after `seconds` while charging. A power bank charge ends when its
---budget is used up or the battery is full (the rest of the period then
---runs in `state`); a station charge never ends by itself and holds 100 %.
---@param levelBp integer
---@param seconds number
---@param state 'open'|'closed'
---@param rates BatteryRates
---@param lowPower? boolean
---@param charge BatteryCharge?
---@return integer levelBp
---@return integer? leftBp  budget left (nil for a station)
---@return boolean ended    the charge finished inside this period
function battery.advanceCharging(levelBp, seconds, state, rates, lowPower, charge)
    if not charge then return battery.advance(levelBp, seconds, state, rates, lowPower), nil, false end
    if not seconds or seconds <= 0 then return clampBp(levelBp), charge.leftBp, false end
    local perSecond = (charge.perMinute or 0) * 100 / 60
    local room = math.max(0, battery.FULL - levelBp)

    if charge.leftBp == nil then
        if perSecond <= 0 then return clampBp(levelBp), nil, false end
        return clampBp(levelBp + math.min(room, perSecond * seconds)), nil, false
    end

    local deliverable = math.min(charge.leftBp, room)
    if perSecond <= 0 or deliverable <= 0 then
        return battery.advance(levelBp, seconds, state, rates, lowPower), charge.leftBp, true
    end
    local untilEnd = deliverable / perSecond
    if seconds < untilEnd then
        local added = math.floor(perSecond * seconds)
        return clampBp(levelBp + added), charge.leftBp - added, false
    end
    local level = levelBp + deliverable
    return battery.advance(level, seconds - untilEnd, state, rates, lowPower), charge.leftBp - deliverable, true
end

---Seconds until a power bank charge ends (nil for a station charge).
---@param levelBp integer
---@param charge BatteryCharge
---@return number?
function battery.secondsUntilChargeEnds(levelBp, charge)
    if charge.leftBp == nil then return nil end
    local perSecond = (charge.perMinute or 0) * 100 / 60
    if perSecond <= 0 then return 0 end
    return math.min(charge.leftBp, math.max(0, battery.FULL - levelBp)) / perSecond
end

---@param levelBp integer
---@return number percent with one decimal
function battery.percent(levelBp)
    return math.floor(levelBp / 10 + 0.5) / 10
end

return battery
