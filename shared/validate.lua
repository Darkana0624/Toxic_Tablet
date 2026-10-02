---Pure value and schema validation (adapted from toxic_core). Used for config
---validation at boot and for every client payload at the guard. No FiveM natives, so it also
---loads in the offline unit-test runner.

local validate = {}

---@param value unknown
---@return boolean
function validate.isFiniteNumber(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

---@param value unknown
---@return boolean
function validate.isInteger(value)
    return math.type(value) == 'integer'
        or (validate.isFiniteNumber(value) and math.floor(value) == value and math.abs(value) < 2 ^ 53)
end

---@alias ToxicSchemaType 'any'|'table'|'array'|'map'|'number'|'integer'|'string'|'boolean'|'function'

---@class ToxicSchema
---@field type ToxicSchemaType
---@field optional? boolean         value may be nil
---@field min? number               number/integer lower bound (inclusive); array/map minimum size
---@field max? number               number/integer upper bound (inclusive); array/map maximum size
---@field minLength? integer        string
---@field maxLength? integer        string
---@field pattern? string           string, Lua pattern that must match the whole value
---@field enum? any[]               allowed values
---@field fields? table<string, ToxicSchema>  table: known keys
---@field strict? boolean           table: reject keys not in `fields` (default true)
---@field items? ToxicSchema        array: schema of each item
---@field keys? ToxicSchema         map: schema of each key
---@field values? ToxicSchema       map: schema of each value
---@field check? fun(value: any): boolean, string?  extra rule after the type checks

local function describe(value)
    local kind = type(value)
    if kind == 'string' then
        return ('"%s"'):format(#value > 40 and value:sub(1, 40) .. '…' or value)
    elseif kind == 'number' or kind == 'boolean' or kind == 'nil' then
        return tostring(value)
    end
    return kind
end

local function inEnum(value, enum)
    for i = 1, #enum do
        if enum[i] == value then return true end
    end
    return false
end

local function isArray(tbl)
    local count = 0
    for key in pairs(tbl) do
        if math.type(key) ~= 'integer' or key < 1 then return false end
        count = count + 1
    end
    for i = 1, count do
        if tbl[i] == nil then return false end
    end
    return true, count
end

local check

---@param value any
---@param schema ToxicSchema
---@param path string
---@param errors string[]
check = function(value, schema, path, errors)
    local function fail(message)
        errors[#errors + 1] = ('%s: %s'):format(path, message)
    end

    if value == nil then
        if not schema.optional then fail('is required') end
        return
    end

    local kind = schema.type

    if kind == 'any' then
        -- accepted as-is; enum/check below may still restrict it
    elseif kind == 'number' or kind == 'integer' then
        if not validate.isFiniteNumber(value) then
            return fail(('expected %s, got %s'):format(kind, describe(value)))
        end
        if kind == 'integer' and not validate.isInteger(value) then
            return fail(('expected integer, got %s'):format(describe(value)))
        end
        if schema.min and value < schema.min then return fail(('must be ≥ %s, got %s'):format(schema.min, value)) end
        if schema.max and value > schema.max then return fail(('must be ≤ %s, got %s'):format(schema.max, value)) end
    elseif kind == 'string' then
        if type(value) ~= 'string' then
            return fail(('expected string, got %s'):format(describe(value)))
        end
        if schema.minLength and #value < schema.minLength then
            return fail(('must be at least %d characters'):format(schema.minLength))
        end
        if schema.maxLength and #value > schema.maxLength then
            return fail(('must be at most %d characters'):format(schema.maxLength))
        end
        if schema.pattern and not value:match('^' .. schema.pattern .. '$') then
            return fail(('has an invalid format: %s'):format(describe(value)))
        end
    elseif kind == 'boolean' or kind == 'function' then
        if type(value) ~= kind then
            return fail(('expected %s, got %s'):format(kind, describe(value)))
        end
    elseif kind == 'table' then
        if type(value) ~= 'table' then
            return fail(('expected table, got %s'):format(describe(value)))
        end
        local fields = schema.fields or {}
        for key, fieldSchema in pairs(fields) do
            check(value[key], fieldSchema, ('%s.%s'):format(path, key), errors)
        end
        if schema.strict ~= false then
            for key in pairs(value) do
                if fields[key] == nil then
                    fail(('unknown key %s'):format(describe(key)))
                end
            end
        end
    elseif kind == 'array' then
        if type(value) ~= 'table' then
            return fail(('expected array, got %s'):format(describe(value)))
        end
        local ok, count = isArray(value)
        if not ok then return fail('expected an array (keys 1..n with no gaps)') end
        if schema.min and count < schema.min then return fail(('needs at least %d entries'):format(schema.min)) end
        if schema.max and count > schema.max then return fail(('allows at most %d entries'):format(schema.max)) end
        if schema.items then
            for i = 1, count do
                check(value[i], schema.items, ('%s[%d]'):format(path, i), errors)
            end
        end
    elseif kind == 'map' then
        if type(value) ~= 'table' then
            return fail(('expected table, got %s'):format(describe(value)))
        end
        local count = 0
        for key, item in pairs(value) do
            count = count + 1
            local keyPath = ('%s[%s]'):format(path, describe(key))
            if schema.keys then check(key, schema.keys, keyPath .. ' (key)', errors) end
            if schema.values then check(item, schema.values, keyPath, errors) end
        end
        if schema.min and count < schema.min then return fail(('needs at least %d entries'):format(schema.min)) end
        if schema.max and count > schema.max then return fail(('allows at most %d entries'):format(schema.max)) end
    else
        return fail(('schema error: unknown type %s'):format(describe(kind)))
    end

    if schema.enum and not inEnum(value, schema.enum) then
        local names = {}
        for i = 1, #schema.enum do names[i] = tostring(schema.enum[i]) end
        return fail(('must be one of: %s'):format(table.concat(names, ', ')))
    end

    if schema.check then
        local ok, message = schema.check(value)
        if not ok then fail(message or 'is invalid') end
    end
end

---Validates a value against a schema.
---@param value any
---@param schema ToxicSchema
---@param rootName? string path prefix used in error messages
---@return boolean ok
---@return string[] errors every problem found, not just the first
function validate.schema(value, schema, rootName)
    local errors = {}
    check(value, schema, rootName or 'value', errors)
    return #errors == 0, errors
end

return validate
