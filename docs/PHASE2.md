# TOXIC iPAD — PHASE 2 ARCHITECTURE (post-MVP features)

Status: **approved 2026-09-28** (decisions in §7). **M4 implemented in 0.5.0, M5 in 0.6.0, M6 in 0.7.0** (in-game tests: docs/TESTING-M4/M5/M6.md). Phase 2 is complete. Base: 0.4.0 (MVP complete, hardened). Pipeline: architecture → database → integrations → implementation → UI → security → performance → review → docs → release, per milestone.

Phase 2 = the features the MVP documents deferred "to Phase 2": photos, charging, device ownership tools, richer multitasking, portrait, widget data. Money/paid apps stay Phase 4, qb-core/ESX Phase 8.

---

## 1. Milestones

| Milestone | Version | Scope |
|---|---|---|
| **M4 — Camera & Photos** | 0.5.0 | Camera app (rear + selfie), Photos app (grid, viewer, delete, Save to Files), uploader adapters, `UpdateWidget` export for third-party widgets, SDK `ipad.photos.pick()` |
| **M5 — Power & ownership** | 0.6.0 | Charging modes (passive / stations / power bank), **Find My** app (last location, Lost Mode, remote erase), Settings › Erase All Content & ownership transfer, admin `/ipadwipe` |
| **M6 — Multitasking & orientation** | 0.7.0 | Split View ratios (⅓ · ½ · ⅔ by dragging the divider), Slide Over, portrait orientation (rotate button + Control Center lock) |

Each milestone is deployed and tested in-game before the next starts. Controller/gamepad navigation stays in the backlog.

---

## 2. M4 — Camera & Photos

