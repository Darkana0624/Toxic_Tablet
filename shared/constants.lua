---Stable identifiers shared by the server, the client and the tests.
---Error codes are part of the public contract: the NUI localises them as
---`ui.error.<code>` and other resources may compare against them.

local constants = {}

constants.RESOURCE = 'toxic_ipad'
constants.SDK_VERSION = 1

constants.ERR = {
    no_session = 'no_session',
    device_gone = 'device_gone',
    locked = 'locked',
    rate_limited = 'rate_limited',
    bad_request = 'bad_request',
    not_owner = 'not_owner',
    wrong_passcode = 'wrong_passcode',
    lockout = 'lockout',
    passcode_required = 'passcode_required',
    no_passcode = 'no_passcode',
    face_unavailable = 'face_unavailable',
    battery_empty = 'battery_empty',
    cannot_use = 'cannot_use',
    already_open = 'already_open',
    no_device = 'no_device',
    not_loaded = 'not_loaded',
    internal = 'internal',
    not_found = 'not_found',
    not_installed = 'not_installed',
    not_removable = 'not_removable',
    app_id_taken = 'app_id_taken',
    permission_denied = 'permission_denied',
    busy = 'busy',
    in_use = 'in_use',
    camera_unavailable = 'camera_unavailable',
    upload_failed = 'upload_failed',
    bad_ticket = 'bad_ticket',
    bad_url = 'bad_url',
    photos_full = 'photos_full',
    storage_full = 'storage_full',
    no_powerbank = 'no_powerbank',
    already_charging = 'already_charging',
    battery_full = 'battery_full',
    lost = 'lost',
}

---Every client-reachable callback, with its rate bucket. The guard refuses
---to register a name that is not listed here, so this table IS the
---complete client-reachable surface (docs/SECURITY.md §2).
constants.CALLBACKS = {
    ['device:unlock'] = 'unlock',
    ['device:setPasscode'] = 'passcode',
    ['device:lock'] = 'power',
    ['settings:patch'] = 'settings',
    ['notes:list'] = 'notes',
    ['notes:save'] = 'notes',
    ['notes:delete'] = 'notes',
    ['notif:read'] = 'notif',
    ['notif:clear'] = 'notif',
    ['notif:list'] = 'notif',
    ['apps:store'] = 'apps',
    ['apps:install'] = 'apps',
    ['apps:uninstall'] = 'apps',
    ['apps:permission'] = 'apps',
    ['appdata:get'] = 'appdata',
    ['appdata:set'] = 'appdata',
    ['appdata:remove'] = 'appdata',
    ['files:list'] = 'files',
    ['files:recents'] = 'files',
    ['files:mkdir'] = 'files',
    ['files:rename'] = 'files',
    ['files:move'] = 'files',
    ['files:delete'] = 'files',
    ['files:saveNote'] = 'files',
    ['device:storage'] = 'storage',
    ['photos:ticket'] = 'camera',
    ['photos:save'] = 'camera',
    ['photos:capture'] = 'camera',
    ['photos:list'] = 'photos',
    ['photos:get'] = 'photos',
    ['photos:delete'] = 'photos',
    ['photos:favorite'] = 'photos',
    ['photos:toFiles'] = 'photos',
    ['battery:info'] = 'power',
    ['battery:powerbank'] = 'power',
    ['findmy:list'] = 'findmy',
    ['findmy:lost'] = 'findmy',
    ['findmy:erase'] = 'findmy',
    ['device:erase'] = 'passcode',
}

---Serial format: TXP-XXXXXXXXXX (32-symbol alphabet without I/L/O/U; 10
---characters keep the chance of two random serials colliding negligible
---even with 100 000 tablets: ~4e-6).
constants.SERIAL_ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'
constants.SERIAL_PATTERN = 'TXP%-[0-9A-HJKMNP-TV-Z]+'
constants.SERIAL_LENGTH = 10

return constants
