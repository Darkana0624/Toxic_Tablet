---App Registry, install state, permissions and app data (docs/APP_SDK.md).
---
---Two kinds of app share one registry:
---  • built-in apps from config/apps.lua (React components inside the OS),
---  • external apps registered by other resources with
---    exports.toxic_ipad:RegisterApp(def) (an iframe of their own UI).
---
---Everything a client sees is decided here, per player and per device:
---accessible (framework groups) AND installed on that device. The client
---only ever receives the filtered lists.
---
---Pure apart from the injected dependencies (framework, storage, device,
---json), so the offline tests drive it with fakes.

local validate = require 'shared.validate'

local apps = {}

apps.PERMISSIONS = { 'location', 'camera', 'photos', 'contacts', 'microphone' }
apps.CATEGORIES = { 'social', 'communication', 'business', 'government', 'police', 'medical', 'entertainment', 'utilities', 'other' }
apps.WIDGET_SIZES = { 'small', 'medium' }

apps.MAX_VALUE_BYTES = 65536      -- one app_data value (JSON)
apps.DEFAULT_QUOTA_KB = 256
apps.MAX_EXTERNAL_APPS = 64
apps.MAX_EXTERNAL_WIDGETS = 32

local ID_PATTERN = '[a-z0-9_]+'
local RESERVED_PREFIX = 'folder_'   -- home-screen folder ids (shared/settings.lua)

-- schemas ----------------------------------------------------------------

---A display text: a plain string, or one string per language.
---@param maxLen integer
---@return fun(value: any): boolean, string?
local function textCheck(maxLen)
    return function(value)
        if type(value) == 'string' then
            if #value < 1 or #value > maxLen then return false, ('must be 1–%d characters'):format(maxLen) end
            return true
        end
        if type(value) ~= 'table' then return false, 'must be a string or a table like { en = "...", mn = "..." }' end
        local count = 0
        for lang, text in pairs(value) do
            count = count + 1
            if type(lang) ~= 'string' or not (lang:match('^%l%l$') or lang:match('^%l%l%-%u%u$')) then
                return false, 'language keys look like "en", "mn" or "pt-BR"'
            end
            if type(text) ~= 'string' or #text < 1 or #text > maxLen then
                return false, ('the "%s" text must be 1–%d characters'):format(lang, maxLen)
            end
        end
        if count == 0 or count > 16 then return false, 'needs 1–16 languages' end
        return true
    end
end

local ACCESS = {
    type = 'table', optional = true,
    fields = {
        groups = { type = 'map', max = 32, keys = { type = 'string', minLength = 1, maxLength = 50 }, values = { type = 'integer', min = 0, max = 100 } },
    },
}

local BUILTIN_SCHEMA = {
    type = 'table',
    fields = {
        id = { type = 'string', minLength = 3, maxLength = 32, pattern = ID_PATTERN },
        name = { type = 'string', minLength = 1, maxLength = 64 },
        icon = { type = 'string', minLength = 1, maxLength = 64 },
        category = { type = 'string', enum = apps.CATEGORIES },
        order = { type = 'integer', min = 0, max = 10000 },
        description = { type = 'string', optional = true, maxLength = 64 },
        install = { type = 'string', optional = true, enum = { 'preinstalled', 'store' } },
        removable = { type = 'boolean', optional = true },
        access = ACCESS,
    },
}

