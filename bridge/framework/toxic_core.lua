---Framework adapter: Toxic Core. Server side.
---Written against the Toxic Core API v1 contract (Toxic Framework
---docs/03-architecture-spec-v1.md §6: flat exports `<Namespace>_<function>`).
---It is selected only when toxic_core reports apiVersion 1, so it stays
---dormant until those exports ship.

local core = { name = 'toxic_core', resource = 'toxic_core' }

local API_VERSION = 1

---@return boolean
function core.available()
    if GetResourceState('toxic_core') ~= 'started' then return false end
    local ok, version = pcall(function() return exports.toxic_core:Core_apiVersion() end)
    return ok and version == API_VERSION
end

---Stable character id: the public id (spec §2, decision N1).
---@param src integer
---@return string?
function core.getIdentifier(src)
    local info = exports.toxic_core:Character_get(src)
    return info and info.publicId or nil
end

---@param src integer
---@return { first: string, last: string }?
function core.getName(src)
    local name = exports.toxic_core:Character_getName(src)
    if not name then return nil end
    return { first = name.first, last = name.last }
end

---@param src integer
---@return boolean
function core.isLoaded(src)
    return exports.toxic_core:Session_isLoaded(src) == true
end

---Toxic group queries (spec §8.3) accept a string; tables are mapped to
---"any of" by checking each entry.
---@param src integer
---@param filter string|string[]|table<string, integer>
---@return boolean
function core.hasGroup(src, filter)
    if type(filter) == 'string' then
        return exports.toxic_core:Groups_has(src, filter) == true
    end
    for key, value in pairs(filter) do
        local query = type(key) == 'number' and value or ('%s>=%d'):format(key, value)
        if exports.toxic_core:Groups_has(src, query) == true then return true end
    end
    return false
end

---Toxic Core has no death/cuff state in core (spec §6); those checks run on
---the client (client/device.lua). Server side only requires a loaded session.
---@param src integer
---@return boolean
function core.canUseDevice(src)
    return core.isLoaded(src)
end

---@param fn fun(src: integer)
function core.onLoaded(fn)
    AddEventHandler('toxic_core:characterLoaded', function(src) fn(src) end)
end

---@param fn fun(src: integer)
function core.onUnloaded(fn)
    AddEventHandler('toxic_core:characterUnloaded', function(src) fn(src) end)
end

return core
