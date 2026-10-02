---Files (MVP §78A, docs/DATABASE.md): a virtual file system per device.
---Entries are names, sizes and references ('note:42', 'app:<id>:/route', an
---uploader URL later) — never binary data (§57).
---
---Two system roots, Documents and Downloads, are created on first use and
---can't be renamed, moved or deleted. Everything is validated here; the
---client sends ids and names only.

local storage = require 'server.storage.files'

local files = {}

files.KIND_FOLDER = 1
files.KIND_FILE = 2
files.MAX_NAME = 80          -- characters
files.LIST_LIMIT = 500
files.ROOTS = { 'Documents', 'Downloads' }

local int = storage.int
local cfg, notesModule, otherBytes

---@param config table
---@param deps { notes: table, otherBytes: (fun(rec: table): integer)? }
function files.init(config, deps)
    cfg = config
    notesModule = deps.notes
    otherBytes = deps.otherBytes or function() return 0 end
    -- InnoDB cascades ON DELETE through at most 15 levels; the roots add one.
    local limits = cfg.server.files
    if limits.maxDepth > 12 then
        print('^3[toxic_ipad] config/server.lua files.maxDepth is capped at 12^7')
        limits.maxDepth = 12
    end
end

-- names ------------------------------------------------------------------

---Cleans a user-typed name. Returns nil when nothing usable is left.
---@param name any
---@return string?
function files.cleanName(name)
    if type(name) ~= 'string' or not utf8.len(name) then return nil end
    name = name:gsub('%c', ''):gsub('[/\\]', ' '):gsub('%s%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if name == '' or name == '.' or name == '..' then return nil end
    if utf8.len(name) > files.MAX_NAME then
        name = name:sub(1, utf8.offset(name, files.MAX_NAME + 1) - 1)
    end
    return name
end

---"Report.txt" → "Report 2.txt" (keeps the extension).
---@param name string
---@param n integer
---@return string
function files.numbered(name, n)
    local base, ext = name:match('^(.+)(%.[%w]+)$')
    if not base then base, ext = name, '' end
    local suffix = (' %d'):format(n)
    local maxBase = files.MAX_NAME - utf8.len(suffix .. ext)
    if utf8.len(base) > maxBase then base = base:sub(1, utf8.offset(base, maxBase + 1) - 1) end
    return base .. suffix .. ext
end

-- helpers ----------------------------------------------------------------

---@param row table
---@return table
local function toClient(row)
    return {
        id = int(row.id),
        parent = row.parent_id and int(row.parent_id) or nil,
        folder = int(row.kind) == files.KIND_FOLDER,
        name = row.name,
        mime = row.mime,
        size = int(row.size_bytes),
        ref = row.ref,
        system = row.system == 1 or row.system == true,
        time = int(row.created_at),
    }
end

---Documents / Downloads ids, created once per device.
---@param rec table
---@return table<string, integer>
local function roots(rec)
    if rec.fileRoots then return rec.fileRoots end
    local found = {}
    for _, row in ipairs(storage.roots(rec.id)) do found[row.name] = int(row.id) end
    for _, name in ipairs(files.ROOTS) do
        if not found[name] then found[name] = storage.createRoot(rec.id, name) end
    end
    rec.fileRoots = found
    return found
end
files.roots = roots

---@param rec table
---@return integer count
---@return integer bytes
local function usage(rec)
    if not rec.fileUsage then
        local count, bytes = storage.usage(rec.id)
        rec.fileUsage = { count = count, bytes = bytes }
    end
    return rec.fileUsage.count, rec.fileUsage.bytes
end

---@param rec table
---@param dCount integer
---@param dBytes integer
local function adjust(rec, dCount, dBytes)
    local count, bytes = usage(rec)
    rec.fileUsage.count = math.max(0, count + dCount)
    rec.fileUsage.bytes = math.max(0, bytes + dBytes)
end

---A folder of this device (roots included), or nil.
---@param rec table
---@param id integer
---@return table? row
local function folderOf(rec, id)
    local row = storage.get(rec.id, id)
    if not row or int(row.kind) ~= files.KIND_FOLDER then return nil end
    return row
end

---@param rec table
---@param parentId integer
---@param name string
---@return string? free name (nil when 99 variants are taken)
local function freeName(rec, parentId, name)
    if not storage.nameTaken(rec.id, parentId, name) then return name end
    for n = 2, 99 do
        local candidate = files.numbered(name, n)
        if not storage.nameTaken(rec.id, parentId, candidate) then return candidate end
    end
    return nil
end

---Creates an entry after every check. Shared by the callbacks and SaveFile.
---@param rec table
---@param parentId integer
---@param entry { kind: integer, name: string, mime: string?, size: integer?, ref: string? }
---@param uniqueName boolean pick "Name 2" instead of failing on a clash
---@return table? row
---@return string? err
local function create(rec, parentId, entry, uniqueName)
    local parent = folderOf(rec, parentId)
    if not parent then return nil, 'not_found' end

    local count, bytes = usage(rec)
    if count >= cfg.server.files.maxEntries then return nil, 'limit' end
    local size = entry.size or 0
    if bytes + otherBytes(rec) + size > rec.capacityMb * 1024 * 1024 then return nil, 'storage_full' end -- files + photos are the large content

    if entry.kind == files.KIND_FOLDER then
        local chain = storage.ancestors(rec.id, parentId)
        if #chain > cfg.server.files.maxDepth then return nil, 'too_deep' end
    end

    local name = entry.name
    if uniqueName then
        name = freeName(rec, parentId, name)
        if not name then return nil, 'name_taken' end
    elseif storage.nameTaken(rec.id, parentId, name) then
        return nil, 'name_taken'
    end

    local ok, id = pcall(storage.insert, rec.id, {
        parent = parentId, kind = entry.kind, name = name, mime = entry.mime, size = size, ref = entry.ref,
    })
    if not ok or not id then return nil, 'name_taken' end -- lost a race on uq_files_name
    adjust(rec, 1, size)
    return {
        id = id, parent_id = parentId, kind = entry.kind, name = name, mime = entry.mime,
        size_bytes = size, ref = entry.ref, system = 0, created_at = os.time(),
    }
end

-- callback handlers --------------------------------------------------------

---@param s table IpadSession
---@param payload { folder: integer? }
---@return table
function files.list(s, payload)
    local rec = s.device
    local r = roots(rec)
    local folderId = payload.folder or r.Documents

    local chain = storage.ancestors(rec.id, folderId)
    local self = chain[1]
    if not self or int(self.kind) ~= files.KIND_FOLDER then return { ok = false, err = 'not_found' } end

    local path = {}
    for i = #chain, 1, -1 do
        local a = chain[i]
        path[#path + 1] = { id = int(a.id), name = a.name, system = a.system == 1 or a.system == true }
    end

    local entries = {}
    for i, row in ipairs(storage.children(rec.id, folderId, files.LIST_LIMIT)) do entries[i] = toClient(row) end

    return {
        ok = true,
        folder = path[#path],
        path = path,
        entries = entries,
        roots = { documents = r.Documents, downloads = r.Downloads },
    }
end

---@param s table
---@return table
function files.recents(s)
    local rec = s.device
    local r = roots(rec)
    local out = {}
    for i, row in ipairs(storage.recents(rec.id, 30)) do out[i] = toClient(row) end
    return { ok = true, entries = out, roots = { documents = r.Documents, downloads = r.Downloads } }
end

---@param s table
---@param payload { parent: integer, name: string }
---@return table
function files.mkdir(s, payload)
    local name = files.cleanName(payload.name)
    if not name then return { ok = false, err = 'bad_name' } end
    local row, err = create(s.device, payload.parent, { kind = files.KIND_FOLDER, name = name }, payload.unique == true)
    if not row then return { ok = false, err = err } end
    return { ok = true, entry = toClient(row) }
end

---@param s table
---@param payload { id: integer, name: string }
---@return table
function files.rename(s, payload)
    local rec = s.device
    local name = files.cleanName(payload.name)
    if not name then return { ok = false, err = 'bad_name' } end
    local row = storage.get(rec.id, payload.id)
    if not row then return { ok = false, err = 'not_found' } end
    if row.system == 1 or row.system == true then return { ok = false, err = 'system' } end
    if row.name == name then return { ok = true, entry = toClient(row) } end
    if storage.nameTaken(rec.id, int(row.parent_id), name) then return { ok = false, err = 'name_taken' } end
    local ok, updated = pcall(storage.rename, rec.id, payload.id, name)
    if not ok or not updated then return { ok = false, err = 'name_taken' } end
    row.name = name
    return { ok = true, entry = toClient(row) }
end

---@param s table
---@param payload { id: integer, parent: integer }
---@return table
function files.move(s, payload)
    local rec = s.device
    local row = storage.get(rec.id, payload.id)
    if not row then return { ok = false, err = 'not_found' } end
    if row.system == 1 or row.system == true then return { ok = false, err = 'system' } end
    if int(row.parent_id) == payload.parent then return { ok = true, entry = toClient(row) } end
    if not folderOf(rec, payload.parent) then return { ok = false, err = 'not_found' } end

    -- a folder cannot move into itself or below itself
    local chain = storage.ancestors(rec.id, payload.parent)
    for _, a in ipairs(chain) do
        if int(a.id) == payload.id then return { ok = false, err = 'into_itself' } end
    end
    if int(row.kind) == files.KIND_FOLDER then
        -- the moved folder lands at depth #chain; its deepest child `height` below
        local _, _, height = storage.subtree(rec.id, payload.id)
        if #chain + height > cfg.server.files.maxDepth then return { ok = false, err = 'too_deep' } end
    end
    if storage.nameTaken(rec.id, payload.parent, row.name) then return { ok = false, err = 'name_taken' } end

    local ok, moved = pcall(storage.move, rec.id, payload.id, payload.parent)
    if not ok or not moved then return { ok = false, err = 'name_taken' } end
    row.parent_id = payload.parent
    return { ok = true, entry = toClient(row) }
end

---@param s table
---@param payload { id: integer }
---@return table
function files.delete(s, payload)
    local rec = s.device
    local row = storage.get(rec.id, payload.id)
    if not row then return { ok = false, err = 'not_found' } end
    if row.system == 1 or row.system == true then return { ok = false, err = 'system' } end
    local count, bytes = storage.subtree(rec.id, payload.id)
    if not storage.delete(rec.id, payload.id) then return { ok = false, err = 'not_found' } end
    adjust(rec, -count, -bytes)
    return { ok = true, removed = count }
end

---Notes › Share › Save to Files: the server copies its own note, the client
---only names which one.
---@param s table
---@param payload { id: integer }
---@return table
function files.saveNote(s, payload)
    local note = notesModule.find(s.device, payload.id)
    if not note then return { ok = false, err = 'not_found' } end
    local title = files.cleanName(note.title) or 'Note'
    if utf8.len(title) > files.MAX_NAME - 4 then title = title:sub(1, utf8.offset(title, files.MAX_NAME - 3) - 1) end
    local r = roots(s.device)
    local row, err = create(s.device, r.Documents, {
        kind = files.KIND_FILE, name = title .. '.txt', mime = 'text/plain',
        size = #note.title + #note.body, ref = ('note:%d'):format(note.id),
    }, true)
    if not row then return { ok = false, err = err } end
    return { ok = true, entry = toClient(row) }
end

-- export -------------------------------------------------------------------

local SAVE_SCHEMA = {
    type = 'table',
    fields = {
        folder = { type = 'string', optional = true, enum = { 'Documents', 'Downloads' } },
        name = { type = 'string', minLength = 1, maxLength = 320 },
        mime = { type = 'string', optional = true, maxLength = 48, pattern = '[%w%.%+%-]+/[%w%.%+%-]+' },
        sizeBytes = { type = 'integer', optional = true, min = 0, max = 1099511627776 },
        ref = { type = 'string', optional = true, maxLength = 255 },
    },
}
files.SAVE_SCHEMA = SAVE_SCHEMA

---exports.toxic_ipad:SaveFile(target, data) for one device record.
---@param rec table
---@param data table validated against SAVE_SCHEMA
---@return table? entry
---@return string? err
function files.saveFor(rec, data)
    local name = files.cleanName(data.name)
    if not name then return nil, 'bad_name' end
    local r = roots(rec)
    local row, err = create(rec, r[data.folder or 'Downloads'], {
        kind = files.KIND_FILE, name = name, mime = data.mime, size = data.sizeBytes or 0, ref = data.ref,
    }, true)
    if not row then return nil, err end
    return toClient(row)
end

---Deletes file entries (not folders) whose reference is one of `refs`
---(e.g. 'photo:12' when that photo is deleted).
---@param rec table
---@param refs string[]
---@return integer removed
function files.removeRefs(rec, refs)
    if #refs == 0 then return 0 end
    local removed = storage.deleteRefs(rec.id, refs)
    if removed > 0 then rec.fileUsage = nil end -- recounted on next use
    return removed
end

---Bytes used by files (Settings › Storage).
---@param rec table
---@return integer count
---@return integer bytes
function files.usage(rec)
    return usage(rec)
end

---@param rec table
---@return integer
function files.notesBytes(rec)
    return storage.notesBytes(rec.id)
end

return files