local EXTERNAL_SCHEMA = {
    type = 'table',
    fields = {
        id = { type = 'string', minLength = 3, maxLength = 32, pattern = ID_PATTERN },
        name = { type = 'any', check = textCheck(48) },
        ui = { type = 'string', minLength = 8, maxLength = 200 },
        icon = { type = 'string', optional = true, maxLength = 200 },
        category = { type = 'string', optional = true, enum = apps.CATEGORIES },
        order = { type = 'integer', optional = true, min = 0, max = 10000 },
        version = { type = 'string', optional = true, maxLength = 16, pattern = '[%w%.%-]+' },
        developer = { type = 'string', optional = true, maxLength = 48 },
        description = { type = 'any', optional = true, check = textCheck(400) },
        install = { type = 'string', optional = true, enum = { 'preinstalled', 'store' } },
        removable = { type = 'boolean', optional = true },
        permissions = { type = 'array', optional = true, max = #apps.PERMISSIONS, items = { type = 'string', enum = apps.PERMISSIONS } },
        storage = { type = 'table', optional = true, fields = { quotaKB = { type = 'integer', min = 16, max = 4096 } } },
        sizeMB = { type = 'number', optional = true, min = 0, max = 4096 },
        access = ACCESS,
    },
}

local WIDGET_SCHEMA = {
    type = 'table',
    fields = {
        id = { type = 'string', minLength = 3, maxLength = 32, pattern = ID_PATTERN },
        name = { type = 'any', check = textCheck(48) },
        ui = { type = 'string', minLength = 8, maxLength = 200 },
        sizes = { type = 'array', min = 1, max = 2, items = { type = 'string', enum = apps.WIDGET_SIZES } },
        app = { type = 'string', optional = true, minLength = 3, maxLength = 32, pattern = ID_PATTERN },
        access = ACCESS,
    },
}

local KEY_SCHEMA = { type = 'string', minLength = 1, maxLength = 64, pattern = '[%w_%-%.:]+' }
apps.KEY_SCHEMA = KEY_SCHEMA

-- state ------------------------------------------------------------------

---@type table<string, table>
local registry = {}
---@type table[]
local ordered = {}
---@type table<string, table>
local widgets = {}
---@type table[]
local widgetOrder = {}
---@type table<string, { apps: table<string, true>, widgets: table<string, true> }>
local owners = {}
---First resource that registered each id since toxic_ipad started. An id
---keeps its owner after that resource stops, so another resource cannot
---take over the app's stored data and granted permissions on the tablets.
---@type table<string, string>
local firstOwner = {}
---@type fun()[]
local listeners = {}
local defaultDock = {}
local externalApps, externalWidgets = 0, 0
local widgetGen = 0   -- bumps on every widget registration (UpdateWidget data of older ones is stale)

local framework, storage, device, json

local function sortAll()
    ordered = {}
    for _, def in pairs(registry) do ordered[#ordered + 1] = def end
    table.sort(ordered, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.id < b.id
    end)
    widgetOrder = {}
    for _, def in pairs(widgets) do widgetOrder[#widgetOrder + 1] = def end
    table.sort(widgetOrder, function(a, b)
        if a.builtin ~= b.builtin then return a.builtin end
        return a.id < b.id
    end)
end

local function changed()
    for i = 1, #listeners do
        local ok, err = pcall(listeners[i])
        if not ok then print(('^1[toxic_ipad] apps listener failed: %s^7'):format(tostring(err))) end
    end
end

---Turns `nui://<res>/<path>` or `https://cfx-nui-<res>/<path>` into the
---https form, only when <res> is `resource` (an app cannot point at
---another resource's files).
---@param value string
---@param resource string
---@return string? url
---@return string? origin
function apps.resourceUrl(value, resource)
    if type(value) ~= 'string' then return nil end
    local res, path = value:match('^nui://([%w_%-]+)/(.+)$')
    if not res then res, path = value:match('^https://cfx%-nui%-([%w_%-]+)/(.+)$') end
    if not res or res ~= resource then return nil end
    if path:find('..', 1, true) or not path:match('^[%w_%-%./]+$') then return nil end
    -- host names are case-insensitive; the browser reports the origin in lower case
    local origin = ('https://cfx-nui-%s'):format(res:lower())
    return ('%s/%s'):format(origin, path), origin
end

-- init -------------------------------------------------------------------

---Builds the registry from config. Pure: runs at load time, before the
---framework and the database are ready (see apps.bind).
---@param list table[]              config/apps.lua builtin
---@param dock string[]             config/apps.lua defaultDock
---@return string[] problems
function apps.init(list, dock)
    registry, widgets, owners, listeners, defaultDock, firstOwner = {}, {}, {}, {}, {}, {}
    externalApps, externalWidgets = 0, 0

    local problems = {}
    for i, def in ipairs(list) do
        local ok, errors = validate.schema(def, BUILTIN_SCHEMA, ('config/apps.lua builtin[%d]'):format(i))
        if not ok then
            for _, e in ipairs(errors) do problems[#problems + 1] = e end
        elseif registry[def.id] then
            problems[#problems + 1] = ('config/apps.lua: app id "%s" is listed twice'):format(def.id)
        elseif def.id:sub(1, #RESERVED_PREFIX) == RESERVED_PREFIX then
            problems[#problems + 1] = ('config/apps.lua: app ids may not start with "%s"'):format(RESERVED_PREFIX)
        else
            registry[def.id] = {
                id = def.id, name = def.name, icon = def.icon, category = def.category, order = def.order,
                description = def.description, access = def.access, builtin = true,
                install = def.install or 'preinstalled', removable = def.removable ~= false,
                permissions = {}, quotaKB = 0,
            }
        end
    end

    widgets.clock = { id = 'clock', name = 'widget.clock', sizes = { 'small', 'medium' }, builtin = true }
    widgets.battery = { id = 'battery', name = 'widget.battery', sizes = { 'small', 'medium' }, builtin = true }

    for _, id in ipairs(dock or {}) do
        if registry[id] and #defaultDock < 6 then defaultDock[#defaultDock + 1] = id end
    end
    sortAll()
    return problems
end

---Connects the runtime dependencies once the boot has them.
---@param deps { framework: table, storage: table, device: table, json: table? }
function apps.bind(deps)
    framework, storage, device, json = deps.framework, deps.storage, deps.device, deps.json or _G.json
end

---@param fn fun()
function apps.onChange(fn)
    listeners[#listeners + 1] = fn
end

-- external registration ---------------------------------------------------

---@param resource string
---@return { apps: table<string, true>, widgets: table<string, true> }
local function ownerOf(resource)
    owners[resource] = owners[resource] or { apps = {}, widgets = {} }
    return owners[resource]
end

---Registers (or updates) an external app for `resource`.
---@param def table
---@param resource string?  GetInvokingResource()
---@return boolean ok
---@return string? err       'bad_request' | 'app_id_taken' | 'limit'
---@return string[]? problems
function apps.register(def, resource)
    if type(resource) ~= 'string' or resource == '' then
        return false, 'bad_request', { 'RegisterApp must be called from another resource' }
    end
    local ok, problems = validate.schema(def, EXTERNAL_SCHEMA, 'RegisterApp')
    if not ok then return false, 'bad_request', problems end
    if def.id:sub(1, #RESERVED_PREFIX) == RESERVED_PREFIX then
        return false, 'bad_request', { ('RegisterApp.id: may not start with "%s"'):format(RESERVED_PREFIX) }
    end

    local existing = registry[def.id]
    if existing and (existing.builtin or existing.owner ~= resource) then
        return false, 'app_id_taken', { ('RegisterApp.id: "%s" already belongs to %s'):format(def.id, existing.builtin and 'toxic_ipad' or existing.owner) }
    end
    local claimed = firstOwner['app:' .. def.id]
    if claimed and claimed ~= resource then
        return false, 'app_id_taken', { ('RegisterApp.id: "%s" belongs to %s (restart toxic_ipad to release it)'):format(def.id, claimed) }
    end
    if not existing and externalApps >= apps.MAX_EXTERNAL_APPS then
        return false, 'limit', { ('RegisterApp: at most %d external apps'):format(apps.MAX_EXTERNAL_APPS) }
    end

    local ui, origin = apps.resourceUrl(def.ui, resource)
    if not ui then
        return false, 'bad_request', { ('RegisterApp.ui: must be "nui://%s/<file>" (a file of the calling resource)'):format(resource) }
    end
    local icon
    if def.icon then
        icon = apps.resourceUrl(def.icon, resource)
        if not icon then
            return false, 'bad_request', { ('RegisterApp.icon: must be "nui://%s/<file>"'):format(resource) }
        end
    end

    registry[def.id] = {
        id = def.id, name = def.name, icon = icon or '', category = def.category or 'other', order = def.order or 100,
        version = def.version or '1.0.0', developer = def.developer, description = def.description,
        access = def.access, builtin = false, owner = resource, ui = ui, origin = origin,
        install = def.install or 'store', removable = def.removable ~= false,
        permissions = def.permissions or {},
        quotaKB = def.storage and def.storage.quotaKB or apps.DEFAULT_QUOTA_KB,
        sizeMB = def.sizeMB,
    }
    if not existing then externalApps = externalApps + 1 end
    firstOwner['app:' .. def.id] = resource
    ownerOf(resource).apps[def.id] = true
    sortAll()
    changed()
    return true
end

---@param id string
---@param resource string?
---@return boolean
function apps.unregister(id, resource)
    local def = registry[id]
    if not def or def.builtin or def.owner ~= resource then return false end
    registry[id] = nil
    externalApps = externalApps - 1
    if owners[resource] then owners[resource].apps[id] = nil end
    sortAll()
    changed()
    return true
end

---@param def table
---@param resource string?
---@return boolean ok
---@return string? err
---@return string[]? problems
function apps.registerWidget(def, resource)
    if type(resource) ~= 'string' or resource == '' then
        return false, 'bad_request', { 'RegisterWidget must be called from another resource' }
    end
    local ok, problems = validate.schema(def, WIDGET_SCHEMA, 'RegisterWidget')
    if not ok then return false, 'bad_request', problems end

    local existing = widgets[def.id]
    local claimed = firstOwner['widget:' .. def.id]
    if (existing and (existing.builtin or existing.owner ~= resource)) or (claimed and claimed ~= resource) then
        return false, 'app_id_taken', { ('RegisterWidget.id: "%s" is already registered'):format(def.id) }
    end
    if not existing and externalWidgets >= apps.MAX_EXTERNAL_WIDGETS then
        return false, 'limit', { ('RegisterWidget: at most %d external widgets'):format(apps.MAX_EXTERNAL_WIDGETS) }
    end
    local ui, origin = apps.resourceUrl(def.ui, resource)
    if not ui then
        return false, 'bad_request', { ('RegisterWidget.ui: must be "nui://%s/<file>"'):format(resource) }
    end

    widgetGen = widgetGen + 1
    widgets[def.id] = {
        id = def.id, name = def.name, sizes = def.sizes, app = def.app, access = def.access,
        builtin = false, owner = resource, ui = ui, origin = origin, gen = widgetGen,
    }
    if not existing then externalWidgets = externalWidgets + 1 end
    firstOwner['widget:' .. def.id] = resource
    ownerOf(resource).widgets[def.id] = true
    sortAll()
    changed()
    return true
end

---Forgets everything a stopped resource registered.
---@param resource string
---@return integer removed
function apps.unregisterResource(resource)
    local owned = owners[resource]
    if not owned then return 0 end
    local removed = 0
    for id in pairs(owned.apps) do
        if registry[id] and registry[id].owner == resource then
            registry[id] = nil
            externalApps = externalApps - 1
            removed = removed + 1
        end
    end
    for id in pairs(owned.widgets) do
        if widgets[id] and widgets[id].owner == resource then
            widgets[id] = nil
            externalWidgets = externalWidgets - 1
            removed = removed + 1
        end
    end
    owners[resource] = nil
    if removed > 0 then
        sortAll()
        changed()
    end
    return removed
end

-- access -----------------------------------------------------------------

---@param src integer
---@param def table
---@return boolean
local function canSee(src, def)
    if def.unavailable then return false end
    if not def.access or not def.access.groups or next(def.access.groups) == nil then return true end
    return framework.hasGroup(src, def.access.groups)
end

---Hides a built-in app whose feature is not set up on this server (e.g.
---Camera without an uploader or screenshot-basic). Hidden apps are not
---listed, launched or offered in the App Store; install state is kept.
---@param id string
---@param available boolean
---@return boolean changed
function apps.setAvailable(id, available)
    local def = registry[id]
    if not def or not def.builtin then return false end
    local hidden = not available or nil
    if def.unavailable == hidden then return false end
    def.unavailable = hidden
    changed()
    return true
end

---Whether a player may see this widget on this device (UpdateWidget).
---@param src integer
---@param rec table
---@param widgetId string
---@return boolean
function apps.widgetVisible(src, rec, widgetId)
    local def = widgets[widgetId]
    if not def or not canSee(src, def) then return false end
    return not def.app or (apps.isInstalled(rec, def.app) and apps.canUse(src, def.app))
end

---@param widgetId string
---@return table?
function apps.getWidget(widgetId)
    return widgets[widgetId]
end

---@param id string
---@return table?
function apps.get(id)
    return registry[id]
end

---@param appId string
---@return boolean
function apps.exists(appId)
    return registry[appId] ~= nil
end

---@param src integer
---@param appId string
---@return boolean
function apps.canUse(src, appId)
    local def = registry[appId]
    return def ~= nil and canSee(src, def)
end

---@return string[]
function apps.defaultDock()
    return defaultDock
end

-- per-device install state ----------------------------------------------------

---@param text string?
---@return table<string, string>
local function decodePermissions(text)
    local out = {}
    if type(text) ~= 'string' then return out end
    for name, state in text:gmatch('"([%w_]+)"%s*:%s*"(%a+)"') do
        if state == 'granted' or state == 'denied' then out[name] = state end
    end
    return out
end

---@param perms table<string, string>
---@return string
local function encodePermissions(perms)
    local names = {}
    for name in pairs(perms) do names[#names + 1] = name end
    table.sort(names)
    local parts = {}
    for i, name in ipairs(names) do parts[i] = ('"%s":"%s"'):format(name, perms[name]) end
    return '{' .. table.concat(parts, ',') .. '}'
end

---Loads the device's install state once per cached device record.
---Must run in a coroutine.
---@param rec table IpadDevice
function apps.loadDevice(rec)
    if rec.apps then return end
    local installedRows, removedRows = storage.load(rec.id)
    local state = { installed = {}, removed = {} }
    for _, row in ipairs(installedRows or {}) do state.installed[row.app_id] = decodePermissions(row.permissions) end
    for _, row in ipairs(removedRows or {}) do state.removed[row.app_id] = true end
    rec.apps = state
end

---@param rec table
---@param appId string
---@return boolean
function apps.isInstalled(rec, appId)
    local def = registry[appId]
    if not def or not rec.apps then return false end
    if rec.apps.installed[appId] then return true end
    return def.install == 'preinstalled' and not rec.apps.removed[appId]
end

---@param rec table
---@param appId string
---@param permission string
---@return 'granted'|'denied'|'prompt'
function apps.permissionState(rec, appId, permission)
    local perms = rec.apps and rec.apps.installed[appId]
    return perms and perms[permission] or 'prompt'
end

---What the NUI needs to show and launch an app.
---@param def table
---@param rec table
---@return table
local function toClient(def, rec)
    local granted = {}
    for _, name in ipairs(def.permissions) do granted[name] = apps.permissionState(rec, def.id, name) end
    return {
        id = def.id, name = def.name, icon = def.icon, category = def.category, builtin = def.builtin,
        removable = def.removable, ui = def.ui, origin = def.origin,
        permissions = def.permissions, granted = granted,
        version = def.version, developer = def.developer,
    }
end

---Installed apps this player may use, in display order.
---@param src integer
---@param rec table
---@return table[]
function apps.visibleFor(src, rec)
    local out = {}
    for _, def in ipairs(ordered) do
        if apps.isInstalled(rec, def.id) and canSee(src, def) then out[#out + 1] = toClient(def, rec) end
    end
    return out
end

---Widgets this player may add (their app, if any, must be installed).
---@param src integer
---@param rec table
---@return table[]
function apps.widgetsFor(src, rec)
    local out = {}
    for _, def in ipairs(widgetOrder) do
        local appOk = not def.app or (apps.isInstalled(rec, def.app) and apps.canUse(src, def.app))
        if appOk and canSee(src, def) then
            out[#out + 1] = { id = def.id, name = def.name, sizes = def.sizes, builtin = def.builtin, ui = def.ui, origin = def.origin, app = def.app }
        end
    end
    return out
end

---App Store catalogue: every removable app this player may use.
---@param src integer
---@param rec table
---@return table[]
function apps.storeFor(src, rec)
    local out = {}
    for _, def in ipairs(ordered) do
        if def.removable and canSee(src, def) then
            out[#out + 1] = {
                id = def.id, name = def.name, icon = def.icon, category = def.category, builtin = def.builtin,
                description = def.description, developer = def.developer, version = def.version,
                permissions = def.permissions, sizeMB = def.sizeMB, installed = apps.isInstalled(rec, def.id),
            }
        end
    end
    return out
end

-- layout pruning -------------------------------------------------------------

---@param list string[]?
---@param id string
local function removeFrom(list, id)
    if type(list) ~= 'table' then return end
    for i = #list, 1, -1 do
        if list[i] == id then table.remove(list, i) end
    end
end

---Removes an uninstalled app from the saved home layout.
---@param settings table
---@param id string
function apps.pruneLayout(settings, id)
    local layout = settings.layout
    for _, page in ipairs(layout.pages) do removeFrom(page, id) end
    removeFrom(layout.dock, id)
    removeFrom(layout.recents, id)
    for folderId, folder in pairs(layout.folders) do
        removeFrom(folder.apps, id)
        if #folder.apps == 0 then
            layout.folders[folderId] = nil
            for _, page in ipairs(layout.pages) do removeFrom(page, folderId) end
            removeFrom(layout.dock, folderId)
        end
    end
    for i = #layout.pages, 1, -1 do
        if #layout.pages[i] == 0 then table.remove(layout.pages, i) end
    end
    if settings.notifications and settings.notifications.perApp then
        settings.notifications.perApp[id] = nil
    end
end

-- callback handlers (registered through the guard) ------------------------------

---@param s table IpadSession
---@return table
function apps.store(s)
    apps.loadDevice(s.device)
    return { ok = true, apps = apps.storeFor(s.src, s.device) }
end

---@param s table
---@param payload { id: string }
---@return table
function apps.install(s, payload)
    local rec, def = s.device, registry[payload.id]
    if not def or not canSee(s.src, def) then return { ok = false, err = 'not_found' } end
    apps.loadDevice(rec)
    if apps.isInstalled(rec, def.id) then return { ok = true, apps = apps.visibleFor(s.src, rec) } end

    local writeRow = def.install ~= 'preinstalled'
    if not storage.install(rec.id, def.id, writeRow) then return { ok = false, err = 'internal' } end
    rec.apps.removed[def.id] = nil
    if writeRow then rec.apps.installed[def.id] = {} end
    return { ok = true, apps = apps.visibleFor(s.src, rec), widgets = apps.widgetsFor(s.src, rec) }
end

---@param s table
---@param payload { id: string }
---@return table
function apps.uninstall(s, payload)
    local rec, def = s.device, registry[payload.id]
    apps.loadDevice(rec)
    -- An app whose resource is gone can still be removed from the device.
    if def and not def.removable then return { ok = false, err = 'not_removable' } end
    if def and not apps.isInstalled(rec, def.id) then return { ok = true, apps = apps.visibleFor(s.src, rec) } end
    if not def and not rec.apps.installed[payload.id] then return { ok = false, err = 'not_found' } end

    local remember = def ~= nil and def.install == 'preinstalled'
    if not storage.uninstall(rec.id, payload.id, remember) then return { ok = false, err = 'internal' } end
    rec.apps.installed[payload.id] = nil
    if remember then rec.apps.removed[payload.id] = true end
    if rec.appUsage then rec.appUsage[payload.id] = nil end

    apps.pruneLayout(rec.settings, payload.id)
    device.markSettingsDirty(rec)
    return { ok = true, apps = apps.visibleFor(s.src, rec), widgets = apps.widgetsFor(s.src, rec), settings = rec.settings }
end

---@param s table
---@param payload { id: string, permission: string, state: 'granted'|'denied'|'prompt' }
---@return table
function apps.setPermission(s, payload)
    local rec, def = s.device, registry[payload.id]
    if not def or not canSee(s.src, def) then return { ok = false, err = 'not_found' } end
    apps.loadDevice(rec)
    if not apps.isInstalled(rec, def.id) then return { ok = false, err = 'not_installed' } end

    local declared = false
    for _, name in ipairs(def.permissions) do
        if name == payload.permission then declared = true end
    end
    if not declared then return { ok = false, err = 'not_declared' } end

    local perms = rec.apps.installed[def.id] or {}
    perms[payload.permission] = payload.state ~= 'prompt' and payload.state or nil
    storage.savePermissions(rec.id, def.id, encodePermissions(perms))
    rec.apps.installed[def.id] = perms
    return { ok = true, state = payload.state, app = toClient(def, rec) }
end

-- app data (SDK storage) ------------------------------------------------------

---@param s table
---@param appId string
---@return table? def
---@return string? err
local function dataTarget(s, appId)
    local def = registry[appId]
    if not def or def.builtin or not canSee(s.src, def) then return nil, 'not_found' end
    apps.loadDevice(s.device)
    if not apps.isInstalled(s.device, appId) then return nil, 'not_installed' end
    return def
end

---@param rec table
---@return table<string, integer>
local function usageOf(rec)
    if not rec.appUsage then
        rec.appUsage = {}
        for appId, u in pairs(storage.usage(rec.id)) do rec.appUsage[appId] = u.bytes end
    end
    return rec.appUsage
end

---@param s table
---@param payload { app: string, key: string }
---@return table
function apps.dataGet(s, payload)
    local def, err = dataTarget(s, payload.app)
    if not def then return { ok = false, err = err } end
    local row = storage.getValue(s.device.id, def.id, payload.key)
    if not row then return { ok = true, value = nil, exists = false } end
    local ok, value = pcall(json.decode, row.value)
    if not ok then return { ok = false, err = 'internal' } end
    return { ok = true, value = value, exists = true }
end

---@param s table
---@param payload { app: string, key: string, value: any }
---@return table
function apps.dataSet(s, payload)
    local def, err = dataTarget(s, payload.app)
    if not def then return { ok = false, err = err } end
    if payload.value == nil then return { ok = false, err = 'bad_request' } end

    local okEncode, encoded = pcall(json.encode, payload.value)
    if not okEncode or type(encoded) ~= 'string' then return { ok = false, err = 'bad_request' } end
    if #encoded > apps.MAX_VALUE_BYTES then return { ok = false, err = 'too_large' } end

    local rec = s.device
    local usage = usageOf(rec)
    local old = storage.getValue(rec.id, def.id, payload.key)
    local oldBytes = old and (math.tointeger(tonumber(old.size_bytes)) or #old.value) or 0
    local after = (usage[def.id] or 0) - oldBytes + #encoded
    if after > def.quotaKB * 1024 then return { ok = false, err = 'quota' } end

    storage.setValue(rec.id, def.id, payload.key, encoded)
    usage[def.id] = after
    return { ok = true }
end

---@param s table
---@param payload { app: string, key: string }
---@return table
function apps.dataRemove(s, payload)
    local def, err = dataTarget(s, payload.app)
    if not def then return { ok = false, err = err } end
    local rec = s.device
    local usage = usageOf(rec)
    local old = storage.getValue(rec.id, def.id, payload.key)
    if old and storage.removeValue(rec.id, def.id, payload.key) then
        usage[def.id] = math.max(0, (usage[def.id] or 0) - (math.tointeger(tonumber(old.size_bytes)) or #old.value))
    end
    return { ok = true }
end

---Bytes of app data per app on this device (Settings › Storage).
---@param rec table
---@return table<string, integer>
function apps.dataUsage(rec)
    return usageOf(rec)
end

return apps
