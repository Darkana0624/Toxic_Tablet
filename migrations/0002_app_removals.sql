-- toxic_ipad migration 0002: removed preinstalled apps (docs/DATABASE.md §2.1).
-- Additive and idempotent. Never edit after release; add a new file instead.
--
-- An app is installed on a device when it has a row in
-- toxic_ipad_installed_apps, or when it is a preinstalled app with no row
-- here. Deleting a preinstalled app writes a row here; installing it again
-- from the App Store removes that row.

CREATE TABLE IF NOT EXISTS `toxic_ipad_app_removals` (
  `device_id`  BIGINT UNSIGNED NOT NULL,
  `app_id`     VARCHAR(32)     NOT NULL,
  `removed_at` TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`device_id`, `app_id`),
  CONSTRAINT `fk_removals_device` FOREIGN KEY (`device_id`)
    REFERENCES `toxic_ipad_devices` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
