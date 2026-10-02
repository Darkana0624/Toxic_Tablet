---Camera & Photos (docs/PHASE2.md §2). A photo is a URL on the uploader
---(Fivemanage or the owner's endpoint) plus a row; the tablet never holds
---image data.
---
---Taking a photo:
---  1. photos:ticket  — the server hands out ONE upload target for this
---                      player (rate + per-minute limit + photo count)
---  2. the client uploads the screenshot there (screenshot-basic)
---  3. photos:save    — the ticket must be this player's, unused, < 60 s
---                      old, for the same tablet; the URL must be https on
---                      an allowed host. Only then a row is written.
---
---Pure apart from the injected dependencies (storage, uploader, files,
---clock), so the offline tests drive it with fakes.

local photos = {}

photos.TICKET_SECONDS = 60
photos.PAGE = 60              -- photos per list request
photos.MAX_URL = 255
photos.MAX_LOCATION = 80

local storage, uploader, files, cfg, withLock
local now = os.time
local random = math.random

---@type table<integer, { id: string, deviceId: integer, selfie: boolean, at: integer }>
local tickets = {}

---@param deps { storage: table, uploader: table?, files: table, config: table, now: fun(): integer?, random: fun(a: integer, b: integer): integer?, withLock: function? }
function photos.init(deps)
    storage, uploader, files, cfg = deps.storage, deps.uploader, deps.files, deps.config
    -- runs fn under the device's request lock (server/device.lua); tests pass none
    withLock = deps.withLock or function(_, fn) return true, fn() end
    now = deps.now or os.time
    random = deps.random or math.random
    tickets = {}
end

---@return boolean
function photos.uploaderReady()
    return uploader ~= nil
end

---@param src integer
function photos.forget(src)
    tickets[src] = nil
end

---Drops every open ticket of a device (it was erased).
---@param deviceId integer
function photos.forgetDevice(deviceId)
    for src, ticket in pairs(tickets) do
        if ticket.deviceId == deviceId then tickets[src] = nil end
    end
end

-- pure checks --------------------------------------------------------------

---Accepts only https URLs on an allowed host with plain path characters.
---@param url any
---@param hosts string[]
---@return boolean
function photos.checkUrl(url, hosts)
    if type(url) ~= 'string' or #url > photos.MAX_URL then return false end
    local host, rest = url:match('^https://([%w%.%-]+)(/.*)$')
    if not host then return false end
    if not rest:match('^/[%w%-%._~/%%]*$') and not rest:match('^/[%w%-%._~/%%]*%?[%w%-%._~=&%%]*$') then return false end
    host = host:lower()
    for _, allowed in ipairs(hosts or {}) do
        if host == allowed:lower() then return true end
    end
    return false
end

---A street name from the client: printable, bounded, or nil.
---@param value any
---@return string?
function photos.cleanLocation(value)
    if type(value) ~= 'string' or not utf8.len(value) then return nil end
    value = value:gsub('%c', ''):gsub('[<>]', ''):gsub('^%s+', ''):gsub('%s+$', '')
    if value == '' then return nil end
    if utf8.len(value) > photos.MAX_LOCATION then
        value = value:sub(1, utf8.offset(value, photos.MAX_LOCATION + 1) - 1)
    end
    return value
end

-- helpers ----------------------------------------------------------------------

local int = function(v) return math.tointeger(tonumber(v)) or 0 end

---@param row table
---@return table
local function toClient(row)
    return {
        id = int(row.id),
        url = row.url,
        selfie = row.selfie == 1 or row.selfie == true,
        favorite = row.favorite == 1 or row.favorite == true,
        size = int(row.size_bytes),
        location = row.location,
        time = int(row.created_at),
    }
end
photos.toClient = toClient

---@param rec table
---@return integer count
---@return integer bytes
local function usage(rec)
    if not rec.photoUsage then
        local count, bytes = storage.usage(rec.id)
        -- another request may have filled it while this query waited
        if not rec.photoUsage then rec.photoUsage = { count = count, bytes = bytes } end
    end
    return rec.photoUsage.count, rec.photoUsage.bytes
end
photos.usage = usage

---@return string
local function ticketId()
    local out = {}
    for i = 1, 24 do out[i] = ('%x'):format(random(0, 15)) end
    return table.concat(out)
end

-- callback handlers ---------------------------------------------------------------

---Tickets issued in the last `window` seconds (drops older stamps).
---@param stamps integer[]
---@param t integer
---@param window integer
---@return integer
local function recent(stamps, t, window)
    local n = 0
    for i = #stamps, 1, -1 do
        if t - stamps[i] < window then n = n + 1 end
    end
    return n
end

---@param s table IpadSession
---@param payload { selfie: boolean? }
---@return table
function photos.ticket(s, payload)
    if not uploader then return { ok = false, err = 'camera_unavailable' } end
    local rec = s.device
    local limits = cfg.server.photos

    local count, bytes = usage(rec)
    if count >= limits.maxPerDevice then return { ok = false, err = 'photos_full' } end
    local _, fileBytes = files.usage(rec)
    if bytes + fileBytes + limits.sizeKB * 1024 > rec.capacityMb * 1024 * 1024 then return { ok = false, err = 'storage_full' } end

    -- Every ticket is an upload the server owner pays for, used or not:
    -- per minute and per hour, per tablet. The stamp is taken BEFORE the
    -- HTTP request yields, so parallel requests cannot all pass the check.
    local t = now()
    local stamps = rec.photoStamps or {}
    for i = #stamps, 1, -1 do
        if t - stamps[i] >= 3600 then table.remove(stamps, i) end
    end
    rec.photoStamps = stamps
    if recent(stamps, t, 60) >= limits.perMinute or #stamps >= (limits.perHour or 60) then
        return { ok = false, err = 'rate_limited' }
    end
    stamps[#stamps + 1] = t

    -- Server capture (screencapture + Fivemanage): the server takes the
    -- screenshot and uploads it itself; no upload address reaches the client.
    local server = uploader.serverCapture ~= nil and uploader.serverCaptureReady ~= nil and uploader.serverCaptureReady()
    local target, err
    if server then
        target = { server = true }
    else
        target, err = uploader.target()
    end
    if not target then
        -- no upload happened: give the slot back
        for i = #stamps, 1, -1 do
            if stamps[i] == t then table.remove(stamps, i) break end
        end
        print(('^1[toxic_ipad] photo upload target failed: %s^7'):format(tostring(err)))
        return { ok = false, err = 'upload_failed' }
    end

    local id = ticketId()
    tickets[s.src] = { id = id, deviceId = rec.id, selfie = payload.selfie == true, at = t, server = server }
    if server then return { ok = true, ticket = id, server = true } end
    return { ok = true, ticket = id, upload = target }
end

---Takes the one-time ticket of this player for this device (burnt either way).
---@param s table
---@param id any
---@return table? ticket
local function takeTicket(s, id)
    local ticket = tickets[s.src]
    tickets[s.src] = nil -- one use (a wrong guess burns it too), whatever happens next
    if not ticket or ticket.id ~= id then return nil end
    if ticket.deviceId ~= s.device.id or now() - ticket.at > photos.TICKET_SECONDS then return nil end
    return ticket
end

---Writes the photo row after the final limit checks.
---@param s table
---@param ticket table
---@param url string
---@param location any
---@return table
local function store(s, ticket, url, location)
    local rec = s.device
    local count, bytes = usage(rec)
    if count >= cfg.server.photos.maxPerDevice then return { ok = false, err = 'photos_full' } end
    local size = cfg.server.photos.sizeKB * 1024
    local _, fileBytes = files.usage(rec)
    if bytes + fileBytes + size > rec.capacityMb * 1024 * 1024 then return { ok = false, err = 'storage_full' } end

    location = cfg.server.photos.recordStreet and photos.cleanLocation(location) or nil
    local id = storage.insert(rec.id, { url = url, selfie = ticket.selfie, size = size, location = location })
    if not id then return { ok = false, err = 'internal' } end
    rec.photoUsage.count = count + 1
    rec.photoUsage.bytes = bytes + size
    return {
        ok = true,
        photo = toClient({ id = id, url = url, selfie = ticket.selfie, favorite = 0, size_bytes = size, location = location, created_at = now() }),
    }
end

---Server capture: the server asks the uploader to capture this player's
---screen and upload it, then stores the address the uploader returned.
---Runs without the device lock while it waits (up to ~30 s), then takes it.
---@param s table
---@param payload { ticket: string, location: string? }
---@return table
function photos.capture(s, payload)
    local ticket = takeTicket(s, payload.ticket)
    if not ticket or not ticket.server then return { ok = false, err = 'bad_ticket' } end
    if not uploader or not uploader.serverCapture then return { ok = false, err = 'camera_unavailable' } end

    local url, err, original = uploader.serverCapture(s.src, {
        filename = ('ipad_%d_%d'):format(s.device.id, now()),
        -- the frame is taken: the viewfinder comes back while the upload runs
        onCaptured = function() TriggerClientEvent('toxic_ipad:client:cameraCaptured', s.src, payload.ticket) end,
    })
    if not url then
        print(('^1[toxic_ipad] photo upload failed: %s^7'):format(tostring(err)))
        return { ok = false, err = 'upload_failed' }
    end
    -- a custom CDN domain outside `hosts`: fall back to the default storage address
    if not photos.checkUrl(url, uploader.hosts) and original and photos.checkUrl(original, uploader.hosts) then url = original end
    if not photos.checkUrl(url, uploader.hosts) then
        print(('^1[toxic_ipad] the uploader returned an address outside uploader hosts: %s^7'):format(tostring(url):sub(1, 120)))
        return { ok = false, err = 'bad_url' }
    end
    local acquired, result = withLock(s.device, function() return store(s, ticket, url, payload.location) end)
    if not acquired then return { ok = false, err = 'busy' } end
    return result
end

---@param s table
---@param payload { ticket: string, url: string, location: string? }
---@return table
function photos.save(s, payload)
    local ticket = takeTicket(s, payload.ticket)
    -- a server-capture ticket never accepts an address from the client
    if not ticket or ticket.server then return { ok = false, err = 'bad_ticket' } end
    if not uploader or not photos.checkUrl(payload.url, uploader.hosts) then return { ok = false, err = 'bad_url' } end
    return store(s, ticket, payload.url, payload.location)
end

---@param s table
---@param payload { before: integer? }
---@return table
function photos.list(s, payload)
    local rec = s.device
    local rows = storage.page(rec.id, payload.before or 9007199254740991, photos.PAGE + 1)
    local out = {}
    for i = 1, math.min(#rows, photos.PAGE) do out[i] = toClient(rows[i]) end
    local count = usage(rec)
    return { ok = true, photos = out, more = #rows > photos.PAGE, total = count }
end

---@param s table
---@param payload { id: integer }
---@return table
function photos.get(s, payload)
    local row = storage.get(s.device.id, payload.id)
    if not row then return { ok = false, err = 'not_found' } end
    return { ok = true, photo = toClient(row) }
end

---@param s table
---@param payload { ids: integer[] }
---@return table
function photos.delete(s, payload)
    local rec = s.device
    local removed, bytes = storage.delete(rec.id, payload.ids)
    if removed > 0 then
        -- "Save to Files" entries point at the photo: they go with it
        local refs = {}
        for i, id in ipairs(payload.ids) do refs[i] = ('photo:%d'):format(id) end
        files.removeRefs(rec, refs)
    end
    if rec.photoUsage then
        if bytes < 0 then
            rec.photoUsage = nil
        else
            rec.photoUsage.count = math.max(0, rec.photoUsage.count - removed)
            rec.photoUsage.bytes = math.max(0, rec.photoUsage.bytes - bytes)
        end
    end
    return { ok = true, removed = removed }
end

---@param s table
---@param payload { id: integer, favorite: boolean }
---@return table
function photos.favorite(s, payload)
    if not storage.setFavorite(s.device.id, payload.id, payload.favorite) then
        -- no row changed: missing, or already in that state
        if not storage.get(s.device.id, payload.id) then return { ok = false, err = 'not_found' } end
    end
    return { ok = true, favorite = payload.favorite }
end

local FILE_TYPES = {
    webp = { 'webp', 'image/webp' },
    png = { 'png', 'image/png' },
    jpg = { 'jpg', 'image/jpeg' },
    jpeg = { 'jpg', 'image/jpeg' },
}

---File extension and MIME type of a photo, from its address (JPEG when unknown).
---@param url string?
---@return string ext
---@return string mime
function photos.fileType(url)
    local ext = type(url) == 'string' and url:lower():match('%.(%w+)$') or nil
    local t = FILE_TYPES[ext] or FILE_TYPES.jpg
    return t[1], t[2]
end

---Photos › Share › Save to Files: a file entry that points at the photo.
---@param s table
---@param payload { id: integer }
---@return table
function photos.toFiles(s, payload)
    local row = storage.get(s.device.id, payload.id)
    if not row then return { ok = false, err = 'not_found' } end
    local ext, mime = photos.fileType(row.url)
    local entry, err = files.saveFor(s.device, {
        folder = 'Documents',
        name = ('IMG_%04d.%s'):format(int(row.id) % 10000, ext),
        mime = mime,
        sizeBytes = int(row.size_bytes),
        ref = ('photo:%d'):format(int(row.id)),
    })
    if not entry then return { ok = false, err = err } end
    return { ok = true, entry = entry }
end

-- export ------------------------------------------------------------------------

---exports.toxic_ipad:GetPhotos(target, limit) for one device.
---@param rec table
---@param limit integer
---@return table[]
function photos.recentFor(rec, limit)
    local out = {}
    for i, row in ipairs(storage.page(rec.id, 9007199254740991, limit)) do
        local p = toClient(row)
        out[i] = { id = p.id, url = p.url, selfie = p.selfie, location = p.location, time = p.time, serial = rec.serial }
    end
    return out
end

return photos
