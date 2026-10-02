---Inventory adapter: ox_inventory 2.47+. Server side.
---Only this file may name ox_inventory (docs/ARCHITECTURE.md §6.2).
---Verified against ox_inventory 2.47.9 source (docs/RESEARCH.md F4–F6).

local inv = { name = 'ox_inventory', resource = 'ox_inventory' }

---@return boolean
function inv.available()
    return GetResourceState('ox_inventory') == 'started'
end

---@param src integer
---@param slot integer
---@return { name: string, slot: integer, metadata: table? }?
function inv.getSlot(src, slot)
    return exports.ox_inventory:GetSlot(src, slot)
end

---@param src integer
---@param slot integer
---@param metadata table
function inv.setMetadata(src, slot, metadata)
    exports.ox_inventory:SetMetadata(src, slot, metadata)
end

---@param src integer
---@param slot integer
---@param serial string
---@param itemNames table<string, true>
---@return boolean
function inv.slotHoldsSerial(src, slot, serial, itemNames)
    local data = inv.getSlot(src, slot)
    return data ~= nil and itemNames[data.name] == true
        and type(data.metadata) == 'table' and data.metadata.serial == serial
end

---Every tablet a player carries, in slot order.
---@param src integer
---@param itemNames table<string, true>
---@return { slot: integer, name: string, metadata: table }[]
function inv.findDevices(src, itemNames)
    local found = {}
    local items = exports.ox_inventory:GetInventoryItems(src) or {}
    for _, item in pairs(items) do
        if item and itemNames[item.name] then
            found[#found + 1] = { slot = item.slot, name = item.name, metadata = item.metadata or {} }
        end
    end
    table.sort(found, function(a, b) return a.slot < b.slot end)
    return found
end

---The slot currently holding `serial` in a player's inventory, if any.
---@param src integer
---@param serial string
---@param itemNames table<string, true>
---@return integer?
function inv.findSerial(src, serial, itemNames)
    for _, item in ipairs(inv.findDevices(src, itemNames)) do
        if item.metadata.serial == serial then return item.slot end
    end
    return nil
end

---Checks the item definitions required by toxic_ipad (RESEARCH F5).
---@param itemName string
---@return string[] problems
function inv.checkItem(itemName)
    local def = exports.ox_inventory:Items(itemName)
    if not def then
        return { ('item "%s" is not defined in ox_inventory/data/items.lua (see docs/INSTALLATION.md).'):format(itemName) }
    end
    local problems = {}
    if def.consume ~= 0 then
        problems[#problems + 1] = ('item "%s" must have consume = 0, otherwise ox_inventory deletes the tablet when it is used.'):format(itemName)
    end
    if def.stack ~= false then
        problems[#problems + 1] = ('item "%s" must have stack = false (every tablet is a separate device).'):format(itemName)
    end
    if not def.cb then
        problems[#problems + 1] = ('item "%s" must have server = { export = \'toxic_ipad.useItem\' }.'):format(itemName)
    end
    return problems
end

---Stamps a serial on every new tablet, whoever creates it (shop, admin,
---crafting). Returning a table from the createItem hook replaces the metadata.
---@param itemNames table<string, true>
---@param makeMetadata fun(itemName: string, metadata: table): table
---@return integer hookId
function inv.registerSerialHook(itemNames, makeMetadata)
    return exports.ox_inventory:registerHook('createItem', function(payload)
        local metadata = type(payload.metadata) == 'table' and payload.metadata or {}
        if metadata.serial then return end
        return makeMetadata(payload.item.name, metadata)
    end, { itemFilter = itemNames })
end

---Calls `fn(src)` after any move/give/drop of a tablet, for the player who
---moved it AND for the player inventories it left or entered (a tablet taken
---from someone by another player ends the owner's session too), so the
---session can follow the item to its new slot or end.
---@param itemNames table<string, true>
---@param fn fun(src: integer)
---@return integer hookId
function inv.onMoved(itemNames, fn)
    return exports.ox_inventory:registerHook('swapItems', function(payload)
        local players = {}
        for _, id in ipairs({ payload.source, payload.fromInventory, payload.toInventory }) do
            if type(id) == 'number' then players[id] = true end
        end
        -- run after ox_inventory has applied the swap
        SetTimeout(0, function()
            for src in pairs(players) do fn(src) end
        end)
    end, { itemFilter = itemNames })
end

---@param src integer
---@param itemName string
---@param count integer
---@return boolean ok
---@return string? err
function inv.addItem(src, itemName, count)
    local ok, response = exports.ox_inventory:AddItem(src, itemName, count)
    if ok then return true end
    return false, type(response) == 'string' and response or 'add_failed'
end

---@param hookId integer
---How many of an item a player carries (any metadata).
---@param src integer
---@param itemName string
---@return integer
function inv.count(src, itemName)
    return math.tointeger(exports.ox_inventory:GetItemCount(src, itemName)) or 0
end

---Removes `count` of an item from a player. Only the item leaves the
---inventory: no use handler of the item runs (a power bank shared with a
---phone resource keeps its own use behaviour).
---@param src integer
---@param itemName string
---@param count integer
---@return boolean removed
function inv.removeItem(src, itemName, count)
    return exports.ox_inventory:RemoveItem(src, itemName, count) == true
end

---@param itemName string
---@return string
function inv.itemLabel(itemName)
    local def = exports.ox_inventory:Items(itemName)
    return def and def.label or itemName
end

---@param itemName string
---@return boolean
function inv.itemExists(itemName)
    return exports.ox_inventory:Items(itemName) ~= nil
end

function inv.removeHook(hookId)
    exports.ox_inventory:removeHooks(hookId)
end

return inv
