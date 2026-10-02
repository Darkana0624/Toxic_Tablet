---SQL for toxic_ipad_notifications (docs/DATABASE.md §4).

local db = require 'server.storage.mysql'

local storage = {}

local SELECT_RECENT = [[
SELECT `id`, `app_id`, `title`, `message`, `priority`, `route`, `is_read`, UNIX_TIMESTAMP(`created_at`) AS `created_at`
FROM `toxic_ipad_notifications`
WHERE `device_id` = ?
ORDER BY `created_at` DESC, `id` DESC
LIMIT ?]]

local INSERT = [[
INSERT INTO `toxic_ipad_notifications` (`device_id`, `app_id`, `title`, `message`, `priority`, `route`)
VALUES (?, ?, ?, ?, ?, ?)]]

local COUNT = 'SELECT COUNT(*) FROM `toxic_ipad_notifications` WHERE `device_id` = ?'

local PRUNE = [[
DELETE FROM `toxic_ipad_notifications` WHERE `device_id` = ?
ORDER BY `created_at` ASC, `id` ASC
LIMIT ?]]

local MARK_READ = 'UPDATE `toxic_ipad_notifications` SET `is_read` = 1 WHERE `device_id` = ? AND `id` IN (?)'
local MARK_ALL_READ = 'UPDATE `toxic_ipad_notifications` SET `is_read` = 1 WHERE `device_id` = ? AND `is_read` = 0'
local DELETE_ONE = 'DELETE FROM `toxic_ipad_notifications` WHERE `device_id` = ? AND `id` = ?'
local DELETE_ALL = 'DELETE FROM `toxic_ipad_notifications` WHERE `device_id` = ?'

---@param deviceId integer
---@param limit integer
---@return table[]
function storage.recent(deviceId, limit)
    return db.query(SELECT_RECENT, { deviceId, limit })
end

---Inserts one notification and trims the device to `keep` rows.
---@return integer? id
function storage.insert(deviceId, appId, title, message, priority, route, keep)
    local id = db.insert(INSERT, { deviceId, appId, title, message, priority, route })
    local count = tonumber(db.scalar(COUNT, { deviceId })) or 0
    if count > keep then
        db.update(PRUNE, { deviceId, count - keep })
    end
    return id
end

---@param deviceId integer
---@param ids integer[]?  nil = all
function storage.markRead(deviceId, ids)
    if ids then
        db.update(MARK_READ, { deviceId, ids })
    else
        db.update(MARK_ALL_READ, { deviceId })
    end
end

---@param deviceId integer
---@param id integer?  nil = all
function storage.delete(deviceId, id)
    if id then
        db.update(DELETE_ONE, { deviceId, id })
    else
        db.update(DELETE_ALL, { deviceId })
    end
end

return storage
