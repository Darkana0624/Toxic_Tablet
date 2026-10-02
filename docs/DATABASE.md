# TOXIC iPAD — DATABASE (MVP)

MariaDB ≥ 10.6 / MySQL ≥ 8.0 · InnoDB · `utf8mb4` / `utf8mb4_unicode_ci` · oxmysql only · every value parameterised.

MVP tables from §78A.11 plus one justified addition (`files`, because the Files app is in the MVP) and the migration ledger. No other future table is created now.

---

## 1. Conventions
- Prefix `toxic_ipad_`. Surrogate `BIGINT UNSIGNED AUTO_INCREMENT` keys; child rows reference `device_id` with `ON DELETE CASCADE`.
- **No foreign key to framework tables.** `owner_identifier` stores the bridge identifier (Qbox `citizenid`, toxic_core `public_id`) as a plain indexed string, so the resource works on any framework and a character purge never blocks. Character cleanup is done by listening to the framework's delete event (toxic_core `characterPurged`) — Phase 8.
- Timestamps are `TIMESTAMP` (UTC).
- Size limits are enforced **in Lua before SQL** (SECURITY §4) and mirrored by column widths.
- Large binary data never goes into SQL (§57). The MVP stores none: files are virtual entries (name/size/ref); photos arrive in Phase 2 as URLs to an external uploader.

---

## 2. Schema (migration `0001_ipad.sql`, additive and idempotent)

