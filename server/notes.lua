---Notes (MVP §78A.4). Notes belong to the device. The list is loaded once
---per open session and kept in the device record (`rec.notes`) so saving,
---searching and reopening Notes cost no SELECTs; it is dropped on close.

local storage = require 'server.storage.notes'

local notes = {}

notes.MAX_NOTES = 500
notes.MAX_TITLE = 120      -- characters
notes.MAX_BODY = 20000     -- characters

---@param text string
---@return integer
local function charLen(text)
    return utf8.len(text) or #text
end

---@param row table
---@return table
local function toClient(row)
    return {
        id = math.tointeger(row.id) or row.id,
        title = row.title,
        body = row.body,
        pinned = row.pinned == 1 or row.pinned == true,
        updatedAt = math.tointeger(row.updated_at) or os.time(),
    }
end

---@param rec IpadDevice
---@return table[] notes (client shape, newest first)
local function load(rec)
    if not rec.notes then
        local list = {}
        for i, row in ipairs(storage.list(rec.id, notes.MAX_NOTES)) do list[i] = toClient(row) end
        rec.notes = list
    end
    return rec.notes
end

---@param list table[]
---@param id integer
---@return integer? index
local function indexOf(list, id)
    for i, n in ipairs(list) do
        if n.id == id then return i end
    end
end

---A note of this device (loads the list once per session).
---@param rec IpadDevice
---@param id integer
---@return table?
function notes.find(rec, id)
    local list = load(rec)
    local index = indexOf(list, id)
    return index and list[index] or nil
end

---@param s IpadSession
---@return table
function notes.list(s)
    return { ok = true, notes = load(s.device) }
end

---@param s IpadSession
---@param payload { id: integer?, title: string, body: string, pinned: boolean? }
---@return table
function notes.save(s, payload)
    local rec = s.device
    local list = load(rec)
    if charLen(payload.title) > notes.MAX_TITLE or charLen(payload.body) > notes.MAX_BODY then
        return { ok = false, err = 'too_long' }
    end
    if not utf8.len(payload.title) or not utf8.len(payload.body) then
        return { ok = false, err = 'bad_request' }
    end

    local pinned = payload.pinned == true
    local note

    if payload.id then
        local index = indexOf(list, payload.id)
        if not index then return { ok = false, err = 'not_found' } end
        storage.update(rec.id, payload.id, payload.title, payload.body, pinned)
        note = list[index]
        note.title, note.body, note.pinned, note.updatedAt = payload.title, payload.body, pinned, os.time()
        table.remove(list, index)
    else
        if #list >= notes.MAX_NOTES then return { ok = false, err = 'limit' } end
        local id = storage.insert(rec.id, payload.title, payload.body, pinned)
        if not id then return { ok = false, err = 'internal' } end
        note = { id = id, title = payload.title, body = payload.body, pinned = pinned, updatedAt = os.time() }
    end

    table.insert(list, 1, note)
    return { ok = true, note = note }
end

---@param s IpadSession
---@param payload { id: integer }
---@return table
function notes.delete(s, payload)
    local rec = s.device
    local list = load(rec)
    local index = indexOf(list, payload.id)
    if not index then return { ok = false, err = 'not_found' } end
    storage.delete(rec.id, payload.id)
    table.remove(list, index)
    return { ok = true }
end

return notes
