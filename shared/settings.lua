---The per-device settings document (docs/DATABASE.md §3): defaults, schema,
---versioned upgrade and validated partial updates. Pure module.

local validate = require 'shared.validate'

local settings = {}

settings.VERSION = 1

-- App ids, widget ids and home-screen folder ids ('folder_<n>') share one shape.
local APP_ID = { type = 'string', minLength = 3, maxLength = 32, pattern = '[a-z0-9_]+' }

---Schema of the full document. Every leaf has a default in `settings.defaults`.
settings.schema = {
    type = 'table',
    fields = {
        v = { type = 'integer', min = 1, max = 1000 },
        appearance = {
            type = 'table',
            fields = {
                theme = { type = 'string', enum = { 'light', 'dark', 'auto' } },
                wallpaper = { type = 'string', maxLength = 32, pattern = '[a-z0-9_]+' },
                textScale = { type = 'number', enum = { 0.9, 1, 1.15 } },
                reducedMotion = { type = 'boolean' },
                highContrast = { type = 'boolean' },
            },
        },
        display = {
            type = 'table',
            fields = {
                brightness = { type = 'number', min = 0.3, max = 1 },
                autoLockSeconds = { type = 'integer', enum = { 30, 60, 120, 300, 0 } },
                orientation = { type = 'string', enum = { 'landscape', 'portrait' } },
                orientationLock = { type = 'boolean' },
            },
        },
        sound = {
            type = 'table',
            fields = {
                volume = { type = 'number', min = 0, max = 1 },
                enabled = { type = 'boolean' },
            },
        },
        notifications = {
            type = 'table',
            fields = {
                showPreviews = { type = 'boolean' },
                dnd = { type = 'boolean' },
                perApp = {
                    type = 'map', max = 64, keys = APP_ID,
                    values = { type = 'table', fields = { allow = { type = 'boolean' } } },
                },
            },
        },
        battery = {
            type = 'table',
            fields = {
                lowPower = { type = 'boolean' },
                showPercent = { type = 'boolean' },
            },
        },
        clock = {
            type = 'table',
            fields = {
                use24h = { type = 'boolean' },
            },
        },
        layout = {
            type = 'table',
            fields = {
                pages = { type = 'array', max = 8, items = { type = 'array', max = 24, items = APP_ID } },
                dock = { type = 'array', max = 6, items = APP_ID },
                folders = {
                    type = 'map', max = 32,
                    keys = { type = 'string', maxLength = 16, pattern = 'folder_[0-9]+' },
                    values = {
                        type = 'table',
                        fields = {
                            name = { type = 'string', minLength = 1, maxLength = 48 },
                            apps = { type = 'array', max = 16, items = APP_ID },
                        },
                    },
                },
                recents = { type = 'array', max = 12, items = APP_ID },
                widgets = {
                    type = 'array', max = 8,
                    items = {
                        type = 'table',
                        fields = {
                            id = APP_ID,
                            size = { type = 'string', enum = { 'small', 'medium' } },
                        },
                    },
                },
            },
        },
    },
}

---@param use24h boolean
---@return table
function settings.defaults(use24h)
    return {
        v = settings.VERSION,
        appearance = { theme = 'auto', wallpaper = 'aurora', textScale = 1, reducedMotion = false, highContrast = false },
        display = { brightness = 1, autoLockSeconds = 120, orientation = 'landscape', orientationLock = false },
        sound = { volume = 0.6, enabled = true },
        notifications = { showPreviews = true, dnd = false, perApp = {} },
        battery = { lowPower = false, showPercent = true },
        clock = { use24h = use24h ~= false },
        layout = {
            pages = {}, dock = {}, folders = {}, recents = {},
            widgets = { { id = 'clock', size = 'medium' }, { id = 'battery', size = 'small' } },
        },
    }
end

---Turns a schema into the same schema with every field optional, for patches.
---Maps/arrays are replaced as a whole by a patch, so their inner schema is kept.
---@param schema table
---@return table
local function optionalCopy(schema)
    local copy = {}
    for key, value in pairs(schema) do copy[key] = value end
    copy.optional = true
    if schema.type == 'table' and schema.fields then
        copy.fields = {}
        for key, field in pairs(schema.fields) do
            copy.fields[key] = optionalCopy(field)
        end
    end
    return copy
end

settings.patchSchema = optionalCopy(settings.schema)
settings.patchSchema.optional = false
settings.patchSchema.fields.v = nil

---@param target table
---@param source table
---@param schema table
local function merge(target, source, schema)
    for key, value in pairs(source) do
        local field = schema.fields and schema.fields[key]
        if field and field.type == 'table' and field.fields and type(value) == 'table' and type(target[key]) == 'table' then
            merge(target[key], value, field)
        else
            target[key] = value
        end
    end
end

---Fills keys missing from a stored document with defaults (a document saved
---by an older version keeps its values and gains new keys).
---@param doc table
---@param defaults table
---@param schema table
local function fill(doc, defaults, schema)
    for key, value in pairs(defaults) do
        local field = schema.fields and schema.fields[key]
        if doc[key] == nil then
            doc[key] = value
        elseif field and field.type == 'table' and field.fields and type(doc[key]) == 'table' then
            fill(doc[key], value, field)
        end
    end
end

---Drops keys the schema does not know (a newer/tampered document).
---@param doc table
---@param schema table
local function prune(doc, schema)
    if not schema.fields then return end
    for key, value in pairs(doc) do
        local field = schema.fields[key]
        if not field then
            doc[key] = nil
        elseif field.type == 'table' and field.fields and type(value) == 'table' then
            prune(value, field)
        end
    end
end

---Loads a stored document (decoded JSON or nil). Never fails: anything
---invalid is replaced by defaults, field by field.
---@param stored table?
---@param use24h boolean
---@return table doc
---@return boolean changed  true when the stored document had to be repaired
function settings.load(stored, use24h)
    local defaults = settings.defaults(use24h)
    if type(stored) ~= 'table' then return defaults, true end

    prune(stored, settings.schema)
    fill(stored, defaults, settings.schema)
    stored.v = settings.VERSION

    local ok = validate.schema(stored, settings.schema, 'settings')
    if ok then return stored, false end

    -- Repair field by field: keep every top-level section that validates.
    local repaired = settings.defaults(use24h)
    for key, field in pairs(settings.schema.fields) do
        if stored[key] ~= nil and validate.schema(stored[key], field, key) then
            repaired[key] = stored[key]
        end
    end
    return repaired, true
end

---Applies a client patch. The document is only changed when the whole patch
---is valid.
---@param doc table
---@param patch unknown
---@return boolean ok
---@return string[]? errors
function settings.apply(doc, patch)
    local ok, errors = validate.schema(patch, settings.patchSchema, 'patch')
    if not ok then return false, errors end
    merge(doc, patch --[[@as table]], settings.schema)
    return true
end

return settings