```sql
CREATE TABLE IF NOT EXISTS `toxic_ipad_migrations` (
  `version`    INT UNSIGNED NOT NULL,
  `checksum`   CHAR(64)     NOT NULL,
  `applied_at` TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`version`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `toxic_ipad_devices` (
  `id`                  BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
  `serial`              VARCHAR(16)      NOT NULL,
  `model`               VARCHAR(32)      NOT NULL,
  `owner_identifier`    VARCHAR(64)      NULL,
  `storage_capacity_mb` INT UNSIGNED     NOT NULL,
  `storage_used_bytes`  BIGINT UNSIGNED  NOT NULL DEFAULT 0,
  `battery_bp`          SMALLINT UNSIGNED NOT NULL DEFAULT 10000,  -- basis points, 10000 = 100.00 %
  `battery_health`      TINYINT UNSIGNED NOT NULL DEFAULT 100,
  `battery_stamp`       TIMESTAMP        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `charging`            TINYINT(1)       NOT NULL DEFAULT 0,
  `passcode_hash`       VARCHAR(72)      NULL,                     -- bcrypt (GetPasswordHash)
  `passcode_length`     TINYINT UNSIGNED NULL,
  `failed_attempts`     TINYINT UNSIGNED NOT NULL DEFAULT 0,
  `locked_until`        TIMESTAMP        NULL,
  `created_at`          TIMESTAMP        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at`          TIMESTAMP        NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_devices_serial` (`serial`),
  KEY `idx_devices_owner` (`owner_identifier`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `toxic_ipad_device_settings` (
  `device_id`      BIGINT UNSIGNED   NOT NULL,
  `schema_version` SMALLINT UNSIGNED NOT NULL,
  `data`           TEXT              NOT NULL,   -- JSON document, validated, ≤ 16 KB
  `updated_at`     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`device_id`),
  CONSTRAINT `fk_settings_device` FOREIGN KEY (`device_id`)
    REFERENCES `toxic_ipad_devices` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `toxic_ipad_installed_apps` (
  `device_id`    BIGINT UNSIGNED NOT NULL,
  `app_id`       VARCHAR(32)     NOT NULL,
  `permissions`  VARCHAR(512)    NOT NULL DEFAULT '{}',  -- JSON { name: 'granted'|'denied' }
  `installed_at` TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`device_id`, `app_id`),
  CONSTRAINT `fk_installed_device` FOREIGN KEY (`device_id`)
    REFERENCES `toxic_ipad_devices` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `toxic_ipad_app_data` (
  `device_id`  BIGINT UNSIGNED NOT NULL,
  `app_id`     VARCHAR(32)     NOT NULL,
  `data_key`   VARCHAR(64)     NOT NULL,
  `value`      MEDIUMTEXT      NOT NULL,               -- JSON; per-app quota enforced in Lua
  `size_bytes` INT UNSIGNED    NOT NULL,
  `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`device_id`, `app_id`, `data_key`),
  CONSTRAINT `fk_appdata_device` FOREIGN KEY (`device_id`)
    REFERENCES `toxic_ipad_devices` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `toxic_ipad_notifications` (
  `id`         BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
  `device_id`  BIGINT UNSIGNED  NOT NULL,
  `app_id`     VARCHAR(32)      NOT NULL,
  `title`      VARCHAR(80)      NOT NULL,
  `message`    VARCHAR(500)     NOT NULL,
  `priority`   TINYINT UNSIGNED NOT NULL DEFAULT 1,   -- 0 info, 1 normal/success, 2 warning, 3 critical
  `route`      VARCHAR(128)     NULL,                 -- deep link on click
  `is_read`    TINYINT(1)       NOT NULL DEFAULT 0,
  `created_at` TIMESTAMP        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_notif_device_time` (`device_id`, `created_at`),
  CONSTRAINT `fk_notif_device` FOREIGN KEY (`device_id`)
    REFERENCES `toxic_ipad_devices` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `toxic_ipad_notes` (
  `id`         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `device_id`  BIGINT UNSIGNED NOT NULL,
  `title`      VARCHAR(120)    NOT NULL,
  `body`       MEDIUMTEXT      NOT NULL,              -- ≤ 20 000 chars (config)
  `pinned`     TINYINT(1)      NOT NULL DEFAULT 0,
  `created_at` TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_notes_device_updated` (`device_id`, `updated_at`),
  CONSTRAINT `fk_notes_device` FOREIGN KEY (`device_id`)
    REFERENCES `toxic_ipad_devices` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `toxic_ipad_files` (
  `id`         BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
  `device_id`  BIGINT UNSIGNED  NOT NULL,
  `parent_id`  BIGINT UNSIGNED  NULL,                 -- NULL only for the system roots
  `kind`       TINYINT UNSIGNED NOT NULL,             -- 1 folder, 2 file
  `name`       VARCHAR(80)      NOT NULL,
  `mime`       VARCHAR(48)      NULL,
  `size_bytes` BIGINT UNSIGNED  NOT NULL DEFAULT 0,
  `ref`        VARCHAR(255)     NULL,                 -- e.g. 'note:42' or an uploader URL (Phase 2)
  `system`     TINYINT(1)       NOT NULL DEFAULT 0,   -- Documents/Downloads roots: not deletable
  `created_at` TIMESTAMP        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_files_name` (`device_id`, `parent_id`, `name`),
  CONSTRAINT `fk_files_device` FOREIGN KEY (`device_id`)
    REFERENCES `toxic_ipad_devices` (`id`) ON DELETE CASCADE,
  CONSTRAINT `fk_files_parent` FOREIGN KEY (`parent_id`)
    REFERENCES `toxic_ipad_files` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```
### 2.1 Migration `0002_app_removals.sql` (0.3.0)
```sql
CREATE TABLE IF NOT EXISTS `toxic_ipad_app_removals` (
  `device_id`  BIGINT UNSIGNED NOT NULL,
  `app_id`     VARCHAR(32)     NOT NULL,
  `removed_at` TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`device_id`, `app_id`),
  CONSTRAINT `fk_removals_device` FOREIGN KEY (`device_id`) REFERENCES `toxic_ipad_devices` (`id`) ON DELETE CASCADE
);
```
An app is installed when it has a row in `installed_apps`, or when it is *preinstalled* and has no row here. A new table instead of a column keeps the migration idempotent on both MariaDB and MySQL (MySQL has no `ADD COLUMN IF NOT EXISTS`). Uninstall = one transaction: delete the `installed_apps` row, delete the app's `app_data`, and (preinstalled apps) insert the removal.

Note on `uq_files_name`: MySQL allows several `NULL` parents, so root uniqueness (one Documents, one Downloads) is enforced in Lua when roots are created with the device.

---

### 2.2 Migration `0003_photos.sql` (0.5.0)
```sql
toxic_ipad_photos (
  id BIGINT UNSIGNED AUTO_INCREMENT PK,
  device_id BIGINT UNSIGNED NOT NULL → toxic_ipad_devices.id ON DELETE CASCADE,
  url VARCHAR(255) NOT NULL,          -- https, host on the uploader allow-list
  selfie TINYINT(1), favorite TINYINT(1),
  size_bytes INT UNSIGNED,            -- virtual size, counts toward storage
  location VARCHAR(80) NULL,          -- street at capture (config photos.recordStreet)
  created_at TIMESTAMP,
  KEY idx_photos_device_id (device_id, id)
)
```
Queries (all `device_id = ?`): page newest first (`id < ? ORDER BY id DESC LIMIT 61`), one photo, usage (`COUNT`, `SUM(size_bytes)`, cached per device record), insert, favourite, delete `id IN (?,…)` (≤ 100 bound ids) plus `toxic_ipad_files` entries whose `ref` is `photo:<id>`.

### 2.3 Migration `0004_device_status.sql` (0.6.0)
`toxic_ipad_device_status (device_id PK → devices ON DELETE CASCADE, lost, lost_message VARCHAR(120), last_x/last_y/last_z FLOAT, last_seen TIMESTAMP, charge_bp SMALLINT)` — one row per device, upserted: last seen on every open/close (non-blocking), Lost Mode from Find My, the power bank charge still to deliver (written when a charge starts, ends and on close/stop). Loaded with the device (`LEFT JOIN`). Find My reads `devices ⋈ status WHERE owner_identifier = ? LIMIT 10`. Erase = one transaction deleting the device's notes, files (roots first — cascade), photos, app data, installs, removals, notifications and settings, clearing Lost Mode and the passcode (and the owner, optionally).

## 3. Settings document (validated JSON)

One document per device instead of one row per key: it is always read and written as a whole, it is small, and the whole shape is validated by a server-side schema (`shared/validate.lua`) — unknown keys are dropped, wrong types rejected.

```json
{ "v": 1,
  "appearance": { "theme": "dark|light|auto", "wallpaper": "default_01", "textScale": 1, "reducedMotion": false, "highContrast": false },
  "display": { "brightness": 0.8, "autoLockSeconds": 120 },
  "sound": { "volume": 0.6, "enabled": true },
  "notifications": { "showPreviews": true, "perApp": { "notes": { "allow": true } } },
  "battery": { "lowPower": false, "showPercent": true },
  "clock": { "use24h": true },
  "layout": { "pages": [["notes","calculator"]], "dock": ["settings","notes","files"], "folders": { "f1": { "name": "Utilities", "apps": ["clock"] } }, "recents": ["notes"] },
  "language": null }
```
Migration of the document is done in Lua by `v` (a pure function per version), never in SQL.

---

## 4. Query catalogue (every query MVP runs)

| When | Query | Index used |
|---|---|---|
| first use of a serial | `SELECT … FROM toxic_ipad_devices WHERE serial = ?` then `INSERT` device + settings + roots in **one transaction** | `uq_devices_serial` |
| open (cache miss) | device row; settings row; `SELECT app_id, permissions FROM installed_apps WHERE device_id = ?`; `SELECT … FROM notifications WHERE device_id = ? ORDER BY created_at DESC LIMIT 100` | PKs, `idx_notif_device_time` |
| Notes list (first launch per session) | `SELECT id, title, body, pinned, updated_at FROM notes WHERE device_id = ? ORDER BY updated_at DESC LIMIT 500` | `idx_notes_device_updated` |
| note save | `INSERT` / `UPDATE … WHERE id = ? AND device_id = ?` (debounced 1.5 s per note) | PK |
| note delete | `DELETE FROM notes WHERE id = ? AND device_id = ?` | PK |
| files list | `SELECT … FROM files WHERE device_id = ? AND parent_id = ?` | `uq_files_name` prefix |
| files path / depth | recursive CTE over `parent_id` (≤ 32 levels) | PK |
| files delete | recursive CTE for the subtree size, then `DELETE … WHERE id = ? AND device_id = ? AND system = 0` (children cascade) | PK |
| storage usage | `SUM(LENGTH(title)+LENGTH(body))` notes; `COUNT/SUM(size_bytes)` files; `SUM(size_bytes) GROUP BY app_id` app data — on request only | device_id prefixes |
| install / uninstall | `INSERT IGNORE` / `DELETE … WHERE device_id = ? AND app_id = ?` | PK |
| app_data get/set | by full PK; `INSERT … ON DUPLICATE KEY UPDATE` | PK |
| notify | `INSERT` then, when count > `maxStoredPerDevice` (200), `DELETE … WHERE device_id = ? ORDER BY created_at ASC LIMIT ?` | `idx_notif_device_time` |
| mark read | `UPDATE notifications SET is_read = 1 WHERE device_id = ? AND id IN (?)` | PK |
| settings flush | `UPDATE device_settings SET data = ?, schema_version = ? WHERE device_id = ?` (debounced 5 s, forced on close) | PK |
| device flush | `UPDATE devices SET battery_bp=?, battery_stamp=?, charging=?, storage_used_bytes=? WHERE id = ?` (on close) | PK |
| passcode | `UPDATE devices SET passcode_hash=?, passcode_length=?, failed_attempts=0 WHERE id = ?` | PK |

The `AND device_id = ?` on every child mutation is a second ownership check in SQL: even a logic bug that passes a foreign note id cannot touch another device's row.

Every table is keyed by `device_id` first, so each query touches one device's rows — load is proportional to players with an open tablet, not to table size.

---

## 5. Caching (§58)

Per-device cache in `server/cache.lua`, created on open, kept for `cacheTTL` (default 10 min) after close so reopening costs **zero queries**. Holds: device row, settings document, installed apps, notification head (100), notes (after first Notes launch). Dirty flags per section; flush on debounce, on close, on `playerDropped`, and on `onResourceStop` (synchronous `.await` loop over dirty devices, bounded by the number of open tablets).

---

## 6. Migrations
Same rules as toxic_core: `migrations/index.lua` lists files; checksum guard; additive and idempotent only; no `DROP/TRUNCATE`; no `?` in migration files. The runner is a small copy adapted from toxic_core's (not a dependency — toxic_ipad must run on Qbox without toxic_core).
