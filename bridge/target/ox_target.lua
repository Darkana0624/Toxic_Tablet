---Target adapter: ox_target. Client side. Only this file may name ox_target.
---Charging stations (config/shared.lua battery.stations) become sphere
---zones with one option; the server checks distance, the tablet and
---everything else.

local target = {}

local zones = {} ---@type integer[]

---@return boolean
function target.available()
    return GetResourceState('ox_target') == 'started'
end

---@param points { coords: vector3, label: string? }[]
---@param radius number
---@param label string   option text
---@param onSelect fun(index: integer)
function target.addStations(points, radius, label, onSelect)
    target.clear()
    for i, point in ipairs(points) do
        local c = point.coords
        zones[#zones + 1] = exports.ox_target:addSphereZone({
            coords = vector3(c.x + 0.0, c.y + 0.0, c.z + 0.0),
            radius = radius,
            debug = false,
            options = {
                {
                    name = ('toxic_ipad_station_%d'):format(i),
                    icon = 'fa-solid fa-plug',
                    label = point.label and ('%s · %s'):format(label, point.label) or label,
                    distance = radius + 1.0,
                    onSelect = function() onSelect(i) end,
                },
            },
        })
    end
end

function target.clear()
    if #zones > 0 and target.available() then
        for _, id in ipairs(zones) do pcall(function() exports.ox_target:removeZone(id) end) end
    end
    zones = {}
end

return target
