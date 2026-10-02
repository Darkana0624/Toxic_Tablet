# Toxic iPad — Installation (0.6.0)

## Requirements
| Dependency | Tested |
|---|---|
| FXServer | build 10731+, OneSync on |
| ox_lib | 3.39+ |
| oxmysql | 2.14+ |
| ox_inventory | 2.44.8+ (tested 2.44.8 and 2.47.9) |
| OneSync | required (server-side positions: Find My, charging stations) |
| Framework | qbx_core 1.24+ (toxic_core is used automatically once its API v1 ships) |
| Database | **MariaDB ≥ 10.6 or MySQL ≥ 8.0** (the Files app uses recursive queries) |
| Charging stations (optional) | ox_target |
| Camera (optional) | [screenshot-basic](https://github.com/citizenfx/screenshot-basic) + a [Fivemanage](https://fivemanage.com) account (or your own upload endpoint) |

## New install
1. Put the `toxic_ipad` folder in your resources.
2. Add the item from `install/ox_inventory_items.lua` to `ox_inventory/data/items.lua`
   (it must keep `consume = 0` and `stack = false`; the resource checks this at start).
   Copy `install/toxic_ipad.png` to `ox_inventory/web/images/`.
3. `server.cfg` — after the framework and ox resources:
   ```cfg
   ensure oxmysql
   ensure ox_lib
   ensure qbx_core
   ensure ox_inventory
   ensure screenshot-basic                   # optional: Camera app
   ensure toxic_ipad
   # optional
   # ensure toxic_ipad_hello                 # the App SDK example (copy examples/toxic_ipad_hello next to toxic_ipad)
   # setr toxic_ipad:debug "true"            # debug logs + the ipad_blur command
   # set  toxic_ipad:webhook "https://discord.com/api/webhooks/..."   # security events
   ```
4. Start the server. Tables are created automatically (`database migrations applied versions=1,2,3,4`).
5. Give yourself a tablet: `/ipadgive <your id>` (needs `group.admin`), then use it from the inventory.

## Updating from an earlier version
1. Stop the server (or `stop toxic_ipad`).
2. Replace the whole `toxic_ipad` folder. Keep a copy of your `config/` files and re-apply your changes to the new ones (new options are added between versions).
3. Start. New migrations run once and are recorded in `toxic_ipad_migrations`; your devices, notes, files and settings are kept.
4. Never edit files in `migrations/` — the resource refuses to start when an applied migration was changed.

## Configuration
- `config/shared.lua` — tablet models (item names, names shown in-game, virtual storage), display size (0.75–0.90, default 0.80), passcode, battery, clock, accent colour.
- `config/client.lua` — world blur (`native` / `timecycle` / `none`), prop and animation, optional keybind, movement while open.
- `config/server.lua` — log level, passcode lockout, rate limits, cache time, Files limits, `allowKeybindOpen` (must be `true` for the client keybind to work), admin ACE.
- `config/apps.lua` — built-in apps (order, job access, removable) and the default dock.

## Camera & Photos
The Camera takes a screenshot of the game with **screenshot-basic** and uploads it to your image host; the tablet stores only the image address.

1. `ensure screencapture` (recommended — Fivemanage's resource) or `screenshot-basic` before `toxic_ipad`. With **screencapture + Fivemanage** the server takes and uploads each photo itself (`uploader.fivemanage.serverCapture = true`, default; WebP 1280 × 720 by default — `encoding`, `quality`, `maxWidth`, `maxHeight`): nothing upload-related reaches clients. Without screencapture, clients upload through one-time presigned URLs. Console at start: `Camera: server capture through screencapture + Fivemanage`.
2. **Fivemanage** (default, `config/server.lua` `uploader.provider = 'fivemanage'`): create an API token in your Fivemanage dashboard and put it in `config/server.lua`:
   ```lua
   fivemanage = { token = 'your-token', ... },
   ```
   `config/server.lua` is server-only (it is not in the manifest's `files`), so players never receive it — just don't share the file. Alternatively `set toxic_ipad:fivemanage_token "..."` in `server.cfg` (use `set`, never `setr`); when set, it is used instead of the config value.
3. **Your own endpoint** (`provider = 'custom'`): `uploader.custom.url` receives the screenshot as `multipart/form-data` (field `field`) and answers JSON with the public https image address at `urlPath`; list the host(s) of those addresses in `hosts` — **only hosts you control** (see SECURITY §4 Photos). The URL reaches clients, so it must not contain a secret.
4. `provider = 'none'` hides the Camera app. Photos stays (library, and apps can still pick existing photos).

The console tells you why the Camera is off (`Camera is off: …`). Limits: `config/server.lua` `photos` (per tablet: 500 photos, 6 per minute, 60 uploads per hour, 2.4 MB virtual size each). Controls and zoom: `config/client.lua` `camera`.

Deleting a photo removes it from the tablet (and its Save-to-Files entries), not from your image host.

## Power bank and charging stations
- `config/shared.lua` `battery.powerBank.item` is an **existing** ox_inventory item (default `powerbank`). It can be the same item a phone resource uses (e.g. codem-phone): the tablet does not register the item's use — using the item from the inventory still charges the phone; the tablet takes one only when the player picks **Settings › Battery › Use Power Bank** or accepts the prompt that appears when an empty tablet is opened.
- One power bank gives `percent` (default 100 %) at `perMinute` (default 5 %/min). The tablet does not drain while it charges; the remaining charge is kept across restarts.
- Passive charging while put away is `battery.closedPerHour` (default +20 %/h). Set it to `0` (or negative) if players should charge only with power banks / stations.
- Stations: set `battery.stations.enabled = true`, add `points = { { coords = vec3(x, y, z), label = 'Café' } }` and ensure `ox_target`. The option "Charge Tablet" charges the tablet in hand (or the first one carried) while the player stays within `radius + 3 m`.

## Find My and resetting
Find My lists every tablet the character owns. Lost Mode locks a tablet for everyone but the owner and shows the owner's message; Erase wipes notes, files, photos, apps and their data, notifications, settings and the passcode. Settings › Transfer or Reset Tablet does the same on the tablet in hand, optionally removing the owner (before giving or selling a tablet). Admins: `/ipadwipe <serial>` (add `owner` to also remove the owner); `/ipadbattery <id> <percent>` for testing. `findMy.enabled = false` hides the app.

## Adding apps from other resources
See [APP_SDK.md](APP_SDK.md) and the example in `examples/toxic_ipad_hello`.

## Troubleshooting
| Symptom | Fix |
|---|---|
| Console: `boot aborted at "items"` | The item is missing from ox_inventory, or it lacks `consume = 0` / `stack = false` / the `server.export`. |
| Console: `boot aborted at "database migrations"` | Read the lines below it: a changed migration file, an older toxic_ipad over a newer database, or a database older than MariaDB 10.6 / MySQL 8. |
| Using the item does nothing, F8 shows `the tablet page did not answer` | The `ui/` folder is incomplete — replace it from the release. |
| A third-party app shows "temporarily unavailable" | Its page does not load `toxic-ipad-sdk.js` or never calls `ToxicIPad.connect()`; its files must be listed in its `fxmanifest.lua` `files {}`. F8 shows `[toxic_ipad:nui] …`. |
| "This tablet is already in use by someone else." | Two items share one serial (copied metadata). Remove the copy. |
| No Find My / Camera / Photos app | Console `config/apps.lua has no "…" app` — copy the new entries from the release's `config/apps.lua`. |
| "Use Power Bank" missing | Console `power bank item "…" is not defined` — add the item or set `battery.powerBank.item`; it also hides when `battery.enabled = false`. |
| No "Charge Tablet" at stations | `battery.stations.enabled = true`, points set, `ox_target` started. |
| No Camera app on the home screen | Console shows `Camera is off: …` — set `uploader.fivemanage.token` in `config/server.lua`, and `ensure screencapture` (or screenshot-basic) before `toxic_ipad`. |
| Console `screencapture … Error uploading file … write EPIPE` (on `presigned-url/…` or `/api/v3/file`), or photos take very long | 0.7.2 or older: update to 0.7.3+ (WebP photos, own upload with retry). |
| Console `photo upload failed: Fivemanage answered HTTP 401/403` | Wrong or revoked token in `config/server.lua` `uploader.fivemanage.token` (or the convar). |
| Console `photo upload failed: Fivemanage answered HTTP 413` | The photo is too large for your plan: lower `uploader.fivemanage.maxWidth` / `maxHeight` or `quality`. |
| Console `photo upload failed: no frame from the player within 15 s` | screencapture could not reach the player's game (see its console lines); try `protocol 'nui'` in screencapture's fxmanifest. |
| Camera: "The photo couldn't be uploaded" | Server console `photo upload target failed: …` (token wrong / Fivemanage down); for `custom`, check the endpoint's JSON answer and `urlPath`. |
| Camera: "unexpected address" | The uploader returned an image URL whose host is not in `uploader.<provider>.hosts`. |

## The NUI
The built interface is in `ui/`. You do not need Node.js to run the resource.
Developers change the source in `web/` and rebuild with `npm ci && npm run build` inside `web/`.
