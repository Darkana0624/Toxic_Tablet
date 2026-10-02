---Versioned, checksum-guarded, forward-only migration runner
---(adapted from toxic_core; docs/DATABASE.md §6).
---
---The database connection is injected (`db`), so the runner has no oxmysql
---dependency of its own and the unit tests can drive it with a fake database.
---
---Locking uses a row in `toxic_ipad_migration_lock` rather than GET_LOCK(): oxmysql
---runs queries on a connection pool, and GET_LOCK() belongs to the one
---connection that took it, so a pool could release it on the wrong connection.

local sha256 = require 'shared.sha256'
local splitSql = require 'server.storage.sqlsplit'

local BOOTSTRAP = {
    [[CREATE TABLE IF NOT EXISTS `toxic_ipad_migrations` (
  `version`    INT UNSIGNED NOT NULL,
  `name`       VARCHAR(100) NOT NULL,
  `checksum`   CHAR(64)     NOT NULL,
  `applied_at` TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`version`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
    [[CREATE TABLE IF NOT EXISTS `toxic_ipad_migration_lock` (
  `id`          TINYINT UNSIGNED NOT NULL,
  `owner`       VARCHAR(80)  NOT NULL,
  `acquired_at` TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
}

local LOCK_STALE = 'DELETE FROM `toxic_ipad_migration_lock` WHERE `id` = 1 AND `acquired_at` < NOW() - INTERVAL 10 MINUTE'
local LOCK_TAKE = 'INSERT IGNORE INTO `toxic_ipad_migration_lock` (`id`, `owner`) VALUES (1, ?)'
local LOCK_RELEASE = 'DELETE FROM `toxic_ipad_migration_lock` WHERE `id` = 1 AND `owner` = ?'
local SELECT_APPLIED = 'SELECT `version`, `checksum` FROM `toxic_ipad_migrations`'
local INSERT_APPLIED = 'INSERT INTO `toxic_ipad_migrations` (`version`, `name`, `checksum`) VALUES (?, ?, ?)'

---@class ToxicMigrationDb
---@field query fun(sql: string, params?: table): table[]   throws on SQL error
---@field update fun(sql: string, params?: table): integer  affected rows; throws on SQL error

---@class ToxicMigration
---@field version integer
---@field name string
---@field file string
---@field module? string

---@class ToxicMigrateOptions
---@field load fun(file: string): string?      reads a migration file
---@field modules table<string, boolean>       enabled optional modules
---@field owner string                         lock owner id (server instance)
---@field wait fun(ms: integer)                yields between lock attempts
---@field lockAttempts? integer                default 30 (one per second)

local migrate = {}

---Normalises line endings before hashing, so a Windows git checkout
---(CRLF) and a Linux one (LF) produce the same checksum.
---@param text string
---@return string
function migrate.normalize(text)
    return (text:gsub('\r\n', '\n'):gsub('\r', '\n'))
end

---@param list ToxicMigration[]
---@return string[] errors
function migrate.checkList(list)
    local errors, seen, last = {}, {}, 0
    for i, m in ipairs(list) do
        if math.type(m.version) ~= 'integer' or m.version < 1 then
            errors[#errors + 1] = ('migrations/index.lua entry %d: version must be a positive whole number'):format(i)
        elseif seen[m.version] then
            errors[#errors + 1] = ('migrations/index.lua: version %d is listed twice'):format(m.version)
        elseif m.version < last then
            errors[#errors + 1] = ('migrations/index.lua: version %d is out of order'):format(m.version)
        else
            seen[m.version] = true
            last = m.version
        end
        if type(m.name) ~= 'string' or m.name == '' or type(m.file) ~= 'string' or not m.file:match('^[%w_%-]+%.sql$') then
            errors[#errors + 1] = ('migrations/index.lua entry %d: needs a name and a file like 0001_name.sql'):format(i)
        end
    end
    return errors
end

---@param db ToxicMigrationDb
---@param owner string
---@param attempts integer
---@param wait fun(ms: integer)
---@return boolean acquired
local function acquireLock(db, owner, attempts, wait)
    for attempt = 1, attempts do
        db.update(LOCK_STALE)
        if db.update(LOCK_TAKE, { owner }) == 1 then
            return true
        end
        if attempt < attempts then wait(1000) end
    end
    return false
end

---@param db ToxicMigrationDb
---@param list ToxicMigration[]
---@param opts ToxicMigrateOptions
---@param report { applied: integer[], errors: string[] }
local function runLocked(db, list, opts, report)
    local appliedRows = db.query(SELECT_APPLIED)
    local applied = {}
    for _, row in ipairs(appliedRows) do
        applied[math.tointeger(row.version) or row.version] = row.checksum
    end

    local known = {}
    local files = {}

    for _, m in ipairs(list) do
        known[m.version] = true
        local content = opts.load(m.file)
        if not content then
            report.errors[#report.errors + 1] = ('migration %d (%s): file migrations/%s is missing'):format(m.version, m.name, m.file)
        else
            local text = migrate.normalize(content)
            files[m.version] = { text = text, checksum = sha256(text) }
        end
    end

    for version in pairs(applied) do
        if not known[version] then
            report.errors[#report.errors + 1] = ('the database has migration %d, which this toxic_ipad version does not know. An older toxic_ipad was installed over a newer database — install the newer version again.'):format(version)
        end
    end

    for _, m in ipairs(list) do
        local stored, file = applied[m.version], files[m.version]
        if stored and file and stored ~= file.checksum then
            report.errors[#report.errors + 1] = ('migration %d (%s) was changed after it was applied (checksum mismatch). Restore the original migrations/%s from the release.'):format(m.version, m.name, m.file)
        end
    end

    if #report.errors > 0 then return end

    for _, m in ipairs(list) do
        if not applied[m.version] and (not m.module or opts.modules[m.module]) then
            local file = files[m.version]
            local ok, statements = pcall(splitSql, file.text)

            if not ok then
                report.errors[#report.errors + 1] = ('migration %d (%s): %s'):format(m.version, m.name, statements)
                return
            end

            if #statements == 0 then
                report.errors[#report.errors + 1] = ('migration %d (%s): file contains no statements'):format(m.version, m.name)
                return
            end

            for index, statement in ipairs(statements) do
                local success, err = pcall(db.query, statement)
                if not success then
                    report.errors[#report.errors + 1] = ('migration %d (%s) failed at statement %d (%s…): %s')
                        :format(m.version, m.name, index, statement:sub(1, 60):gsub('%s+', ' '), tostring(err))
                    return
                end
            end

            db.update(INSERT_APPLIED, { m.version, m.name, file.checksum })
            report.applied[#report.applied + 1] = m.version
        end
    end
end

---Brings the database schema up to date.
---@param db ToxicMigrationDb
---@param list ToxicMigration[]
---@param opts ToxicMigrateOptions
---@return boolean ok
---@return { applied: integer[], errors: string[] } report
function migrate.run(db, list, opts)
    local report = { applied = {}, errors = migrate.checkList(list) }
    if #report.errors > 0 then return false, report end

    for _, statement in ipairs(BOOTSTRAP) do
        local ok, err = pcall(db.query, statement)
        if not ok then
            report.errors[#report.errors + 1] = ('could not create the migration tables: %s'):format(tostring(err))
            return false, report
        end
    end

    if not acquireLock(db, opts.owner, opts.lockAttempts or 30, opts.wait) then
        report.errors[#report.errors + 1] = 'another server is migrating this database (toxic_ipad_migration_lock is held). If no other server is running, wait 10 minutes or delete the row in toxic_ipad_migration_lock.'
        return false, report
    end

    local ok, err = pcall(runLocked, db, list, opts, report)

    local released, releaseErr = pcall(db.update, LOCK_RELEASE, { opts.owner })

    if not ok then
        report.errors[#report.errors + 1] = ('unexpected migration error: %s'):format(tostring(err))
    end
    if not released then
        report.errors[#report.errors + 1] = ('could not release the migration lock: %s'):format(tostring(releaseErr))
    end

    return #report.errors == 0, report
end

return migrate
