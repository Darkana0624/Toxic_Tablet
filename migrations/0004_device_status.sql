-- toxic_ipad migration 0004: power & ownership (docs/DATABASE.md §2.3).
-- Additive and idempotent. Never edit after release; add a new file instead.
--
-- One row per device, created on first use: where it was last seen (Find
-- My), Lost Mode, and the power bank charge still to deliver.

CREATE TABLE IF NOT EXISTS `toxic_ipad_device_status` (
  `device_id`    BIGINT UNSIGNED   NOT NULL,
  `lost`         TINYINT(1)        NOT NULL DEFAULT 0,
  `lost_message` VARCHAR(120)      NULL,
  `last_x`       FLOAT             NULL,
  `last_y`       FLOAT             NULL,
  `last_z`       FLOAT             NULL,
  `last_seen`    TIMESTAMP         NULL,
  `charge_bp`    SMALLINT UNSIGNED NOT NULL DEFAULT 0,  -- power bank charge left (basis points)
  PRIMARY KEY (`device_id`),
  CONSTRAINT `fk_status_device` FOREIGN KEY (`device_id`)
    REFERENCES `toxic_ipad_devices` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
