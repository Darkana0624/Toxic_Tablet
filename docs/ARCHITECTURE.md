# TOXIC iPAD — ARCHITECTURE (MVP v0.1, designed for 1.x)

Status: Phase 1 draft for approval. Companion documents: RESEARCH, UI_SYSTEM, APP_SDK, WINDOW_MANAGER, DATABASE, SECURITY, PERFORMANCE, DECISIONS.

Resource name: **`toxic_ipad`** · Lua 5.4 · FXServer 10731+ · OneSync · ox_lib · oxmysql · ox_inventory · Qbox (live MVP target) / toxic_core (primary, enabled when its API ships).

---

## 1. Principles for this resource

1. **The server owns the device.** Ownership, passcode, installed apps, notes, files, settings, notifications and battery are server state. The NUI is a renderer that asks.
2. **The item is the device.** A tablet is one ox_inventory item instance with a serial in its metadata. Data follows the device, not the character (D1).
3. **Apps are guests.** The OS never trusts, imports or shares a JS heap with third-party code. External apps run in iframes from their own resource (APP_SDK). Built-in apps use the same registry and lifecycle contract as external ones.
4. **Adapters at the edge.** Framework, inventory and future phone/banking code live in `bridge/`. Nothing outside `bridge/` names `qbx_core`, `toxic_core` or `ox_inventory`.
5. **Zero cost when closed.** No thread, no timer, no NUI work while the tablet is closed (PERFORMANCE).
6. **Small, complete MVP.** Every subsystem in §78A exists and works; nothing outside it is started.

---

## 2. Layer model

```
                           ┌────────────────────────────────────┐
  CLIENT (Lua)             │  device controller (open/close,    │
                           │  prop, anim, focus, world blur)    │
                           │  nui bridge (callbacks → server)   │
                           └───────────────┬────────────────────┘
                                           │ SendNUIMessage / RegisterNUICallback
  NUI (React/TS)  ┌────────────────────────▼─────────────────────────────┐
                  │ Device Layer   frame · display · boot/lock · power     │
                  │ System UI      status bar · home · dock · CC · NC      │
                  │ Window Manager windows · recents · split · lifecycle   │
                  │ App Host       built-in (lazy React) │ external (iframe)│
                  │ Stores         device·system·window·app·user·network   │
                  └────────────────────────┬─────────────────────────────┘
                                           │ lib.callback (validated)
  SERVER (Lua)    ┌────────────────────────▼─────────────────────────────┐
                  │ session (who holds which device, open/closed)         │
                  │ devices · settings · apps(registry+installs) · notif. │
                  │ notes · files · app_data · battery · security(guard)  │
                  │ cache (per-device, dirty flush) · storage (SQL)       │
                  └──────────┬───────────────────────────┬──────────────┘
                             │                           │
                  bridge/framework/*             bridge/inventory/*
                  (toxic_core | qbox | qb | esx) (ox_inventory)
```

---

## 3. Resource layout

Adjusted from master prompt §77 after research (reasons in the right column).

```
toxic_ipad/
├── fxmanifest.lua
├── config/
│   ├── shared.lua        -- device models, display, battery, storage, features
│   ├── client.lua        -- prop, anim, keybind, world blur, sounds
│   ├── server.lua        -- limits, rate limits, retention, admin ACE
│   ├── apps.lua          -- built-in app list + App Store catalog
│   └── theme.lua         -- colour/radius tokens pushed to NUI (no rebuild)
├── shared/
│   ├── constants.lua     -- error codes, event names, limits
│   └── validate.lua      -- pure validators (unit-tested)
├── bridge/
│   ├── framework/
│   │   ├── init.lua      -- detection order: toxic_core → qbox → qb → esx
│   │   ├── toxic_core.lua
│   │   ├── qbox.lua
│   │   ├── qbcore.lua    -- Phase 8 (interface stub fails loudly if selected)
│   │   └── esx.lua       -- Phase 8
│   └── inventory/
│       ├── init.lua
│       └── ox_inventory.lua
├── server/
│   ├── main.lua          -- boot, exports, resource stop
│   ├── session.lua       -- open sessions, holder ↔ device binding
│   ├── device.lua        -- device records, lock/unlock, passcode, power
│   ├── battery.lua       -- lazy battery model
│   ├── settings.lua      -- schema-validated settings document
│   ├── apps.lua          -- App Registry (server side) + installs + store
│   ├── notifications.lua
│   ├── notes.lua
│   ├── files.lua
│   ├── appdata.lua       -- namespaced KV for apps (SDK storage)
│   ├── guard.lua         -- rate limit + schema + session checks for every callback
│   ├── cache.lua         -- per-device cache, dirty tracking, flush
│   └── storage/          -- all SQL (one file per table family)
├── client/
│   ├── main.lua
│   ├── device.lua        -- open/close state machine
│   ├── prop.lua          -- prop + anim
│   ├── world.lua         -- screen blur / timecycle
│   └── nui.lua           -- NUI callbacks → lib.callback
├── migrations/           -- versioned SQL, same runner rules as toxic_core
├── locales/              -- en.json, mn.json (Lua + NUI share them)
├── web/                  -- NUI source (not served)
│   └── src/{device,system,window,apps,widgets,components,stores,sdk,bridge,motion,i18n}
├── ui/                   -- built NUI (served, committed; the repo ignores dist/)
├── sdk/
│   └── toxic-ipad-sdk.js -- served to iframe apps (APP_SDK §3)
├── tests/                -- lua5.4 unit tests (pure modules), vitest for web
└── docs/
```

