---oxmysql adapter used by the storage layer (copied from toxic_core, plus `fire`). Every call is an `.await` form
---and therefore must run inside a coroutine (event handlers, threads and
---ox_lib callbacks all are). SQL errors are raised, not swallowed: callers
---that can recover wrap the call; everything else lets the error surface.

local db = {}

---@param sql string
---@param params? table
---@return table[] rows
function db.query(sql, params)
    return MySQL.query.await(sql, params or {}) or {}
end

---@param sql string
---@param params? table
---@return integer affectedRows
function db.update(sql, params)
    return MySQL.update.await(sql, params or {}) or 0
end

---@param sql string
---@param params? table
---@return table? row
function db.single(sql, params)
    return MySQL.single.await(sql, params or {})
end

---@param sql string
---@param params? table
---@return any value
function db.scalar(sql, params)
    return MySQL.scalar.await(sql, params or {})
end

---@param sql string
---@param params? table
---@return integer? insertId
function db.insert(sql, params)
    return MySQL.insert.await(sql, params or {})
end

---@param queries table[] { { query = string, values = table }, ... }
---@return boolean committed
function db.transaction(queries)
    return MySQL.transaction.await(queries) == true
end

---Sends a write without waiting for it (callback form). Used only on
---resource stop, where a yielding `.await` may never resume.
---@param sql string
---@param params? table
function db.fire(sql, params)
    MySQL.update(sql, params or {})
end

---Blocks until oxmysql has a database connection.
function db.ready()
    MySQL.ready.await()
end

return db
