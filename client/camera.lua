---Camera mode (docs/PHASE2.md §2.1). The tablet steps aside, a scripted
---camera takes over and the player aims with the mouse; the NUI only shows
---a small, non-interactive viewfinder overlay.
---
---A photo: server ticket → either the server captures and uploads the frame
---(screencapture) or screenshot-basic uploads it to the ticket's target →
---the server stores the returned URL. The client never
---sees an upload secret and cannot store a photo without a ticket.
---
---Costs one Wait(0) loop while the camera is active, nothing otherwise.

local camera = {}

local HEAD_BONE = 31086 -- SKEL_Head

local CONTROL = {
    lookX = 1, lookY = 2,
    shutter = 24,         -- left mouse
    shutterKey = 191,     -- Enter
    flip = 38,            -- E
    zoomIn = 241, zoomOut = 242,   -- mouse wheel
    zoomIn2 = 15, zoomOut2 = 14,   -- weapon wheel (same wheel on some keyboards)
    exit = 177,           -- Backspace / Esc / right mouse
    exitPause = 200,      -- Esc
    pushToTalk = 249,
    chat = 245,
}

local active = false
local token = 0
local cam = nil       ---@type integer?
local selfie = false
local busy = false
local yaw, pitch, fov = 0.0, 0.0, 50.0
local selfieYaw = 0.0
local hooks = nil     ---@type { send: fun(action: string, data: any), exit: fun(reason: string) }?
local cfg = nil       ---@type table

---@return boolean
function camera.isActive()
    return active
end

---@return boolean
function camera.available()
    return GetResourceState('screencapture') == 'started' or GetResourceState('screenshot-basic') == 'started'
end

---@param h number heading in degrees
---@return number x
---@return number y
local function forward(h)
    local r = math.rad(h)
    return -math.sin(r), math.cos(r)
end

local function placeCamera()
    local ped = cache.ped
    local head = GetPedBoneCoords(ped, HEAD_BONE, 0.0, 0.0, 0.0)
    if selfie then
        local h = GetEntityHeading(ped) + selfieYaw
        local fx, fy = forward(h)
        local dist = cfg.selfieDistance
        local pos = vec3(head.x + fx * dist, head.y + fy * dist, head.z + 0.04 + pitch * 0.006)
        SetCamCoord(cam, pos.x, pos.y, pos.z)
        PointCamAtCoord(cam, head.x, head.y, head.z + 0.02)
    else
        local fx, fy = forward(yaw)
        SetCamCoord(cam, head.x + fx * 0.22, head.y + fy * 0.22, head.z + 0.04)
        SetCamRot(cam, pitch, 0.0, yaw, 2)
    end
    SetCamFov(cam, fov)
end

---@param dx number
---@param dy number
local function look(dx, dy)
    local speed = cfg.sensitivity * (fov / 50.0)
    if selfie then
        selfieYaw = math.max(-40.0, math.min(40.0, selfieYaw - dx * speed))
        pitch = math.max(-25.0, math.min(25.0, pitch - dy * speed))
        return
    end
    yaw = (yaw - dx * speed) % 360.0
    pitch = math.max(-70.0, math.min(60.0, pitch - dy * speed))
    local ped = cache.ped
    if not cache.vehicle and dx ~= 0.0 then SetEntityHeading(ped, yaw) end
end

---@param value any
---@param path string dot path, e.g. 'data.url'
---@return any
local function pick(value, path)
    for key in path:gmatch('[^%.]+') do
        if type(value) ~= 'table' then return nil end
        value = value[key]
    end
    return value
end

---@return string?
local function streetName()
    local coords = GetEntityCoords(cache.ped)
    local street = GetStreetNameAtCoord(coords.x, coords.y, coords.z)
    local name = street and GetStreetNameFromHashKey(street) or nil
    return name ~= '' and name or nil
end

---@param url string
---@param field string
---@return string? body
local function upload(url, field)
    local p = promise.new()
    local settled = false
    exports['screenshot-basic']:requestScreenshotUpload(url, field, { encoding = 'webp', quality = cfg.quality }, function(body)
        if settled then return end
        settled = true
        p:resolve(body)
    end)
    SetTimeout(20000, function()
        if settled then return end
        settled = true
        p:resolve(nil)
    end)
    return Citizen.Await(p)
end

local waitingTicket = nil ---@type string?
local onCaptured = nil    ---@type fun()?

RegisterNetEvent('toxic_ipad:client:cameraCaptured', function(ticketId)
    if ticketId ~= waitingTicket or not onCaptured then return end
    onCaptured()
end)

