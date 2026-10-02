---NotificationService (docs/ARCHITECTURE.md §7, MVP §78A.7).
---
---Only server code can create a notification: the export `Notify` for
---other resources, and the OS itself. Clients can read, mark read and clear
---their own device's notifications — never create one (SECURITY §4).

local validate = require 'shared.validate'
local storage = require 'server.storage.notifications'
local log = require 'server.log'

local notifications = {}

local KEEP_PER_DEVICE = 200
local BOOT_LIMIT = 60

---Priority names accepted by Notify → stored number.
notifications.PRIORITY = { info = 0, normal = 1, success = 2, warning = 3, critical = 4 }
local PRIORITY_NAMES = {}
for name, value in pairs(notifications.PRIORITY) do PRIORITY_NAMES[value] = name end

local DATA_SCHEMA = {
    type = 'table',
    fields = {
        app = { type = 'string', minLength = 3, maxLength = 32, pattern = '[a-z0-9_]+' },
        title = { type = 'string', minLength = 1, maxLength = 80 },
        message = { type = 'string', minLength = 1, maxLength = 500 },
        priority = { type = 'string', optional = true, enum = { 'info', 'normal', 'success', 'warning', 'critical' } },
        route = { type = 'string', optional = true, maxLength = 128 },
    },
}

local targets

---@param deps { targets: table }
function notifications.init(deps)
    targets = deps.targets
end

---@param row table
---@return table
local function toClient(row)
    return {
        id = math.tointeger(row.id) or row.id,
        app = row.app_id,
        title = row.title,
        message = row.message,
        priority = PRIORITY_NAMES[math.tointeger(row.priority) or 1] or 'normal',
        route = row.route,
        read = row.is_read == 1 or row.is_read == true,
        time = math.tointeger(row.created_at) or os.time(),
    }
end

---Latest notifications for the boot payload.
---@param deviceId integer
---@return table[]
function notifications.recent(deviceId)
    local rows = storage.recent(deviceId, BOOT_LIMIT)
    local out = {}
    for i, row in ipairs(rows) do out[i] = toClient(row) end
    return out
end

---What a locked tablet may show: no message, and the title only when the
---owner allows previews. A locked device's notifications never reach the
---client in full (docs/SECURITY.md) — the page asks for them after unlock.
---@param n table
---@param showTitle boolean
---@return table
function notifications.redact(n, showTitle)
    return {
        id = n.id, app = n.app, priority = n.priority, read = n.read, time = n.time,
        title = showTitle and n.title or nil, redacted = true,
    }
end

---@param s table IpadSession
---@return boolean
local function mustRedact(s)
    return not s.unlocked and s.device.passcodeHash ~= nil
end

---The boot list for a session (redacted while a passcode protects it).
---@param s table IpadSession
---@return table[]
function notifications.forSession(s)
    local list = notifications.recent(s.device.id)
    if not mustRedact(s) then return list end
    local show = s.device.settings.notifications.showPreviews == true
    for i, n in ipairs(list) do list[i] = notifications.redact(n, show) end
    return list
end

---Callback `notif:list` (unlocked sessions only): the full list.
---@param s table IpadSession
---@return table
function notifications.list(s)
    return { ok = true, notifications = notifications.recent(s.device.id) }
end

---Creates a notification and shows it on every open session of the device.
---Must run in a coroutine (exports called from event handlers/threads are).
---@param target integer|{ serial: string }|{ identifier: string }
---@param data table
---@return boolean ok
---@return string? err
function notifications.notify(target, data)
    local ok, errors = validate.schema(data, DATA_SCHEMA, 'Notify')
    if not ok then
        log.warn('notify', 'rejected Notify call', { resource = GetInvokingResource() or 'toxic_ipad', problem = errors[1] })
        return false, 'bad_request'
    end

    local recs = targets.resolve(target)
    if #recs == 0 then return false, 'no_device' end

    local priority = notifications.PRIORITY[data.priority or 'normal']
    for _, rec in ipairs(recs) do
        local id = storage.insert(rec.id, data.app, data.title, data.message, priority, data.route, KEEP_PER_DEVICE)
        local payload = toClient({
            id = id, app_id = data.app, title = data.title, message = data.message,
            priority = priority, route = data.route, is_read = 0, created_at = os.time(),
        })
        for _, s in ipairs(targets.sessions(rec)) do
            local shown = mustRedact(s) and notifications.redact(payload, rec.settings.notifications.showPreviews == true) or payload
            TriggerClientEvent('toxic_ipad:client:notify', s.src, shown)
        end
    end
    return true
end

---Callback handlers (registered through the guard in server/main.lua).
---@param s IpadSession
---@param payload { ids: integer[]? }
---@return table
function notifications.markRead(s, payload)
    storage.markRead(s.device.id, payload.ids)
    return { ok = true }
end

---@param s IpadSession
---@param payload { id: integer? }
---@return table
function notifications.clear(s, payload)
    storage.delete(s.device.id, payload.id)
    return { ok = true }
end

return notifications
