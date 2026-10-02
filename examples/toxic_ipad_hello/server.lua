---toxic_ipad_hello — server side of the App SDK example (docs/APP_SDK.md).

local APP_ID = 'hello_demo'
local RESOURCE = GetCurrentResourceName()

local function register()
    exports.toxic_ipad:RegisterApp({
        id = APP_ID,
        name = { en = 'Hello', mn = 'Сайн уу' },
        description = {
            en = 'The App SDK example: storage, dialogs, a permission, a notification and a widget.',
            mn = 'App SDK-ийн жишээ: санах ой, цонх, зөвшөөрөл, мэдэгдэл болон виджет.',
        },
        developer = 'Toxic Scripts',
        version = '1.0.0',
        category = 'other',
        icon = ('nui://%s/web/icon.svg'):format(RESOURCE),
        ui = ('nui://%s/web/index.html'):format(RESOURCE),
        install = 'store',            -- players get it from the App Store
        permissions = { 'location', 'photos' },
        storage = { quotaKB = 64 },
    })
    exports.toxic_ipad:RegisterWidget({
        id = 'hello_taps',
        name = { en = 'Hello', mn = 'Сайн уу' },
        ui = ('nui://%s/web/widget.html'):format(RESOURCE),
        sizes = { 'small' },
        app = APP_ID,                 -- the widget appears once the app is installed
    })
end

-- toxic_ipad may start before or after us; both cases register once each.
CreateThread(function()
    if GetResourceState('toxic_ipad') == 'started' then register() end
end)
AddEventHandler('onResourceStart', function(resource)
    if resource == 'toxic_ipad' then register() end
end)

-- The app asks "where am I?". Only the server decides whether the tablet
-- granted this app the location permission.
lib.callback.register('toxic_ipad_hello:canLocate', function(src)
    return exports.toxic_ipad:HasPermission(src, APP_ID, 'location')
end)

-- Notifications can only come from server code (never from the iframe).
local last = {}
RegisterNetEvent('toxic_ipad_hello:notifyMe', function()
    local src = source
    local now = os.time()
    if last[src] and now - last[src] < 5 then return end -- a tiny rate limit
    last[src] = now
    exports.toxic_ipad:Notify(src, {
        app = APP_ID,
        title = 'Hello',
        message = 'This notification was sent by toxic_ipad_hello on the server.',
        route = '/from-notification',
    })
end)

-- The app tells us its tap count; the widget on the home screen shows it
-- live (exports.toxic_ipad:UpdateWidget → ipad.on('data') in widget.html).
-- The number comes from a client: it is only ever displayed, never trusted.
local lastTap = {}
RegisterNetEvent('toxic_ipad_hello:tapped', function(count)
    local src = source
    local now = GetGameTimer()
    if lastTap[src] and now - lastTap[src] < 250 then return end
    lastTap[src] = now
    count = math.tointeger(count)
    if not count or count < 0 or count > 1e9 then return end
    exports.toxic_ipad:UpdateWidget(src, 'hello_taps', { taps = count })
end)

AddEventHandler('playerDropped', function()
    last[source] = nil
    lastTap[source] = nil
end)
