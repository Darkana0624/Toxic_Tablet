---Resolves the `target` argument of the public exports (Notify, SaveFile…)
---to device records (docs/ARCHITECTURE.md §7):
---  player source      → the tablet they have open, else every tablet they carry
---  { serial = '…' }   → that tablet (must already exist)
---  { identifier = '…' } → every tablet owned by that character
---Must run in a coroutine (it may load devices from the database).

local targets = {}

local session, device, inventory, itemNames

---@param deps { session: table, device: table, inventory: table, itemNames: table<string, true> }
function targets.init(deps)
    session, device, inventory, itemNames = deps.session, deps.device, deps.inventory, deps.itemNames
end

---@param target any
---@return table[] IpadDevice records
function targets.resolve(target)
    local recs = {}
    if type(target) == 'number' then
        local s = session.get(target)
        if s then return { s.device } end
        for _, item in ipairs(inventory.findDevices(target, itemNames)) do
            if item.metadata.serial then
                local rec = device.resolve(item.metadata.serial, item.name, nil)
                if rec then recs[#recs + 1] = rec end
            end
        end
    elseif type(target) == 'table' and type(target.serial) == 'string' then
        local rec = device.resolve(target.serial, nil, nil, true)
        if rec then recs[1] = rec end
    elseif type(target) == 'table' and type(target.identifier) == 'string' then
        for _, rec in ipairs(device.byOwner(target.identifier)) do recs[#recs + 1] = rec end
    end
    return recs
end

---Every open session of this device.
---@param rec table
---@return table[] IpadSession
function targets.sessions(rec)
    local out = {}
    for _, s in pairs(session.all()) do
        if s.device == rec then out[#out + 1] = s end
    end
    return out
end

---Every player source that currently has this device open.
---@param rec table
---@return integer[]
function targets.viewers(rec)
    local out = {}
    for src, s in pairs(session.all()) do
        if s.device == rec then out[#out + 1] = src end
    end
    return out
end

return targets
