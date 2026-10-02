# Changelog

## 0.7.3 — 2026-09-28 (camera fix)
- **Faster, reliable photos with screencapture.** Photos were sent as PNG: screencapture turns the `jpg` encoding into the canvas type `image/jpg`, which Chromium does not know, so it silently made multi-megabyte PNGs — slow to send, and Fivemanage sometimes closed the connection mid-upload (`write EPIPE`), after which screencapture never answered and the camera waited 30 s. Now:
  - photos are **WebP** (`uploader.fivemanage.encoding`, `quality = 0.8`) at **1280 × 720** by default — usually 10–20 × smaller;
  - the server takes the frame with `exports.screencapture:serverCapture` and uploads it itself to Fivemanage's base64 endpoint (`POST /api/v3/file/base64`), sees every HTTP status and **retries once** after a network or server failure (not after 401 / 403 / 413);
  - the viewfinder comes back as soon as the frame is taken; the thumbnail shows a spinner until the photo is stored;
  - waits are capped at 15 s for the frame and 20 s per upload attempt, with a precise console reason.
- Client uploads (without screencapture) are WebP too; Save to Files names the file after the photo's real type (`.webp`, `.jpg`, `.png`).
- New config: `config/server.lua` `uploader.fivemanage.encoding`, `quality`; `maxWidth` / `maxHeight` now default to 1280 × 720.

## 0.7.2 — 2026-09-28
- The Fivemanage API token is set in `config/server.lua` (`uploader.fivemanage.token`) — a server-only file, never sent to clients. The `toxic_ipad:fivemanage_token` convar still works and wins when set.

