---The tablet prop in the player's hand and the holding animation.
---Everything is created on open and deleted on close; nothing exists while
---the tablet is put away.

local holding = {}

local entity = nil      ---@type integer?
local token = 0         -- invalidates a load that finishes after stop()
local current = nil     ---@type table?

---@param cfg table config/client.lua `holding`
function holding.start(cfg)
    if not cfg.enabled then return end
    token = token + 1
    local myToken = token

    CreateThread(function()
        local okDict = pcall(lib.requestAnimDict, cfg.dict, 3000)
        local okModel = pcall(lib.requestModel, cfg.prop, 3000)
        if myToken ~= token then return end

        local ped = cache.ped
        if okModel then
            local coords = GetEntityCoords(ped)
            local obj = CreateObject(joaat(cfg.prop), coords.x, coords.y, coords.z + 0.2, true, true, false)
            SetEntityCollision(obj, false, false)
            AttachEntityToEntity(obj, ped, GetPedBoneIndex(ped, cfg.bone),
                cfg.offset.x, cfg.offset.y, cfg.offset.z,
                cfg.rotation.x, cfg.rotation.y, cfg.rotation.z,
                true, true, false, true, 1, true)
            SetModelAsNoLongerNeeded(joaat(cfg.prop))
            entity = obj
        end

        if okDict then
            TaskPlayAnim(ped, cfg.dict, cfg.clip, 3.0, 3.0, -1, cfg.flag, 0.0, false, false, false)
            current = cfg
        end
    end)
end

function holding.stop()
    token = token + 1
    if entity then
        if DoesEntityExist(entity) then
            DetachEntity(entity, true, false)
            DeleteEntity(entity)
        end
        entity = nil
    end
    if current then
        StopAnimTask(cache.ped, current.dict, current.clip, 2.0)
        RemoveAnimDict(current.dict)
        current = nil
    end
end

return holding
