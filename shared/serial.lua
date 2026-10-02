---Device serial numbers: 'TXP-' + 10 characters from a 32-symbol alphabet
---(~1.1e15 values). Generated without the database (inside the ox_inventory
---createItem hook, where queries are not allowed), so the space is large
---enough that collisions are negligible.

local constants = require 'shared.constants'

local serial = {}

local ALPHABET = constants.SERIAL_ALPHABET

---@param random? fun(m: integer, n: integer): integer  injectable for tests
---@return string
function serial.generate(random)
    random = random or math.random
    local chars = {}
    for i = 1, constants.SERIAL_LENGTH do
        local index = random(1, #ALPHABET)
        chars[i] = ALPHABET:sub(index, index)
    end
    return 'TXP-' .. table.concat(chars)
end

---@param value unknown
---@return boolean
function serial.isValid(value)
    return type(value) == 'string'
        and #value == 4 + constants.SERIAL_LENGTH
        and value:match('^' .. constants.SERIAL_PATTERN .. '$') ~= nil
end

return serial