Changes vs §77: `bridge/phone` and `bridge/banking` are **not created** in MVP (no code to put there); `database/schema.sql` becomes `migrations/` (versioned, like toxic_core); `config/locales` merged into `locales/` so Lua and NUI share one set of files.

---

## 4. Runtime flows

### 4.1 Open (MVP §78A.13)
```
player uses item in ox_inventory
  → ox_inventory calls exports.toxic_ipad:useItem('usingItem', item, inv, slot)   [server]
      guard: player loaded? not already open? not dead/cuffed (bridge)? rate limit
      device = devices.resolve(item.metadata.serial)   -- creates the row on first use
      session.open(src, device.id, slot)                -- binding the holder to THIS slot
      return false  (cancel ox_inventory's own use flow: nothing to consume, no client item anim)
  → TriggerClientEvent('toxic_ipad:client:open', src, bootPayload)
      client: anim + prop → world blur → SetNuiFocus(true,true) → NUI 'open' with bootPayload
      NUI: power-on animation → lock screen
```
`bootPayload` = device summary, settings, installed app list (already filtered for this player), unread notification count, theme, locale strings version. One message; no follow-up fetch before the lock screen can render.

### 4.2 Close
Every close path — Esc, home-gesture-from-home, power button, item removed, player died, resource stop — calls the single client `closeDevice(reason)`:
NUI exit animation (350 ms) → `SetNuiFocus(false,false)` → world blur off → prop removed → `toxic_ipad:server:closed` (server ends the session, flushes dirty data, stamps battery).
`onResourceStop` releases focus and deletes the prop without waiting for animations.

### 4.3 Operation (example: save a note)
```
NUI  fetchNui('notes:save', {id?, title, body})
Lua  RegisterNUICallback → lib.callback.await('toxic_ipad:server:notes:save', …)
SRV  guard(src, 'notes:save', payload)   -- session exists, slot still holds the serial, schema, rate
     notes.save(session.deviceId, payload) → cache → debounced SQL write
     return { ok = true, note = … } | { ok = false, err = 'code' }
NUI  optimistic UI already shown; reconciles on reply; toast on error (localized from code)
```
The client never sends a `deviceId`. The server derives it from the session.

---

## 5. Device model

- **Serial**: stamped into item metadata by the `createItem` hook: `TXP-` + 10 characters from a 32-symbol alphabet (the hook cannot query the database, so the space is large enough that a collision is negligible: ~4e-6 at 100 000 tablets). Older items without metadata get one on first use via `SetMetadata`.
- **Device row** created on first use: `serial`, `model`, `storage_capacity`, `battery`, `battery_health`, `owner_identifier` (the first user), passcode hash, lock state.
- **Owner vs holder**: the holder is whoever has the item open; the owner is recorded. A non-owner holder sees the lock screen and needs the passcode (Face ID refuses). A device with no passcode opens for anyone — same as a real tablet. Device transfer / Lost Mode / remote wipe are Phase 2+, but the columns exist.
- **Metadata shown in inventory**: `serial`, `label` ("Toxic iPad Pro · 512 GB"), `description` — refreshed on change.
- Models come from `config/shared.lua`:
```lua
models = {
    toxic_ipad = { label = 'Toxic iPad Pro', chip = 'M5-class', storageGB = 512,
                   os = 'Toxic iPadOS 27', aspect = 4/3 },
}
```
(the key is the ox_inventory item name, so a server can sell several models).

---

## 6. Bridges

### 6.1 Framework interface (server)
```lua
Framework.name                          -- 'toxic_core' | 'qbox' | 'qbcore' | 'esx'
Framework.getIdentifier(src)  -> string?            -- stable character id
Framework.getName(src)        -> { first, last }?
Framework.isLoaded(src)       -> boolean
Framework.hasGroup(src, filter) -> boolean          -- filter: string | string[] | { [name]=minGrade }
Framework.canUseDevice(src)   -> boolean            -- dead / cuffed / etc.
Framework.onLoaded(fn(src))   Framework.onUnloaded(fn(src))
```
Money (`GetMoney/AddMoney/RemoveMoney`) is **not in the MVP interface**: no MVP feature spends money (paid apps are out of scope, §78A.19). It is added with the paid App Store in Phase 4 — adding an unused money path now would be an untested exploit surface.

