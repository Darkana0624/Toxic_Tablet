---The game world behind the tablet (docs/RESEARCH.md F3): CSS cannot blur
---the game frame, so the blur is a game-side effect.

local world = {}

local active = nil ---@type string?

---@param mode 'native'|'timecycle'|'none'
---@param cfg table config/client.lua
---@param ms integer fade time
function world.enable(mode, cfg, ms)
    if active then return end
    if mode == 'native' then
        TriggerScreenblurFadeIn(ms)
    elseif mode == 'timecycle' then
        SetTimecycleModifier(cfg.timecycle.modifier)
        SetTimecycleModifierStrength(cfg.timecycle.strength)
    else
        return
    end
    active = mode
end

---@param ms integer fade time
function world.disable(ms)
    if active == 'native' then
        TriggerScreenblurFadeOut(ms)
    elseif active == 'timecycle' then
        ClearTimecycleModifier()
    end
    active = nil
end

return world