### 2.1 How a photo is taken
FiveM cannot capture the game from NUI. The standard resource **screenshot-basic** (citizenfx) captures the frame on the client and uploads it as `multipart/form-data`:
`exports['screenshot-basic']:requestScreenshotUpload(url, field, { encoding = 'jpg', quality = 0.85 }, cb)` ([README](https://github.com/citizenfx/screenshot-basic)).

Flow (the upload key never reaches a client):
1. Player opens **Camera** → the tablet slides away, a scripted camera takes over (rear: over the shoulder / selfie: in front of the face), minimal HUD: shutter, flip, zoom (FOV), exit.
2. Shutter → client asks the server `photos:ticket`.
3. Server (rate-limited, session + unlocked + camera permission of the Camera app) asks the **uploader adapter** for a one-time upload target.
   - **Fivemanage** (recommended): `GET https://api.fivemanage.com/api/v3/file/presigned-url` with `Authorization: <token>` → `data.presignedUrl` ([docs](https://docs.fivemanage.com/guides/uploading-files/presigned-urls)). Token from convar `toxic_ipad:fivemanage_token`, never from config files.
   - **Custom**: an upload URL + field the owner hosts (their own server/proxy); documented as "must not require a secret on the client".
   - **None**: Camera app hidden.
4. Client uploads with screenshot-basic to that target, gets the response, sends `photos:save { ticket, url }`.
5. Server checks: ticket issued to this player, unused, < 60 s old; URL host is in the adapter's allow-list (e.g. `r2.fivemanage.com`, `cdn.fivemanage.com`); stores the photo.

### 2.2 Data (migration 0003)
```sql
CREATE TABLE IF NOT EXISTS toxic_ipad_photos (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  device_id BIGINT UNSIGNED NOT NULL,
  url VARCHAR(255) NOT NULL,
  selfie TINYINT(1) NOT NULL DEFAULT 0,
  size_bytes INT UNSIGNED NOT NULL DEFAULT 0,          -- virtual, counts toward storage
  location VARCHAR(80) NULL,                            -- street name at capture (optional, config)
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY idx_photos_device_time (device_id, created_at),
  CONSTRAINT fk_photos_device FOREIGN KEY (device_id) REFERENCES toxic_ipad_devices (id) ON DELETE CASCADE
);
```
Limits: `maxPhotos` per device (default 500), photos per minute (default 6). Deleting removes the row only (the file on the CDN is not deleted — documented; Fivemanage deletion needs the secret and is optional via adapter `delete`).

### 2.3 Apps and API
- **Photos**: Library grid (newest first, lazy images), viewer with swipe, delete (confirm), Save to Files (`ref = 'photo:<id>'`, opens in Photos), Recents album; storage counts photos.
- **SDK**: `ipad.photos.pick()` → system picker sheet in the OS → returns `{ id, url }` of the chosen photo to the app (requires the app's `photos` permission). Lets MDT/marketplace apps attach pictures.
- **Export** `GetPhotos(target, limit)` (server) for other resources (e.g. evidence systems).
- **`UpdateWidget(target, widgetId, data)`** — pushes JSON data (≤ 8 KB) to that widget on open tablets; the widget receives it via `ipad.on('data', fn)`; last value cached per device while the tablet is open.

### 2.4 Security
Server-issued one-time tickets; host allow-list; the Camera app's `camera` permission and Photos' `photos` permission use the existing permission system; rate limits; no upload secret on clients; photo URLs are rendered as `<img>` only (no HTML).

---

## 3. M5 — Power & ownership

### 3.1 Charging (`config/shared.lua` `battery.charging`)
| Mode | Behaviour |
|---|---|
| `passive` (default, current) | charges while put away (`closedPerHour`) |
| `stations` | charges only at charging spots: ox_target zones from config (coords + label, optional job) and/or target models (e.g. wall sockets). Server starts a charging state for the device; it stops when the player leaves the zone (server distance check every 15 s with OneSync coordinates) |
| + **power bank** (existing server item, shared with codem-phone) | *Charge with Power Bank* in the tablet: the server removes one item (`battery.powerBank.item`) and adds `battery.powerBank.percent`. The item's own use handler (codem-phone) is not touched. |

ox_target becomes an **optional** dependency (only for `stations`), behind the existing bridge pattern.

### 3.2 Find My (new app) and device ownership
- The server records **last seen** (street + coordinates) when a tablet is put away or its holder disconnects — new table `toxic_ipad_device_status (device_id PK, lost TINYINT, lost_message VARCHAR(120), last_x/last_y/last_z FLOAT, last_street VARCHAR(80), last_seen TIMESTAMP)`.
- **Find My** lists every tablet the character **owns** (by identifier): last seen, "Directions" (GPS waypoint), **Lost Mode** (the lost tablet shows the owner's message and cannot be unlocked by others, Face ID off), **Erase** (queued; wipes the device's data the next time it is loaded; ownership kept).
- **Settings › General › Transfer or Reset**: owner only, passcode required: *Erase All Content* (data wiped, device keeps owner) and *Remove Owner* (next user becomes owner — for selling a tablet in RP).
- Admin `/ipadwipe <serial>`.

---

## 4. M6 — Multitasking & orientation
- **Split ratios**: drag the divider to ⅓ / ½ / ⅔ (snap); ratio kept per pair while on screen.
- **Slide Over**: window menu › Slide Over → a floating phone-width window on the right edge; swipe it off-screen and back; one Slide Over window at a time.
- **Portrait**: rotate button in Control Center + orientation lock; the whole geometry (1 rem = 1/64 of the display height) re-derives for portrait; all built-in apps get portrait layouts; SDK context gains `orientation`.

---

## 5. Configuration additions (all optional, safe defaults)
```lua
-- config/server.lua (0.5.0)
photos   = { maxPerDevice = 500, perMinute = 6, perHour = 60, sizeKB = 2400, recordStreet = true },
uploader = { provider = 'fivemanage', fivemanage = { hosts = { 'r2.fivemanage.com' } }, custom = { url, field, urlPath, hosts } },
-- config/client.lua (0.5.0)
camera   = { fovDefault = 50, fovMin = 15, fovMax = 70, zoomStep = 5, sensitivity = 8, selfieDistance = 0.55, quality = 0.85 },
-- config/shared.lua (0.6.0)
battery  = { closedPerHour = 20, powerBank = { enabled = true, item = 'powerbank', percent = 100, perMinute = 5 },
             stations = { enabled = false, perMinute = 3, radius = 1.2, points = { { coords = vec3(...), label = '...' } } } },
findMy   = { enabled = true, waypoint = true },
-- M6 (planned)
display  = { portrait = true },
-- server.cfg
set toxic_ipad:fivemanage_token "…"      -- secret: set, never setr
```
Existing configs keep working unchanged (every new key has a default).

---

## 6. Dependencies
| | Required | Optional |
|---|---|---|
| M4 | — | **screenshot-basic** (Camera only), a Fivemanage account or own upload endpoint |
| M5 | — | **ox_target** (stations mode) |
| M6 | — | — |

---

## 7. Decisions (owner, 2026-09-28)
1. **Photo hosting: Fivemanage** presigned uploads (token in the `toxic_ipad:fivemanage_token` convar). A `custom` adapter stays available for owners with their own endpoint.
2. **Charging:** the server already has a **power bank item** (consumed on use, used by codem-phone). The tablet uses the **same item** without taking over its use handler: *Settings › Battery › Charge with Power Bank* / Control Center — the server removes one item (name in config) and charges the tablet. Passive charging while put away stays configurable (`closedPerHour`, set 0 to disable). Charging stations remain optional.
3. **Find My:** street name + GPS waypoint to the last seen location.
4. **Order:** M4 → M5 → M6.
