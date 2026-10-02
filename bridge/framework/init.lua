---Selects the framework adapter once at boot (docs/ARCHITECTURE.md §6.1).
---Detection order for 'auto': toxic_core (API v1) → qbx_core.

local ADAPTERS = {
    toxic_core = 'bridge.framework.toxic_core',
    qbox = 'bridge.framework.qbox',
}

local ORDER = { 'toxic_core', 'qbox' }

local framework = {}

---@param wanted string  'auto' | 'toxic_core' | 'qbox'
---@return table? adapter
---@return string? err
function framework.select(wanted)
    if wanted ~= 'auto' then
        local path = ADAPTERS[wanted]
        if not path then
            return nil, ('config/shared.lua framework = "%s" is not supported. Use "auto", "qbox" or "toxic_core".'):format(tostring(wanted))
        end
        local adapter = require(path)
        if not adapter.available() then
            return nil, ('framework "%s" was selected in config/shared.lua but %s is not started (or its API is not available).'):format(wanted, adapter.resource)
        end
        return adapter
    end

    for _, name in ipairs(ORDER) do
        local adapter = require(ADAPTERS[name])
        if adapter.available() then return adapter end
    end

    return nil, 'no supported framework is running. Start qbx_core (or toxic_core with API v1) before toxic_ipad.'
end

return framework
