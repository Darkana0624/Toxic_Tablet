---SQL for toxic_ipad_devices and toxic_ipad_device_settings
---(docs/DATABASE.md §4). Every value is a placeholder; nothing else in the
---resource writes these tables.

local db = require 'server.storage.mysql'

local SELECT_DEVICE = [[
SELECT d.`id`, d.`serial`, d.`model`, d.`owner_identifier`, d.`storage_capacity_mb`, d.`storage_used_bytes`,
       d.`battery_bp`, UNIX_TIMESTAMP(d.`battery_stamp`) AS `battery_stamp`, d.`battery_health`, d.`charging`,
       d.`passcode_hash`, d.`passcode_length`, d.`failed_attempts`, UNIX_TIMESTAMP(d.`locked_until`) AS `locked_until`,
       s.`data` AS `settings`,
       st.`lost`, st.`lost_message`, st.`last_x`, st.`last_y`, st.`last_z`,
       UNIX_TIMESTAMP(st.`last_seen`) AS `last_seen`, st.`charge_bp`
FROM `toxic_ipad_devices` d
LEFT JOIN `toxic_ipad_device_settings` s ON s.`device_id` = d.`id`
LEFT JOIN `toxic_ipad_device_status` st ON st.`device_id` = d.`id`
WHERE d.`serial` = ?
LIMIT 1]]

local INSERT_DEVICE = [[
INSERT IGNORE INTO `toxic_ipad_devices` (`serial`, `model`, `owner_identifier`, `storage_capacity_mb`)
VALUES (?, ?, ?, ?)]]

local UPSERT_SETTINGS = [[
INSERT INTO `toxic_ipad_device_settings` (`device_id`, `schema_version`, `data`)
VALUES (?, ?, ?)
ON DUPLICATE KEY UPDATE `schema_version` = VALUES(`schema_version`), `data` = VALUES(`data`)]]

local UPDATE_STATE = [[
UPDATE `toxic_ipad_devices`
SET `battery_bp` = ?, `battery_stamp` = FROM_UNIXTIME(?), `charging` = ?, `storage_used_bytes` = ?
WHERE `id` = ?]]

local UPDATE_PASSCODE = [[
UPDATE `toxic_ipad_devices`
SET `passcode_hash` = ?, `passcode_length` = ?, `failed_attempts` = 0, `locked_until` = NULL
WHERE `id` = ?]]

local UPDATE_ATTEMPTS = [[
UPDATE `toxic_ipad_devices`
SET `failed_attempts` = ?, `locked_until` = IF(? = 0, NULL, FROM_UNIXTIME(?))
WHERE `id` = ?]]

local UPDATE_OWNER = [[
UPDATE `toxic_ipad_devices` SET `owner_identifier` = ? WHERE `id` = ? AND `owner_identifier` IS NULL]]

local SERIALS_BY_OWNER = 'SELECT `serial` FROM `toxic_ipad_devices` WHERE `owner_identifier` = ? LIMIT 10'

-- Find My: every tablet of a character with its status (no settings blob)
local OWNED = [[
SELECT d.`id`, d.`serial`, d.`model`, d.`battery_bp`, UNIX_TIMESTAMP(d.`battery_stamp`) AS `battery_stamp`,
       st.`lost`, st.`lost_message`, st.`last_x`, st.`last_y`, st.`last_z`, UNIX_TIMESTAMP(st.`last_seen`) AS `last_seen`,
       st.`charge_bp`
FROM `toxic_ipad_devices` d
LEFT JOIN `toxic_ipad_device_status` st ON st.`device_id` = d.`id`
WHERE d.`owner_identifier` = ?
ORDER BY d.`id`
LIMIT 10]]
local OWNED_ONE = [[
SELECT d.`id`, d.`serial` FROM `toxic_ipad_devices` d WHERE d.`serial` = ? AND d.`owner_identifier` = ? LIMIT 1]]
local ID_BY_SERIAL = 'SELECT `id` FROM `toxic_ipad_devices` WHERE `serial` = ? LIMIT 1'

local UPSERT_SEEN = [[
INSERT INTO `toxic_ipad_device_status` (`device_id`, `last_x`, `last_y`, `last_z`, `last_seen`) VALUES (?, ?, ?, ?, NOW())
ON DUPLICATE KEY UPDATE `last_x` = VALUES(`last_x`), `last_y` = VALUES(`last_y`), `last_z` = VALUES(`last_z`), `last_seen` = VALUES(`last_seen`)]]
local UPSERT_CHARGE = [[
INSERT INTO `toxic_ipad_device_status` (`device_id`, `charge_bp`) VALUES (?, ?)
ON DUPLICATE KEY UPDATE `charge_bp` = VALUES(`charge_bp`)]]
local UPSERT_LOST = [[
INSERT INTO `toxic_ipad_device_status` (`device_id`, `lost`, `lost_message`) VALUES (?, ?, ?)
ON DUPLICATE KEY UPDATE `lost` = VALUES(`lost`), `lost_message` = VALUES(`lost_message`)]]

