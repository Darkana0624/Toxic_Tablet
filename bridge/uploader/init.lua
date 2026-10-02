---Photo uploader adapters (docs/PHASE2.md §2.1). Server side.
---Only files in bridge/uploader/ may name an upload provider.
---
---An adapter answers two questions:
---  target()  → where ONE screenshot may be uploaded (a one-time URL from the
---              provider, or the owner's own endpoint) + how to read the
---              final file URL from the upload response
---  hosts     → the hosts a stored photo URL may point at (allow-list)
---
---Upload secrets never reach a client: the Fivemanage token is read from a
---server convar and only used here to ask for a presigned URL.

local selector = {}

local ADAPTERS = {
    fivemanage = 'bridge.uploader.fivemanage',
    custom = 'bridge.uploader.custom',
}

---@param cfg table config/server.lua `uploader`
---@return table? adapter  nil when photos are turned off ('none')
---@return string? problem  why the configured adapter cannot work
function selector.select(cfg)
    local provider = cfg and cfg.provider or 'none'
    if provider == 'none' then return nil end
    local path = ADAPTERS[provider]
    if not path then
        return nil, ('config/server.lua uploader.provider "%s" is unknown (fivemanage | custom | none)'):format(tostring(provider))
    end
    local adapter = require(path)
    local ok, problem = adapter.init(cfg[provider] or {})
    if not ok then return nil, problem end
    return adapter
end

return selector
