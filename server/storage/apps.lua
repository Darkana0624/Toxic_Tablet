---SQL for installed apps, removed preinstalled apps and app data
---(docs/DATABASE.md §4). Every statement is keyed by device_id first.

local db = require 'server.storage.mysql'

local storage = {}

local SELECT_INSTALLED = 'SELECT `app_id`, `permissions` FROM `toxic_ipad_installed_apps` WHERE `device_id` = ?'
local SELECT_REMOVED = 'SELECT `app_id` FROM `toxic_ipad_app_removals` WHERE `device_id` = ?'

local INSERT_INSTALLED = [[
INSERT INTO `toxic_ipad_installed_apps` (`device_id`, `app_id`, `permissions`) VALUES (?, ?, ?)
ON DUPLICATE KEY UPDATE `permissions` = VALUES(`permissions`)]]
local DELETE_INSTALLED = 'DELETE FROM `toxic_ipad_installed_apps` WHERE `device_id` = ? AND `app_id` = ?'
local INSERT_REMOVED = 'INSERT IGNORE INTO `toxic_ipad_app_removals` (`device_id`, `app_id`) VALUES (?, ?)'
local DELETE_REMOVED = 'DELETE FROM `toxic_ipad_app_removals` WHERE `device_id` = ? AND `app_id` = ?'
local DELETE_APP_DATA = 'DELETE FROM `toxic_ipad_app_data` WHERE `device_id` = ? AND `app_id` = ?'

local SELECT_VALUE = [[
SELECT `value`, `size_bytes` FROM `toxic_ipad_app_data`
WHERE `device_id` = ? AND `app_id` = ? AND `data_key` = ? LIMIT 1]]
local UPSERT_VALUE = [[
INSERT INTO `toxic_ipad_app_data` (`device_id`, `app_id`, `data_key`, `value`, `size_bytes`) VALUES (?, ?, ?, ?, ?)
ON DUPLICATE KEY UPDATE `value` = VALUES(`value`), `size_bytes` = VALUES(`size_bytes`)]]
local DELETE_VALUE = 'DELETE FROM `toxic_ipad_app_data` WHERE `device_id` = ? AND `app_id` = ? AND `data_key` = ?'
local USAGE_BY_APP = [[
SELECT `app_id`, COALESCE(SUM(`size_bytes`), 0) AS `bytes`, COUNT(*) AS `count`
FROM `toxic_ipad_app_data` WHERE `device_id` = ? GROUP BY `app_id`]]

---@param deviceId integer
---@return table[] installed rows { app_id, permissions }
---@return table[] removed rows { app_id }
function storage.load(deviceId)
    return db.query(SELECT_INSTALLED, { deviceId }), db.query(SELECT_REMOVED, { deviceId })
end

---Installs an app: clears a removal and (for store apps) writes the row.
---@param deviceId integer
---@param appId string
---@param writeRow boolean
---@return boolean
function storage.install(deviceId, appId, writeRow)
    local queries = { { query = DELETE_REMOVED, values = { deviceId, appId } } }
    if writeRow then
        queries[#queries + 1] = { query = INSERT_INSTALLED, values = { deviceId, appId, '{}' } }
    end
    return db.transaction(queries)
end

---Uninstalls an app and deletes its data in one transaction.
---@param deviceId integer
---@param appId string
---@param rememberRemoval boolean preinstalled apps stay removed
---@return boolean
function storage.uninstall(deviceId, appId, rememberRemoval)
    local queries = {
        { query = DELETE_INSTALLED, values = { deviceId, appId } },
        { query = DELETE_APP_DATA, values = { deviceId, appId } },
    }
    if rememberRemoval then
        queries[#queries + 1] = { query = INSERT_REMOVED, values = { deviceId, appId } }
    end
    return db.transaction(queries)
end

---@param deviceId integer
---@param appId string
---@param permissionsJson string
function storage.savePermissions(deviceId, appId, permissionsJson)
    db.update(INSERT_INSTALLED, { deviceId, appId, permissionsJson })
end

---@param deviceId integer
---@param appId string
---@param key string
---@return table? row { value, size_bytes }
function storage.getValue(deviceId, appId, key)
    return db.single(SELECT_VALUE, { deviceId, appId, key })
end

---@param deviceId integer
---@param appId string
---@param key string
---@param value string JSON
function storage.setValue(deviceId, appId, key, value)
    db.update(UPSERT_VALUE, { deviceId, appId, key, value, #value })
end

---@param deviceId integer
---@param appId string
---@param key string
---@return boolean deleted
function storage.removeValue(deviceId, appId, key)
    return db.update(DELETE_VALUE, { deviceId, appId, key }) == 1
end

---@param deviceId integer
---@return table<string, { bytes: integer, count: integer }>
function storage.usage(deviceId)
    local out = {}
    for _, row in ipairs(db.query(USAGE_BY_APP, { deviceId })) do
        out[row.app_id] = { bytes = math.tointeger(tonumber(row.bytes)) or 0, count = math.tointeger(tonumber(row.count)) or 0 }
    end
    return out
end

return storage
