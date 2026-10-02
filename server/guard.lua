---The single entry point for client requests (docs/SECURITY.md §3).
---Every callback goes through, in order: rate limit → session → the slot
---still holds the serial → lock state → schema → per-device lock → handler.
---The handler receives the session; the device id is never taken from the
---client payload.

local constants = require 'shared.constants'
local validate = require 'shared.validate'
local ratelimit = require 'shared.ratelimit'
local session = require 'server.session'
local device = require 'server.device'
local log = require 'server.log'

local ERR = constants.ERR

local guard = {}

local limiter = ratelimit.new(function() return GetGameTimer() / 1000 end)
local cfg, inventory, itemNames

---@param config table
---@param inventoryAdapter table
---@param items table<string, true>
function guard.init(config, inventoryAdapter, items)
    cfg = config
    inventory = inventoryAdapter
    itemNames = items
end

---@param src integer
---@param bucket string
---@return boolean
function guard.rate(src, bucket)
    local perMinute = cfg.server.rateLimits[bucket] or cfg.server.rateLimits.default
    local ok, over = limiter:take(('%d:%s'):format(src, bucket), perMinute)
    if not ok and over == perMinute * 5 then
        log.security('guard', 'player is flooding a tablet endpoint', { src = src, bucket = bucket, perMinute = perMinute })
    end
    return ok
end

---@param src integer
function guard.forget(src)
    limiter:forget(('%d:'):format(src))
end

---Confirms the session's slot still holds its tablet; follows the item if
---the player only moved it inside their inventory.
---@param s IpadSession
---@return boolean
function guard.holding(s)
    if inventory.slotHoldsSerial(s.src, s.slot, s.serial, itemNames) then return true end
    local slot = inventory.findSerial(s.src, s.serial, itemNames)
    if slot then
        s.slot = slot
        return true
    end
    return false
end

---@class GuardOptions
---@field schema table        payload schema (validate.schema)
---@field unlocked? boolean   default true: requires an unlocked session
---@field lock? boolean       default true: runs under the per-device lock. false only for
---                           handlers that wait on something slow (HTTP) and keep their
---                           own state consistent without it

---Registers `toxic_ipad:server:<name>`. `name` must be listed in
---constants.CALLBACKS, which is the whole client-reachable surface.
---@param name string
---@param opts GuardOptions
---@param handler fun(s: IpadSession, payload: any): table
function guard.register(name, opts, handler)
    local bucket = constants.CALLBACKS[name]
    assert(bucket, ('guard.register: "%s" is not listed in constants.CALLBACKS'):format(name))

    lib.callback.register(('toxic_ipad:server:%s'):format(name), function(src, payload)
        if not guard.rate(src, bucket) then return { ok = false, err = ERR.rate_limited } end

        local s = session.get(src)
        if not s then return { ok = false, err = ERR.no_session } end

        if not guard.holding(s) then
            session.close(src, 'device_gone', true)
            return { ok = false, err = ERR.device_gone }
        end

        if opts.unlocked ~= false and not s.unlocked then
            return { ok = false, err = ERR.locked }
        end

        local valid, errors = validate.schema(payload, opts.schema, name)
        if not valid then
            log.debug('guard', 'rejected payload', { src = src, name = name, problem = errors[1] })
            return { ok = false, err = ERR.bad_request }
        end

        if opts.lock == false then
            local ok, result = pcall(handler, s, payload)
            if not ok then
                log.error('guard', 'handler error', { name = name, src = src, err = tostring(result) })
                return { ok = false, err = ERR.internal }
            end
            return result
        end

        -- one request per device at a time (device.withLock)
        local ok, acquired, result = pcall(device.withLock, s.device, function()
            -- the tablet was erased while this request waited for the lock
            if s.device.erased then return { ok = false, err = ERR.no_session } end
            return handler(s, payload)
        end)
        if not ok then
            log.error('guard', 'handler error', { name = name, src = src, err = tostring(acquired) })
            return { ok = false, err = ERR.internal }
        end
        if not acquired then return { ok = false, err = ERR.busy } end
        return result
    end)
end

return guard