| Function | toxic_core (spec §6) | qbox (qbx_core 1.24) |
|---|---|---|
| getIdentifier | `Toxic.Character.get(src).publicId` | `GetPlayer(src).PlayerData.citizenid` |
| getName | `Toxic.Character.getName(src)` | `PlayerData.charinfo.firstname/lastname` |
| isLoaded | `Toxic.Session.isLoaded(src)` | `GetPlayer(src) ~= nil` |
| hasGroup | `Toxic.Groups.has(src, query)` | `HasGroup(src, filter)` |
| onLoaded / onUnloaded | `toxic_core:characterLoaded` / `characterUnloaded` | `QBCore:Server:PlayerLoaded` / `QBCore:Server:OnPlayerUnload` |

Detection: config `framework = 'auto' | 'toxic_core' | 'qbox' | ...`. `auto` checks `GetResourceState` once at boot in the order toxic_core → qbx_core → qb-core → es_extended; toxic_core is chosen only when `exports.toxic_core:Core_apiVersion() == 1` (spec §6.1 flat export naming).

### 6.2 Inventory interface (server)
```lua
Inventory.getSlot(src, slot)                   -> { name, metadata }?
Inventory.setMetadata(src, slot, metadata)
Inventory.slotHoldsSerial(src, slot, serial)   -> boolean   -- used by guard
Inventory.registerSerialHook(itemNames)        -- createItem hook
Inventory.onRemoved(fn(src, serial))           -- swapItems/drop hook → close session
```
Only `ox_inventory.lua` is implemented in MVP. `AddItem/RemoveItem/GetItemCount/HasItem` from §51 are added when a feature needs them (none in MVP).

---

## 7. Public API (MVP)

Server exports. All return plain data; mutations return `ok, err`.

| Export | Signature | Notes |
|---|---|---|
| `RegisterApp` | `(def) → ok, err` | APP_SDK §2. Owner = `GetInvokingResource()`; auto-removed when it stops. |
| `UnregisterApp` | `(appId) → ok` | owner only |
| `RegisterWidget` | `(def) → ok, err` | APP_SDK §5 |
| `Notify` | `(target, data) → ok, err` | **target added** (see below) |
| `Open` | `(src) → ok, err` | opens the tablet the player carries (first slot holding one) |
| `Close` | `(src) → ok` | |
| `IsOpen` | `(src) → boolean` | |
| `OpenApp` | `(src, appId, route?) → ok, err` | opens the device if needed; `route` is passed to the app |
| `GetDevice` | `(src) → DeviceInfo?` | the open device, else the first carried device |
| `SdkVersion` | `() → integer` | `1` (APP_SDK §8) |
| `HasPermission` | `(src, appId, permission) → boolean` | the open tablet's answer (APP_SDK §3.5) — added in 0.3.0 |
| `SaveFile` | `(target, data) → ok, err` | virtual file into Documents/Downloads (APP_SDK §7) — added in 0.3.0 |
| `useItem` | ox_inventory callback | not for other resources |

**Deviation from §66 / §78A.15:** the spec's `Notify(data)` has no recipient. A server export needs one, so the signature is `Notify(target, data)` where `target` is a player source, `{ identifier = '...' }` (all devices owned by that character) or `{ serial = '...' }`. Notifications for an offline or closed device are stored (if the app allows persistence) and shown on next open.

Client exports (own tablet only): `IsOpen()`, `Close()`, `OpenApp(appId, route?)` — each goes through the server; the client cannot open a device it does not carry. *(Implemented in 0.4.0; `OpenApp` travels as the `toxic_ipad:server:openApp` net event with the same checks as the server export.)*

---

## 8. Configuration outline

```lua
-- config/shared.lua
return {
    framework = 'auto',
    item = { name = 'toxic_ipad' },               -- model table keyed by item name (§5)
    display = {
        size = 0.80,                              -- 0.75 | 0.80 | 0.85 | 0.90 (clamped)
        overlay = { enabled = true, opacity = 0.15, worldBlur = 'native' },  -- none|native|timecycle
        animation = { openMs = 450, closeMs = 350 },
        orientation = 'landscape',
    },
    lock = { passcodeLengths = { 4, 6 }, maxAttempts = 5, lockoutSeconds = 60, faceId = true },
    battery = { enabled = true, drainPerMinuteOpen = 0.35, drainPerHourClosed = 0.5,
                lowPowerMultiplier = 0.6, shutdownAt = 0 },
    storage = { warnAtPercent = 90 },
    clock = { source = 'game' },                  -- game | real
    multitasking = { recents = 6, maxLiveFrames = 4, splitView = true },
}
```
Full keys and comments go in CONFIGURATION.md (Phase 10). Server-only limits (rate limits, text lengths, retention) live in `config/server.lua`.