## 0.7.1 — 2026-09-28 (camera fix)
- **Server capture with `screencapture`**: when the `screencapture` resource (Fivemanage's replacement for screenshot-basic) is started, the server captures the player's screen and uploads it straight to the Fivemanage API (`exports.screencapture:remoteUpload`). Fixes uploads failing with `write EPIPE` on presigned URLs through screencapture's proxy, and no upload address reaches a client any more — the stored address is always the one Fivemanage returned to the server.
- The Camera app now also counts `screencapture` as a capture resource (it provides the screenshot-basic exports).
- `config/server.lua` `uploader.fivemanage.serverCapture` (default `true`), `maxWidth` / `maxHeight`.

## 0.7.0 — 2026-09-28 (Phase 2 · M6 Multitasking & orientation)
Added:
- **Split View ratios**: drag the divider to ⅓ · ½ · ⅔ (snaps); drag it to an edge to close that side; the ratio of each app pair is remembered.
- **Slide Over**: Window menu › Slide Over floats an app on the right edge over the app underneath; swipe the grabber to put it away, the edge tab brings it back; Full Screen from its menu. One Slide Over window at a time.
- **Portrait**: Control Center › Portrait / Landscape and Rotation Lock; the device turns with an animation; home screen 4 × 6 in portrait (same saved layout); built-in apps use their compact layouts. `config/shared.lua` `display.portrait = false` keeps tablets landscape.
- App SDK: `context.orientation`, `data-orientation` on `<html>`; clicks inside an SDK app give its window the focus (Split View / Slide Over).
Fixes from the independent review: rotation start scale, divider/grabber state after an interrupted drag, window menu closes on an outside click, portrait widget row fits wider aspects, lifecycle `blur` only for the focused window.

## 0.6.0 — 2026-09-28 (Phase 2 · M5 Power & ownership)
Added:
- **Power bank** with an existing inventory item (default `powerbank`, shared with phone resources — the tablet never registers the item's use, it only removes one): Settings › Battery › Use Power Bank; gradual charge (default 100 % at 5 %/min, no drain meanwhile); the remaining charge survives restarts. Opening an empty tablet offers to use a power bank.
- **Charging stations** (optional, ox_target): "Charge Tablet" spots from config; charging stops when the player leaves or no longer carries the tablet.
- **Find My** app: every tablet the character owns — with you / in use now / last seen (street and area), battery, **Directions** (GPS waypoint), **Lost Mode** (lock-screen message; only the owner can unlock, which turns it off), **Erase This Tablet**.
- **Settings › Transfer or Reset Tablet**: Erase All Content and Settings; Erase and Remove Owner (passcode required).
- Admin `/ipadwipe <serial> [owner]`.
- Database: migration `0004_device_status` (last seen, Lost Mode, power bank charge).
Fixes from the independent review: no double battery drain when a charge ends; station charging of a pocketed tablet is saved; no charging when the battery simulation is off; an erase cannot race an open; photo tickets and station charges end with an erase; Find My battery includes a saved power bank charge; the power bank is not spent when the player cannot open the tablet; a tablet whose session ended server-side puts itself away.
Upgrade note: copy the new entries of `config/apps.lua` (camera, photos, findmy) and the new `battery.powerBank`, `battery.stations`, `findMy` blocks of `config/shared.lua` into your config — the console warns about missing apps.

## 0.5.0 — 2026-09-28 (Phase 2 · M4 Camera & Photos)
Added:
- **Camera** app: rear and selfie camera with mouse aim, zoom (mouse wheel), flip (E), shutter (left click / Enter), exit (Backspace / Esc / right click); the tablet steps aside and a viewfinder overlay shows mode, zoom, the last photo and key hints. Needs **screenshot-basic** and an uploader; hidden automatically otherwise.
- **Uploader bridge** (`bridge/uploader/`): **Fivemanage** presigned uploads (token in the server convar `toxic_ipad:fivemanage_token`, never sent to clients), your own endpoint (`custom`), or `none`.
- **Photos** app: library (newest first, paged), All / Favorites / Selfies, select & delete, viewer (swipe, arrows, date, street), Favorite, Save to Files, `/photo/<id>` deep links; Files opens saved photos in Photos; Settings › Storage counts photos.
- **App SDK**: `ipad.photos.pick()` (system picker; needs the `photos` permission; the app receives only the chosen photo) and widget data: `ipad.on('data')` / `ipad.data`.
- **Exports**: `GetPhotos(target, limit)`, `UpdateWidget(target, widgetId, data)`.
- Example `toxic_ipad_hello`: "Pick a photo" and a live tap counter in its widget via `UpdateWidget`.
- Database: migration `0003_photos` (applied automatically).
Security: one-time upload tickets (per player, per tablet, 60 s, single use), host allow-list for stored photo URLs, per-tablet limits per minute / hour and photo count, storage checked before an upload is allowed; third-party apps cannot open the Camera; the picker never shows on a locked tablet.
Config: `config/server.lua` `photos`, `uploader`, rate buckets `camera`, `photos`; `config/client.lua` `camera`.

## 0.4.0 — 2026-09-28 (release hardening)
Security (independent audit):
- One request per device at a time on the server: app-data quota, note/file limits and folder moves can no longer be raced.
- A locked tablet receives notifications redacted (no message; title only with previews on); the full list is loaded after unlock.
- Per-open token for the tablet's own NUI callbacks: third-party app iframes cannot drive the tablet.
- Duplicated tablet items (same serial) cannot be open by two players (`in_use`, logged).
- Taking a tablet from a player ends that player's session at once.
- Folder moves check the height of the moved tree; recursive queries are depth-bounded; `files.maxDepth` capped at 12.
- App/widget ids stay bound to their first resource; external origins are lower-cased.
- The client keybind is accepted only when `config/server.lua` `allowKeybindOpen = true`.
Performance and fixes (independent review):
- Fixed an endless re-render of the date hook that ran even while the tablet was put away.
- Apps and widgets are suspended while the tablet is put away.
- Dragging icons no longer re-renders the whole home screen; brightness sliders no longer re-render every app.
- Opening the tablet again during the close animation no longer leaves a stuck session.
- One cache-expiry timer per device; battery shutdown timers no longer pile up; New Folder is one request.
- A settings reply no longer undoes a home-screen change that was still being saved.
Added: client exports `IsOpen`, `Close`, `OpenApp`. Docs: installation/update/troubleshooting, security model refreshed.

## 0.3.0 — 2026-09-27 (milestone 3, development build)
- **App SDK**: `RegisterApp`, `UnregisterApp`, `RegisterWidget`, `OpenApp`, `HasPermission`, `SaveFile`; third-party apps and widgets run in a sandboxed iframe of their own resource with `toxic-ipad-sdk.js` (context, lifecycle, routes, storage, confirm, toast, badge, permissions). Example resource `examples/toxic_ipad_hello`.
- **App Store**: catalogue per player (job access), Get / Open / Delete, app pages with version, size, developer and requested permissions.
- **Files**: Recents, Documents, Downloads, folders, rename, move, delete, grid/list; opens notes and app references; Notes › Save to Files.
- **Home screen**: edit mode (press and hold), drag to reorder and to/from the dock, folders (drop an app on another), delete apps, widget column with Clock, Battery and third-party widgets, widget gallery.
- **Settings**: Home Screen & Widgets (edit, reset), Privacy & Security (permissions per app), Tablet Storage (usage breakdown); deep links (`/battery`, `/privacy`…).
- In-tablet toasts; OpenApp on a closed tablet launches the app after unlock.
- Database: migration `0002_app_removals` (applied automatically).

## 0.2.0 — 2026-09-27 (milestone 2, development build)
- App Registry (server-filtered, `config/apps.lua`, optional group access) and a home screen with pages, dock and unread badges.
- Window Manager: launch zoom from the icon, home gesture (drag the bottom bar), app switcher (drag up and hold, or F3), 50/50 Split View from the window "⋯" menu, one crashing app shows "temporarily unavailable" instead of breaking the OS.
- Built-in apps: Settings (display, wallpaper, sounds, notifications, battery, Face ID & passcode, accessibility, about), Notes (server-saved, search, pin, autosave), Calculator (with operator precedence), Clock (city/local time, stopwatch).
- Notifications: `exports.toxic_ipad:Notify(target, data)`, stored per device (last 200), banners, Notification Center (F1 / pull down top-left), Do Not Disturb and per-app switches.
- Control Center (F2 / pull down top-right): dark mode, Do Not Disturb, Low Power, brightness, volume, lock.
- New wallpapers: Dune, Lagoon, Graphite. `/ipadnotify` test command.
- Fixes (found in-game): NUI messages from the parent frame were ignored; the screen stayed black with Windows animations turned off.

## 0.1.0 — 2026-09-27 (milestone 1, development build)
- Resource foundation: config (shared/client/server), locales en/mn, pure shared modules with unit tests.
- Framework bridge: Qbox (qbx_core) live; toxic_core adapter written against API v1, enabled automatically when available.
- ox_inventory: tablet item opens through a server export; serials stamped on item creation; boot check for `consume = 0` / `stack = false`; sessions follow the item and end when it leaves the player.
- Devices: database schema + migration runner, per-device cache, battery model without ticks, bcrypt passcode with escalating lockout, validated settings document.
- Security: single guard for every client request (rate limit → session → item still held → lock state → schema).
- NUI (React/TypeScript, Chromium 103 target): 80 % floating device with correct aspect ratio at every resolution, open/close spring animation, lock screen with swipe/Enter, passcode keypad, simulated Face ID (owner only), power and volume buttons, auto-lock, status bar, low-battery alert.
- Admin commands `/ipadgive`, `/ipadpin`.