-- Erase: every table that holds a tablet's content. Files: the roots go
-- first (ON DELETE CASCADE removes their trees), then anything left.
local ERASE = {
    'DELETE FROM `toxic_ipad_notes` WHERE `device_id` = ?',
    'DELETE FROM `toxic_ipad_files` WHERE `device_id` = ? AND `parent_id` IS NULL',
    'DELETE FROM `toxic_ipad_files` WHERE `device_id` = ?',
    'DELETE FROM `toxic_ipad_photos` WHERE `device_id` = ?',
    'DELETE FROM `toxic_ipad_app_data` WHERE `device_id` = ?',
    'DELETE FROM `toxic_ipad_installed_apps` WHERE `device_id` = ?',
    'DELETE FROM `toxic_ipad_app_removals` WHERE `device_id` = ?',
    'DELETE FROM `toxic_ipad_notifications` WHERE `device_id` = ?',
    'DELETE FROM `toxic_ipad_device_settings` WHERE `device_id` = ?',
    'UPDATE `toxic_ipad_device_status` SET `lost` = 0, `lost_message` = NULL WHERE `device_id` = ?',
}
local RESET_DEVICE = [[
UPDATE `toxic_ipad_devices`
SET `passcode_hash` = NULL, `passcode_length` = NULL, `failed_attempts` = 0, `locked_until` = NULL, `storage_used_bytes` = 0
WHERE `id` = ?]]
local RESET_DEVICE_OWNER = [[
UPDATE `toxic_ipad_devices`
SET `passcode_hash` = NULL, `passcode_length` = NULL, `failed_attempts` = 0, `locked_until` = NULL, `storage_used_bytes` = 0,
    `owner_identifier` = NULL
WHERE `id` = ?]]

local storage = {}

---@param owner string
---@return string[]
function storage.serialsByOwner(owner)
    local out = {}
    for _, row in ipairs(db.query(SERIALS_BY_OWNER, { owner })) do out[#out + 1] = row.serial end
    return out
end

---@param serial string
---@return table? row
function storage.find(serial)
    return db.single(SELECT_DEVICE, { serial })
end

---Creates the device row if the serial is new. Safe under a race (two
---players using a freshly given tablet in the same tick): INSERT IGNORE on
---the unique serial, then read back whichever row won.
---@param serial string
---@param model string
---@param owner string?
---@param capacityMb integer
---@return table? row
function storage.create(serial, model, owner, capacityMb)
    db.update(INSERT_DEVICE, { serial, model, owner, capacityMb })
    return storage.find(serial)
end

---@param deviceId integer
---@param version integer
---@param json string
function storage.saveSettings(deviceId, version, json)
    db.update(UPSERT_SETTINGS, { deviceId, version, json })
end

---Non-yielding variants for resource stop.
---@param deviceId integer
---@param version integer
---@param json string
function storage.saveSettingsNow(deviceId, version, json)
    db.fire(UPSERT_SETTINGS, { deviceId, version, json })
end

---@param deviceId integer
---@param batteryBp integer
---@param stamp integer
---@param charging boolean
---@param usedBytes integer
function storage.saveStateNow(deviceId, batteryBp, stamp, charging, usedBytes)
    db.fire(UPDATE_STATE, { batteryBp, stamp, charging and 1 or 0, usedBytes, deviceId })
end

---@param deviceId integer
---@param batteryBp integer
---@param stamp integer unix seconds
---@param charging boolean
---@param usedBytes integer
function storage.saveState(deviceId, batteryBp, stamp, charging, usedBytes)
    db.update(UPDATE_STATE, { batteryBp, stamp, charging and 1 or 0, usedBytes, deviceId })
end

---@param deviceId integer
---@param hash string?
---@param length integer?
function storage.savePasscode(deviceId, hash, length)
    db.update(UPDATE_PASSCODE, { hash, length, deviceId })
end

---@param deviceId integer
---@param attempts integer
---@param lockedUntil integer  unix seconds, 0 = not locked
function storage.saveAttempts(deviceId, attempts, lockedUntil)
    db.update(UPDATE_ATTEMPTS, { attempts, lockedUntil, lockedUntil, deviceId })
end

---@param owner string
---@return table[] rows (Find My)
function storage.owned(owner)
    return db.query(OWNED, { owner })
end

---The device id of `serial` when `owner` owns it.
---@param serial string
---@param owner string
---@return integer?
function storage.ownedId(serial, owner)
    local row = db.single(OWNED_ONE, { serial, owner })
    return row and (math.tointeger(tonumber(row.id)) or nil) or nil
end

---@param serial string
---@return integer?
function storage.idOf(serial)
    local id = db.scalar(ID_BY_SERIAL, { serial })
    return id and math.tointeger(tonumber(id)) or nil
end

---Last seen position. Non-yielding (called from close/drop paths).
---@param deviceId integer
---@param x number
---@param y number
---@param z number
function storage.seenNow(deviceId, x, y, z)
    db.fire(UPSERT_SEEN, { deviceId, x, y, z })
end

---@param deviceId integer
---@param chargeBp integer
function storage.saveCharge(deviceId, chargeBp)
    db.update(UPSERT_CHARGE, { deviceId, chargeBp })
end

---@param deviceId integer
---@param chargeBp integer
function storage.saveChargeNow(deviceId, chargeBp)
    db.fire(UPSERT_CHARGE, { deviceId, chargeBp })
end

---@param deviceId integer
---@param lost boolean
---@param message string?
function storage.saveLost(deviceId, lost, message)
    db.update(UPSERT_LOST, { deviceId, lost and 1 or 0, lost and message or nil })
end

---Erases a tablet's content in one transaction (owner kept unless removeOwner).
---@param deviceId integer
---@param removeOwner boolean
---@return boolean committed
function storage.erase(deviceId, removeOwner)
    local queries = {}
    for i, sql in ipairs(ERASE) do queries[i] = { query = sql, values = { deviceId } } end
    queries[#queries + 1] = { query = removeOwner and RESET_DEVICE_OWNER or RESET_DEVICE, values = { deviceId } }
    return db.transaction(queries)
end

---Claims an ownerless device (e.g. created by an admin command) for the
---first character who uses it.
---@param deviceId integer
---@param owner string
---@return boolean claimed
function storage.claimOwner(deviceId, owner)
    return db.update(UPDATE_OWNER, { owner, deviceId }) == 1
end

return storage