---

## 9. Localization

`locales/en.json` and `locales/mn.json` hold **both** Lua and NUI keys (`ui.*` namespace for the NUI). Lua uses ox_lib `locale()`. The NUI receives the active locale table once in `bootPayload` (cached by version hash; not resent on every open). No string in TSX; lint rule forbids JSX text literals. Error codes map to `error.<code>` keys.

---

## 10. MVP build order (maps §78A.22 to files)

| # | Step | Main files |
|---|---|---|
| 1–2 | Resource foundation, config | fxmanifest, config/*, shared/* |
| 3 | Framework bridge | bridge/framework/* |
| 4 | ox_inventory | bridge/inventory/*, server `useItem` |
| 5–6 | Device state, database | server/device, session, cache, storage, migrations |
| 7–8 | NUI root, 80 % device | web/src/device |
| 9–10 | Lock, home | web/src/system |
| 11–12 | App Registry, Window Manager | server/apps, web/src/window, web/src/apps/host |
| 13–19 | Settings, Notifications, Notes, Calculator, Clock, Files, App Store | web/src/apps/*, server/* |
| 20–24 | Dock, widgets, CC, recents, split | web/src/system, window |
| 25–29 | Security, performance, integration test, docs, release | tests/, docs/ |

Each step ends with: unit tests green, browser preview (mock bridge) clean, and — from step 4 on — an in-game smoke test on the Qbox dev server.

---

## 11. Implementation notes (milestone 1, 2026-09-27)
- NUI build output lives in `ui/` (not `dist/`), because the monorepo `.gitignore` excludes `dist/` and the built UI must ship with the resource.
- Battery while put away: `closedPerHour` (default +20 %/h) — the tablet charges off-screen until charging stations exist; a negative value drains instead.
- Admin/support commands: `/ipadgive <id> [item]`, `/ipadpin <id> [pin]` (ACE `group.admin`).
- The optional keybind uses one extra net event `toxic_ipad:server:requestOpen`, rate-limited through the same open path as the item.
- Resource stop writes devices with non-yielding queries (`db.fire`), because an awaited query inside `onResourceStop` may never resume.

## 12. Implementation notes (milestone 2, 2026-09-27)
- Built-in apps are bundled with the OS instead of lazy chunks: in testing, lazily loaded app chunks could leave the Suspense fallback on screen, and bundling avoids a second fetch inside CEF (+25 KB gzip).
- `Notify` is implemented with the `target` argument (DECISIONS D5). Priorities: info, normal, success, warning, critical (stored 0–4). The last 200 per device are kept.
- Recents are not persisted across reconnects yet; windows survive putting the tablet away for up to 5 minutes (the NUI page stays loaded).
- Split View keeps pairs only while on screen; going home and back restores single windows (WINDOW_MANAGER §3 pairs → later).
- Folders, home edit mode, widgets, Files, App Store and the iframe SDK are milestone 3.

## 13. Implementation notes (milestone 3, 2026-09-27)
- **Install state** (DATABASE §2.1): installed = a row in `installed_apps`, or a preinstalled app without a row in the new `app_removals` table. Loaded once per cached device on open (2 queries). Settings and App Store cannot be removed.
- **Registry at load time**: `apps.init` runs when `server/main.lua` loads, so other resources can `RegisterApp` while the boot still waits for the framework/database; `apps.bind` connects framework/storage later. Stopped resources are unregistered on `onResourceStop`; open tablets receive the new lists (debounced 250 ms).
- **iframe SDK**: `web/public/sdk/toxic-ipad-sdk.js` (served at `ui/sdk/`), host `web/src/sdk/FrameHost.tsx`, router checks `event.source` + origin, protocol validation in `sdk/protocol.ts` (unit-tested). Widgets use a reduced request set.
- **Home screen** (`web/src/home/`): pure layout functions (`layout.ts`, unit-tested) + edit mode with drag & drop, folders (`folder_<n>` ids), a widget column on page 1 (first page holds 16 icons when widgets are shown). The layout is saved debounced (600 ms) and replaced, not merged, so removed folders disappear.
- **Files**: virtual entries only; roots Documents/Downloads created on first use; recursive CTEs for subtree size and ancestors (MariaDB 10.2+ / MySQL 8); limits in `config/server.lua` (`files.maxEntries`, `files.maxDepth`).
- **Storage** (Settings › Tablet Storage) is computed on request: notes bytes (SUM), files (cached count/bytes), app data per app, plus the model's virtual `systemGB`.
- Known limits: widgets cannot be reordered by drag (remove and add again); apps inside a folder are reordered only by taking them out; frame widgets do not enter edit mode on long-press (press elsewhere on the home screen).
