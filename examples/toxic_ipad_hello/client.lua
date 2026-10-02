---toxic_ipad_hello — client side. The app page (an iframe inside the
---tablet) calls these with fetch('https://toxic_ipad_hello/<name>').

RegisterNUICallback('whereAmI', function(_, cb)
    if not lib.callback.await('toxic_ipad_hello:canLocate', false) then
        return cb({ ok = false, err = 'permission_denied' })
    end
    local coords = GetEntityCoords(cache.ped)
    local street = GetStreetNameFromHashKey(GetStreetNameAtCoord(coords.x, coords.y, coords.z))
    local zone = GetLabelText(GetNameOfZone(coords.x, coords.y, coords.z))
    cb({ ok = true, street = street, zone = zone })
end)

RegisterNUICallback('tapped', function(data, cb)
    TriggerServerEvent('toxic_ipad_hello:tapped', type(data) == 'table' and data.count or 0)
    cb({ ok = true })
end)

RegisterNUICallback('notifyMe', function(_, cb)
    TriggerServerEvent('toxic_ipad_hello:notifyMe')
    cb({ ok = true })
end)
