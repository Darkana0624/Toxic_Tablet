---Console logging for toxic_ipad:  [toxic_ipad] [warn] [module] message key=value
---Security events can also go to a Discord webhook from the convar
---`toxic_ipad:webhook` (never from config files).

local LEVELS = { debug = 1, info = 2, warn = 3, security = 3, error = 4 }
local COLORS = { debug = '^5', info = '^2', warn = '^3', security = '^6', error = '^1' }

local log = {}

local threshold = LEVELS.info
local webhook = ''

---@param value any
---@return string
local function formatValue(value)
    local text = tostring(value)
    if type(value) == 'string' and (text == '' or text:find('[%s="]')) then
        return ('"%s"'):format((text:gsub('"', '\\"')))
    end
    return text
end

---@param level string
---@param module string
---@param message string
---@param fields? table
---@return string
function log.format(level, module, message, fields)
    local parts = { ('[toxic_ipad] [%s] [%s] %s'):format(level, module, message) }
    if fields then
        local keys = {}
        for key in pairs(fields) do keys[#keys + 1] = tostring(key) end
        table.sort(keys)
        for _, key in ipairs(keys) do
            parts[#parts + 1] = ('%s=%s'):format(key, formatValue(fields[key]))
        end
    end
    return table.concat(parts, ' ')
end

---@param level string 'debug'|'info'|'warn'|'error'
function log.init(level)
    if GetConvar('toxic_ipad:debug', 'false') == 'true' then level = 'debug' end
    threshold = LEVELS[level] or LEVELS.info
    webhook = GetConvar('toxic_ipad:webhook', '')
end

---@param level string
---@param module string
---@param message string
---@param fields? table
local function emit(level, module, message, fields)
    if LEVELS[level] < threshold then return end
    print(COLORS[level] .. log.format(level, module, message, fields) .. '^7')

    if level == 'security' and webhook ~= '' then
        PerformHttpRequest(webhook, function() end, 'POST', json.encode({
            username = 'toxic_ipad',
            embeds = { { title = module, description = log.format(level, module, message, fields):sub(1, 3900), color = 0xb14aed } },
        }), { ['Content-Type'] = 'application/json' })
    end
end

function log.debug(module, message, fields) emit('debug', module, message, fields) end
function log.info(module, message, fields) emit('info', module, message, fields) end
function log.warn(module, message, fields) emit('warn', module, message, fields) end
function log.security(module, message, fields) emit('security', module, message, fields) end
function log.error(module, message, fields) emit('error', module, message, fields) end

return log
