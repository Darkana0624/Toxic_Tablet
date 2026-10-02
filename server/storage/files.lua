---SQL for toxic_ipad_files (docs/DATABASE.md §4). Every statement carries
---`device_id = ?`; system roots (Documents, Downloads) cannot be renamed,
---moved or deleted (`system = 0` in every mutation).

local db = require 'server.storage.mysql'

local storage = {}

local COLUMNS = '`id`, `parent_id`, `kind`, `name`, `mime`, `size_bytes`, `ref`, `system`, UNIX_TIMESTAMP(`created_at`) AS `created_at`'

local SELECT_ROOTS = ('SELECT %s FROM `toxic_ipad_files` WHERE `device_id` = ? AND `parent_id` IS NULL AND `system` = 1'):format(COLUMNS)
local INSERT_ROOT = 'INSERT INTO `toxic_ipad_files` (`device_id`, `parent_id`, `kind`, `name`, `system`) VALUES (?, NULL, 1, ?, 1)'
local SELECT_CHILDREN = ([[
SELECT %s FROM `toxic_ipad_files`
WHERE `device_id` = ? AND `parent_id` = ?
ORDER BY `kind` ASC, `name` ASC
LIMIT ?]]):format(COLUMNS)
local SELECT_ONE = ('SELECT %s FROM `toxic_ipad_files` WHERE `id` = ? AND `device_id` = ? LIMIT 1'):format(COLUMNS)
local NAME_TAKEN = 'SELECT 1 FROM `toxic_ipad_files` WHERE `device_id` = ? AND `parent_id` = ? AND `name` = ? LIMIT 1'
local INSERT_ENTRY = [[
INSERT INTO `toxic_ipad_files` (`device_id`, `parent_id`, `kind`, `name`, `mime`, `size_bytes`, `ref`)
VALUES (?, ?, ?, ?, ?, ?, ?)]]
local RENAME = 'UPDATE `toxic_ipad_files` SET `name` = ? WHERE `id` = ? AND `device_id` = ? AND `system` = 0'
local MOVE = 'UPDATE `toxic_ipad_files` SET `parent_id` = ? WHERE `id` = ? AND `device_id` = ? AND `system` = 0'
local DELETE = 'DELETE FROM `toxic_ipad_files` WHERE `id` = ? AND `device_id` = ? AND `system` = 0'
local RECENTS = ([[
SELECT %s FROM `toxic_ipad_files`
WHERE `device_id` = ? AND `kind` = 2
ORDER BY `created_at` DESC, `id` DESC
LIMIT ?]]):format(COLUMNS)
local USAGE = 'SELECT COUNT(*) AS `n`, COALESCE(SUM(`size_bytes`), 0) AS `bytes` FROM `toxic_ipad_files` WHERE `device_id` = ?'

-- Subtree of one entry (itself included): how much a delete frees and how
-- tall it is (a folder move must keep the whole tree within maxDepth).
-- Bounded depth and device_id in the recursive step: a damaged tree can
-- never make the query run away.
local SUBTREE = [[
WITH RECURSIVE `sub` AS (
  SELECT `id`, `size_bytes`, 0 AS `depth` FROM `toxic_ipad_files` WHERE `id` = ? AND `device_id` = ?
  UNION ALL
  SELECT f.`id`, f.`size_bytes`, `sub`.`depth` + 1
  FROM `toxic_ipad_files` f JOIN `sub` ON f.`parent_id` = `sub`.`id`
  WHERE f.`device_id` = ? AND `sub`.`depth` < 64
)
SELECT COUNT(*) AS `n`, COALESCE(SUM(`size_bytes`), 0) AS `bytes`, COALESCE(MAX(`depth`), 0) AS `height` FROM `sub`]]

