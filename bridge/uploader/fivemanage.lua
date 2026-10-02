---Fivemanage presigned uploads (https://docs.fivemanage.com/guides/uploading-files/presigned-urls).
---
---  1. server: GET https://api.fivemanage.com/api/v3/file/presigned-url
---             header  Authorization: <token>
---             → { data = { presignedUrl = '…' }, status = 'ok' }
---  2. client: screenshot-basic POSTs the image as multipart field `file`
---             to presignedUrl → { data = { id = '…', url = 'https://r2.fivemanage.com/…' }, status = 'ok' }
---
---The token is set in config/server.lua (uploader.fivemanage.token) or the
---server convar `toxic_ipad:fivemanage_token`. config/server.lua is a
---server-only file (never listed in fxmanifest `files`), so clients never
---receive it.

local adapter = { name = 'fivemanage' }

local ENDPOINT = 'https://api.fivemanage.com/api/v3/file/presigned-url'
local TOKEN_CONVAR = 'toxic_ipad:fivemanage_token'

local cfg

---The API token: config/server.lua uploader.fivemanage.token, or the
---server convar (it wins when set, e.g. to keep the token out of files).
---Both live only on the server — config/server.lua is never sent to clients.
---@return string
local function token()
    local fromConvar = GetConvar(TOKEN_CONVAR, '')
    if fromConvar ~= '' then return fromConvar end
    return cfg and type(cfg.token) == 'string' and cfg.token or ''
end
local TIMEOUT_MS = 10000

---@param config table config/server.lua uploader.fivemanage
---@return boolean ok
---@return string? problem
function adapter.init(config)
    cfg = config
    adapter.hosts = config.hosts or { 'r2.fivemanage.com' }
    if token() == '' then
        return false, 'Camera is off: put your Fivemanage API token in config/server.lua  uploader.fivemanage.token  (see docs/INSTALLATION.md)'
    end
    return true
end

---A one-time upload target. Yields (HTTP request).
---@return { url: string, field: string, urlPath: string }? target
---@return string? err
function adapter.target()
    local apiToken = token()
    if apiToken == '' then return nil, 'no token' end

    local p = promise.new()
    local settled = false
    PerformHttpRequest(ENDPOINT, function(status, body)
        if settled then return end
        settled = true
        p:resolve({ status = status, body = body })
    end, 'GET', '', { Authorization = apiToken })
    SetTimeout(TIMEOUT_MS, function()
        if settled then return end
        settled = true
        p:resolve({ status = 0 })
    end)

    local res = Citizen.Await(p)
    if res.status ~= 200 or type(res.body) ~= 'string' then
        return nil, ('presigned-url request failed (HTTP %s)'):format(tostring(res.status))
    end
    local ok, decoded = pcall(json.decode, res.body)
    local url = ok and type(decoded) == 'table' and type(decoded.data) == 'table' and decoded.data.presignedUrl
    if type(url) ~= 'string' or not url:match('^https://') or #url > 2048 then
        return nil, 'presigned-url response had no presignedUrl'
    end
    return { url = url, field = 'file', urlPath = 'data.url' }
end

-- Server capture ------------------------------------------------------------
-- With the `screencapture` resource (Fivemanage's replacement for
-- screenshot-basic) the SERVER asks for the player's frame
--   exports.screencapture:serverCapture(source, { encoding, quality, maxWidth, maxHeight }, cb)
-- (screencapture README) and uploads it itself to the Fivemanage base64
-- endpoint (docs.fivemanage.com › Upload File (Base64)):
--   POST https://api.fivemanage.com/api/v3/file/base64
--        Authorization: <token>   { base64 = 'data:image/webp;base64,…', filename }
--   → { status = 'ok', data = { id, url, originalUrl } }
-- The upload runs through PerformHttpRequest, so this resource sees every
-- HTTP status, retries a failed attempt and never waits on a callback that
-- screencapture does not call when its own upload fails. No upload address
-- ever reaches a client.

local BASE64_URL = 'https://api.fivemanage.com/api/v3/file/base64'
local CAPTURE_TIMEOUT_MS = 15000
local UPLOAD_TIMEOUT_MS = 20000
local UPLOAD_ATTEMPTS = 2
local ENCODINGS = { webp = 'webp', jpg = 'jpg', png = 'png' }

---@return boolean
function adapter.serverCaptureReady()
    return (cfg == nil or cfg.serverCapture ~= false)
        and GetResourceState('screencapture') == 'started'
        and token() ~= ''
end

---@return string encoding  'webp' (default) · 'jpg' · 'png'
function adapter.encoding()
    return cfg and ENCODINGS[cfg.encoding] or 'webp'
end

---Asks screencapture for the player's frame. Yields.
---@param src integer
---@return string? dataUri
---@return string? err
local function captureFrame(src)
    local p = promise.new()
    local settled = false
    local function finish(value)
        if settled then return end
        settled = true
        p:resolve(value)
    end
    local encoding = adapter.encoding()
    local ok, err = pcall(function()
        exports.screencapture:serverCapture(src, {
            -- screencapture hands the encoding to the canvas as image/<encoding>:
            -- 'jpeg' is the valid type there (image/jpg silently becomes a PNG)
            encoding = encoding == 'jpg' and 'jpeg' or encoding,
            quality = cfg and tonumber(cfg.quality) or 0.8,
            maxWidth = cfg and cfg.maxWidth or 1280,
            maxHeight = cfg and cfg.maxHeight or 720,
        }, function(data) finish({ data = data }) end)
    end)
    if not ok then return nil, ('screencapture:serverCapture failed: %s'):format(tostring(err)) end
    SetTimeout(CAPTURE_TIMEOUT_MS, function() finish({ timeout = true }) end)

    local res = Citizen.Await(p)
    if res.timeout then return nil, 'no frame from the player within 15 s (screencapture)' end
    local data = res.data
    if type(data) ~= 'string' or not data:find('^data:image/[%w.+-]+;base64,') then
        return nil, ('screencapture returned no image (%s)'):format(type(data))
    end
    return data
end

---One POST to the base64 endpoint. Yields.
---@return integer status
---@return string? body
local function post(apiToken, body)
    local p = promise.new()
    local settled = false
    PerformHttpRequest(BASE64_URL, function(status, response)
        if settled then return end
        settled = true
        p:resolve({ status = status, body = response })
    end, 'POST', body, { Authorization = apiToken, ['Content-Type'] = 'application/json' })
    SetTimeout(UPLOAD_TIMEOUT_MS, function()
        if settled then return end
        settled = true
        p:resolve({ status = 0 })
    end)
    local res = Citizen.Await(p)
    return tonumber(res.status) or 0, res.body
end

---Captures `src`'s screen and uploads it. Yields.
---@param src integer
---@param opts { filename: string?, onCaptured: fun()? }
---@return string? url
---@return string? err
---@return string? originalUrl  default storage address (when a custom CDN domain is set)
function adapter.serverCapture(src, opts)
    local apiToken = token()
    if apiToken == '' then return nil, 'no token' end

    local data, captureErr = captureFrame(src)
    if not data then return nil, captureErr end
    -- the frame is on the server: the player may move on while it uploads
    if opts and opts.onCaptured then pcall(opts.onCaptured) end

    local ext = data:match('^data:image/([%w]+)') or adapter.encoding()
    if ext == 'jpeg' then ext = 'jpg' end
    local body = json.encode({
        base64 = data,
        filename = ('%s.%s'):format(opts and opts.filename or 'ipad', ext),
    })
    data = nil

    local lastErr
    for attempt = 1, UPLOAD_ATTEMPTS do
        local status, response = post(apiToken, body)
        if status >= 200 and status < 300 then
            local okDecode, decoded = pcall(json.decode, response or '')
            local url = okDecode and type(decoded) == 'table' and type(decoded.data) == 'table' and decoded.data.url
            if type(url) == 'string' then
                local original = decoded.data.originalUrl
                return url, nil, type(original) == 'string' and original or nil
            end
            return nil, ('unexpected Fivemanage answer: %s'):format(tostring(response):sub(1, 200))
        end
        lastErr = status == 0 and 'no answer from Fivemanage within 20 s'
            or ('Fivemanage answered HTTP %d: %s'):format(status, tostring(response or ''):sub(1, 200))
        -- a wrong token or a rejected file will not get better on retry
        if status == 400 or status == 401 or status == 403 or status == 413 then break end
        if attempt < UPLOAD_ATTEMPTS then Wait(750) end
    end
    return nil, lastErr
end

return adapter
