---SQL for toxic_ipad_notes (docs/DATABASE.md §4). Every mutation carries
---`AND device_id = ?` so a note id from another device can never match.

local db = require 'server.storage.mysql'

local storage = {}

local LIST = [[
SELECT `id`, `title`, `body`, `pinned`, UNIX_TIMESTAMP(`updated_at`) AS `updated_at`
FROM `toxic_ipad_notes`
WHERE `device_id` = ?
ORDER BY `updated_at` DESC, `id` DESC
LIMIT ?]]

local INSERT = 'INSERT INTO `toxic_ipad_notes` (`device_id`, `title`, `body`, `pinned`) VALUES (?, ?, ?, ?)'
local UPDATE = 'UPDATE `toxic_ipad_notes` SET `title` = ?, `body` = ?, `pinned` = ? WHERE `id` = ? AND `device_id` = ?'
local DELETE = 'DELETE FROM `toxic_ipad_notes` WHERE `id` = ? AND `device_id` = ?'

---@param deviceId integer
---@param limit integer
---@return table[]
function storage.list(deviceId, limit)
    return db.query(LIST, { deviceId, limit })
end

---@return integer? id
function storage.insert(deviceId, title, body, pinned)
    return db.insert(INSERT, { deviceId, title, body, pinned and 1 or 0 })
end

---@return boolean updated
function storage.update(deviceId, id, title, body, pinned)
    return db.update(UPDATE, { title, body, pinned and 1 or 0, id, deviceId }) == 1
end

---@return boolean deleted
function storage.delete(deviceId, id)
    return db.update(DELETE, { id, deviceId }) == 1
end

return storage
