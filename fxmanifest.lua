fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'toxic_ipad'
author 'Toxic Scripts'
description 'Toxic iPad — a virtual tablet operating system for FiveM'
version '0.7.3'

ox_lib 'locale'

ui_page 'ui/index.html'

shared_scripts {
    '@ox_lib/init.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
}

client_scripts {
    'client/main.lua',
}

-- Everything the client `require`s or the NUI loads must be listed here.
-- config/server.lua, server/ and migrations/ are deliberately NOT listed:
-- they never leave the server.
files {
    'config/shared.lua',
    'config/client.lua',
    'shared/*.lua',
    'client/*.lua',
    'bridge/target/*.lua',
    'locales/*.json',
    'ui/index.html',
    'ui/assets/*',
    'ui/sdk/*',        -- App SDK for third-party apps (docs/APP_SDK.md)
}

-- Tebex escrow: the files a buyer edits stay readable.
escrow_ignore {
    'config/*.lua',
    'bridge/**/*.lua',
}

dependencies {
    '/server:10731',
    '/onesync',
    'oxmysql',
    'ox_lib',
    'ox_inventory',
}
