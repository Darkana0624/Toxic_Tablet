-- Add this entry to ox_inventory/data/items.lua (inside the returned table),
-- and copy install/toxic_ipad.png to ox_inventory/web/images/toxic_ipad.png.
--
-- consume = 0 and stack = false are REQUIRED: without consume = 0,
-- ox_inventory deletes the tablet every time it is used. toxic_ipad checks
-- both at start and refuses to run if they are wrong.

['toxic_ipad'] = {
    label = 'Toxic Tab Pro',
    weight = 700,
    stack = false,
    close = true,
    consume = 0,
    description = 'A premium tablet.',
    server = {
        export = 'toxic_ipad.useItem',
    },
},