---@param myToken integer
local function shoot(myToken)
    if busy then return end
    busy = true
    CreateThread(function()
        local current = function() return myToken == token and hooks ~= nil end
        local captureOpen = false

        ---@return string? err
        local function run()
            local ticket = lib.callback.await('toxic_ipad:server:photos:ticket', false, { selfie = selfie })
            if not current() then return nil end
            if type(ticket) ~= 'table' or not ticket.ok or (not ticket.server and type(ticket.upload) ~= 'table') then
                return type(ticket) == 'table' and ticket.err or 'internal'
            end

            -- the overlay leaves the frame; the flash plays once the frame is taken
            hooks.send('cameraCapture', { phase = 'start' })
            captureOpen = true
            Wait(60)

            -- server capture (screencapture + Fivemanage): the server takes the
            -- screenshot and uploads it; this client only waits for the result
            if ticket.server then
                -- the server says when the frame is taken (before its upload):
                -- the viewfinder comes back then, the thumbnail when it is stored
                waitingTicket = ticket.ticket
                onCaptured = function()
                    if captureOpen and current() then hooks.send('cameraCapture', { phase = 'taken' }) end
                    captureOpen = false
                end
                local result = lib.callback.await('toxic_ipad:server:photos:capture', false, {
                    ticket = ticket.ticket, location = streetName(),
                })
                waitingTicket, onCaptured = nil, nil
                if captureOpen and current() then hooks.send('cameraCapture', { phase = 'taken' }) end
                captureOpen = false
                if type(result) ~= 'table' or not result.ok then
                    return type(result) == 'table' and result.err or 'internal'
                end
                if current() then hooks.send('cameraResult', { ok = true, photo = result.photo }) end
                return nil
            end

            local body = upload(ticket.upload.url, ticket.upload.field)
            if current() then hooks.send('cameraCapture', { phase = 'taken' }) end
            captureOpen = false

            local ok, decoded = pcall(json.decode, body or '')
            local url = ok and pick(decoded, ticket.upload.urlPath or 'url') or nil
            if type(url) ~= 'string' then return 'upload_failed' end

            local result = lib.callback.await('toxic_ipad:server:photos:save', false, {
                ticket = ticket.ticket, url = url, location = streetName(),
            })
            if type(result) ~= 'table' or not result.ok then
                return type(result) == 'table' and result.err or 'internal'
            end
            if current() then hooks.send('cameraResult', { ok = true, photo = result.photo }) end
            return nil
        end

        -- whatever fails (an export gone, a callback error), the HUD comes
        -- back and the shutter works again
        local ok, err = pcall(run)
        waitingTicket, onCaptured = nil, nil
        if not ok then
            print(('^1[toxic_ipad] camera: %s^7'):format(tostring(err)))
            err = 'upload_failed'
        end
        if current() then
            if captureOpen then hooks.send('cameraCapture', { phase = 'taken' }) end
            if err then hooks.send('cameraResult', { ok = false, err = err }) end
            busy = false
        end
    end)
end

---@param myToken integer
local function loop(myToken)
    CreateThread(function()
        while active and token == myToken do
            DisableAllControlActions(0)
            EnableControlAction(0, CONTROL.pushToTalk, true)
            EnableControlAction(0, CONTROL.chat, true)
            HideHudAndRadarThisFrame()

            local dx, dy = GetDisabledControlNormal(0, CONTROL.lookX), GetDisabledControlNormal(0, CONTROL.lookY)
            if dx ~= 0.0 or dy ~= 0.0 then look(dx, dy) end

            if IsDisabledControlJustPressed(0, CONTROL.zoomIn) or IsDisabledControlJustPressed(0, CONTROL.zoomIn2) then
                fov = math.max(cfg.fovMin, fov - cfg.zoomStep)
                hooks.send('cameraZoom', { zoom = cfg.fovDefault / fov })
            elseif IsDisabledControlJustPressed(0, CONTROL.zoomOut) or IsDisabledControlJustPressed(0, CONTROL.zoomOut2) then
                fov = math.min(cfg.fovMax, fov + cfg.zoomStep)
                hooks.send('cameraZoom', { zoom = cfg.fovDefault / fov })
            end

            if IsDisabledControlJustPressed(0, CONTROL.flip) then
                selfie = not selfie
                pitch, selfieYaw = 0.0, 0.0
                yaw = GetEntityHeading(cache.ped)
                fov = cfg.fovDefault
                hooks.send('camera', { active = true, selfie = selfie, zoom = 1 })
            end

            placeCamera()

            if IsDisabledControlJustPressed(0, CONTROL.shutter) or IsDisabledControlJustPressed(0, CONTROL.shutterKey) then
                shoot(myToken)
            end

            if IsDisabledControlJustPressed(0, CONTROL.exit) or IsDisabledControlJustPressed(0, CONTROL.exitPause) then
                hooks.exit('user')
                break
            end
            Wait(0)
        end
    end)
end

---Enters camera mode. The caller already released NUI focus.
---@param config table config/client.lua `camera`
---@param opts { selfie: boolean }
---@param h { send: fun(action: string, data: any), exit: fun(reason: string) }
---@return boolean
function camera.start(config, opts, h)
    if active or not camera.available() then return false end
    cfg, hooks = config, h
    active = true
    token = token + 1
    busy = false
    selfie = opts.selfie == true
    pitch, selfieYaw = 0.0, 0.0
    fov = cfg.fovDefault
    local ped = cache.ped
    yaw = GetEntityHeading(ped)

    cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    placeCamera()
    RenderScriptCams(true, true, 250, true, false)
    hooks.send('camera', { active = true, selfie = selfie, zoom = 1 })
    loop(token)
    return true
end

---Leaves camera mode (idempotent). Does not touch NUI focus.
---@param instant? boolean no blend (the tablet is closing anyway)
function camera.stop(instant)
    if not active then return end
    active = false
    token = token + 1
    busy = false
    RenderScriptCams(false, not instant, instant and 0 or 250, true, false)
    if cam then
        DestroyCam(cam, false)
        cam = nil
    end
    if hooks then hooks.send('camera', { active = false }) end
end

return camera
