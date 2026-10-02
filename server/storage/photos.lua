---SQL for toxic_ipad_photos (docs/DATABASE.md §2.2). Every statement is
---keyed by device_id; ids from a client are only ever used together with it.

local db = require 'server.storage.mysql'

local storage = {}

local COLUMNS = '`id`, `url`, `selfie`, `favorite`, `size_bytes`, `location`, UNIX_TIMESTAMP(`created_at`) AS `created_at`'

local INSERT = [[
INSERT INTO `toxic_ipad_photos` (`device_id`, `url`, `selfie`, `size_bytes`, `location`)
VALUES (?, ?, ?, ?, ?)]]
local PAGE = ([[
SELECT %s FROM `toxic_ipad_photos`
WHERE `device_id` = ? AND `id` < ?
ORDER BY `id` DESC
LIMIT ?]]):format(COLUMNS)
local ONE = ('SELECT %s FROM `toxic_ipad_photos` WHERE `id` = ? AND `device_id` = ? LIMIT 1'):format(COLUMNS)
local USAGE = 'SELECT COUNT(*) AS `n`, COALESCE(SUM(`size_bytes`), 0) AS `bytes` FROM `toxic_ipad_photos` WHERE `device_id` = ?'
local FAVORITE = 'UPDATE `toxic_ipad_photos` SET `favorite` = ? WHERE `id` = ? AND `device_id` = ?'

---@param value any
---@return integer
local function int(value)
    return math.tointeger(tonumber(value)) or 0
end
storage.int = int

---@param deviceId integer
---@param photo { url: string, selfie: boolean, size: integer, location: string? }
---@return integer? id
function storage.insert(deviceId, photo)
    return db.insert(INSERT, { deviceId, photo.url, photo.selfie and 1 or 0, photo.size, photo.location })
end

---Newest first, below `beforeId`.
---@param deviceId integer
---@param beforeId integer
---@param limit integer
---@return table[]
function storage.page(deviceId, beforeId, limit)
    return db.query(PAGE, { deviceId, beforeId, limit })
end

---@param deviceId integer
---@param id integer
---@return table?
function storage.get(deviceId, id)
    return db.single(ONE, { id, deviceId })
end

---@param deviceId integer
---@return integer count
---@return integer bytes
function storage.usage(deviceId)
    local row = db.single(USAGE, { deviceId }) or {}
    return int(row.n), int(row.bytes)
end

---Deletes photos of this device; returns how many rows and bytes went.
---The ids are integers checked by the schema; they are bound, never
---concatenated.
---@param deviceId integer
---@param ids integer[]
---@return integer count
---@return integer bytes
function storage.delete(deviceId, ids)
    if #ids == 0 then return 0, 0 end
    local marks = ('?,'):rep(#ids):sub(1, -2)
    local params = { deviceId }
    for i = 1, #ids do params[i + 1] = ids[i] end
    local row = db.single(('SELECT COUNT(*) AS `n`, COALESCE(SUM(`size_bytes`), 0) AS `bytes` FROM `toxic_ipad_photos` WHERE `device_id` = ? AND `id` IN (%s)'):format(marks), params) or {}
    local removed = db.update(('DELETE FROM `toxic_ipad_photos` WHERE `device_id` = ? AND `id` IN (%s)'):format(marks), params)
    if removed == int(row.n) then return removed, int(row.bytes) end
    -- another request removed some in between: recount lazily
    return removed, -1
end

---@param deviceId integer
---@param id integer
---@param favorite boolean
---@return boolean
function storage.setFavorite(deviceId, id, favorite)
    return db.update(FAVORITE, { favorite and 1 or 0, id, deviceId }) == 1
end

return storage
