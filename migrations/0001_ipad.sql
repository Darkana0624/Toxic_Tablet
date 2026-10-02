-- toxic_ipad migration 0001: MVP schema (docs/DATABASE.md §2).
-- Additive and idempotent. Never edit after release; add a new file instead.

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
  `passcode_hash`       VARCHAR(72)      NULL,                     -- bcrypt 
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
