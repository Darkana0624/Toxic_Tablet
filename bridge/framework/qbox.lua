---Framework adapter: Qbox (qbx_core 1.24+). Server side.
---Only this file may name qbx_core (docs/ARCHITECTURE.md §6.1).

local qbox = { name = 'qbox', resource = 'qbx_core' }

---@return boolean
function qbox.available()
    return GetResourceState('qbx_core') == 'started'
end

---@param src integer
---@return table? PlayerData
local function data(src)
    local player = exports.qbx_core:GetPlayer(src)
    return player and player.PlayerData or nil
end

---Stable character id (citizenid).
---@param src integer
---@return string?
function qbox.getIdentifier(src)
    local pd = data(src)
    return pd and pd.citizenid or nil
end

---@param src integer
---@return { first: string, last: string }?
function qbox.getName(src)
    local pd = data(src)
    local info = pd and pd.charinfo
    if not info then return nil end
    return { first = tostring(info.firstname or ''), last = tostring(info.lastname or '') }
end

---@param src integer
---@return boolean
function qbox.isLoaded(src)
    return data(src) ~= nil
end

---@param src integer
---@param filter string|string[]|table<string, integer>
---@return boolean
function qbox.hasGroup(src, filter)
    return exports.qbx_core:HasGroup(src, filter) == true
end

---Dead, downed or cuffed players cannot use a tablet.
---@param src integer
---@return boolean
function qbox.canUseDevice(src)
    local pd = data(src)
    if not pd then return false end
    local meta = pd.metadata or {}
    return not (meta.isdead or meta.inlaststand or meta.ishandcuffed)
end

---@param fn fun(src: integer)
function qbox.onLoaded(fn)
    AddEventHandler('QBCore:Server:PlayerLoaded', function(player)
        local src = player and player.PlayerData and player.PlayerData.source
        if src then fn(src) end
    end)
end

---@param fn fun(src: integer)
function qbox.onUnloaded(fn)
    AddEventHandler('QBCore:Server:OnPlayerUnload', function(src)
        fn(src)
    end)
end

return qbox