-- Ancestors of one entry, itself first, root last (bounded depth).
local ANCESTORS = [[
WITH RECURSIVE `up` AS (
  SELECT `id`, `parent_id`, `kind`, `name`, `system`, 0 AS `depth` FROM `toxic_ipad_files` WHERE `id` = ? AND `device_id` = ?
  UNION ALL
  SELECT f.`id`, f.`parent_id`, f.`kind`, f.`name`, f.`system`, `up`.`depth` + 1
  FROM `toxic_ipad_files` f JOIN `up` ON f.`id` = `up`.`parent_id`
  WHERE f.`device_id` = ? AND `up`.`depth` < 32
)
SELECT `id`, `parent_id`, `kind`, `name`, `system`, `depth` FROM `up` ORDER BY `depth` ASC]]

local NOTES_BYTES = 'SELECT COALESCE(SUM(LENGTH(`title`) + LENGTH(`body`)), 0) AS `bytes` FROM `toxic_ipad_notes` WHERE `device_id` = ?'

---@param value any
---@return integer
local function int(value)
    return math.tointeger(tonumber(value)) or 0
end
storage.int = int

---@param deviceId integer
---@return table[]
function storage.roots(deviceId)
    return db.query(SELECT_ROOTS, { deviceId })
end

---@param deviceId integer
---@param name string
---@return integer? id
function storage.createRoot(deviceId, name)
    return db.insert(INSERT_ROOT, { deviceId, name })
end

---@param deviceId integer
---@param parentId integer
---@param limit integer
---@return table[]
function storage.children(deviceId, parentId, limit)
    return db.query(SELECT_CHILDREN, { deviceId, parentId, limit })
end

---@param deviceId integer
---@param id integer
---@return table?
function storage.get(deviceId, id)
    return db.single(SELECT_ONE, { id, deviceId })
end

---@param deviceId integer
---@param parentId integer
---@param name string
---@return boolean
function storage.nameTaken(deviceId, parentId, name)
    return db.scalar(NAME_TAKEN, { deviceId, parentId, name }) ~= nil
end

---@param deviceId integer
---@param entry { parent: integer, kind: integer, name: string, mime: string?, size: integer, ref: string? }
---@return integer? id
function storage.insert(deviceId, entry)
    return db.insert(INSERT_ENTRY, { deviceId, entry.parent, entry.kind, entry.name, entry.mime, entry.size, entry.ref })
end

---@return boolean
function storage.rename(deviceId, id, name)
    return db.update(RENAME, { name, id, deviceId }) == 1
end

---@return boolean
function storage.move(deviceId, id, parentId)
    return db.update(MOVE, { parentId, id, deviceId }) == 1
end

---@return boolean
function storage.delete(deviceId, id)
    return db.update(DELETE, { id, deviceId }) == 1
end

---@param deviceId integer
---@param id integer
---@return integer count
---@return integer bytes
---@return integer height  levels below the entry (0 = no children)
function storage.subtree(deviceId, id)
    local row = db.single(SUBTREE, { id, deviceId, deviceId }) or {}
    return int(row.n), int(row.bytes), int(row.height)
end

---@param deviceId integer
---@param id integer
---@return table[] ancestors, itself first
function storage.ancestors(deviceId, id)
    return db.query(ANCESTORS, { id, deviceId, deviceId })
end

---@param deviceId integer
---@param refs string[] bound as parameters, never concatenated
---@return integer removed
function storage.deleteRefs(deviceId, refs)
    local marks = ('?,'):rep(#refs):sub(1, -2)
    local params = { deviceId }
    for i = 1, #refs do params[i + 1] = refs[i] end
    return db.update(('DELETE FROM `toxic_ipad_files` WHERE `device_id` = ? AND `kind` = 2 AND `system` = 0 AND `ref` IN (%s)'):format(marks), params)
end

---@param deviceId integer
---@param limit integer
---@return table[]
function storage.recents(deviceId, limit)
    return db.query(RECENTS, { deviceId, limit })
end

---@param deviceId integer
---@return integer count
---@return integer bytes
function storage.usage(deviceId)
    local row = db.single(USAGE, { deviceId }) or {}
    return int(row.n), int(row.bytes)
end

---@param deviceId integer
---@return integer bytes
function storage.notesBytes(deviceId)
    local row = db.single(NOTES_BYTES, { deviceId }) or {}
    return int(row.bytes)
end

return storage
