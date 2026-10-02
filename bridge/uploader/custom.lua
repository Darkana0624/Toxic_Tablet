---Your own upload endpoint (docs/INSTALLATION.md › Camera).
---
---screenshot-basic POSTs the screenshot as multipart/form-data to `url`,
---field `field`; your endpoint answers with JSON that contains the public
---https URL of the stored image at `urlPath` (dot path, e.g. 'data.url' or
---'url'). The URL must be on one of `hosts`.
---
---The upload URL is sent to the photographer's client, so it must NOT
---contain a secret. Protect the endpoint another way (size limit, image
---type check, rate limit, or a proxy on your own server).

local adapter = { name = 'custom' }

local cfg

---@param config table config/server.lua uploader.custom
---@return boolean ok
---@return string? problem
function adapter.init(config)
    cfg = config
    if type(config.url) ~= 'string' or not config.url:match('^https?://[%w%.%-:]+/') then
        return false, 'config/server.lua uploader.custom.url must be the http(s) URL of your upload endpoint'
    end
    if type(config.hosts) ~= 'table' or #config.hosts == 0 then
        return false, 'config/server.lua uploader.custom.hosts must list the host(s) your image URLs are on'
    end
    adapter.hosts = config.hosts
    return true
end

---@return { url: string, field: string, urlPath: string }? target
---@return string? err
function adapter.target()
    return { url = cfg.url, field = cfg.field or 'file', urlPath = cfg.urlPath or 'url' }
end

return adapter
