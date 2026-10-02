fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'toxic_ipad_hello'
author 'Toxic Scripts'
description 'Toxic iPad App SDK example: one app and one widget'
version '1.0.0'

shared_script '@ox_lib/init.lua'
client_script 'client.lua'
server_script 'server.lua'

-- Everything the tablet loads from this resource must be listed here.
-- No ui_page: the tablet shows these pages inside its own window.
files {
    'web/index.html',
    'web/widget.html',
    'web/icon.svg',
}

dependencies {
    'ox_lib',
    'toxic_ipad',
}
