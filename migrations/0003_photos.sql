-- toxic_ipad migration 0003: Camera & Photos (docs/DATABASE.md §2.2).
-- Additive and idempotent. Never edit after release; add a new file instead.
--
-- A photo is a URL on the configured uploader (Fivemanage or the owner's
-- own endpoint), never image data. `size_bytes` is the virtual size that
-- counts toward the tablet's storage.

CREATE TABLE IF NOT EXISTS `toxic_ipad_photos` (
  `id`         BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
  `device_id`  BIGINT UNSIGNED  NOT NULL,
  `url`        VARCHAR(255)     NOT NULL,
  `selfie`     TINYINT(1)       NOT NULL DEFAULT 0,
  `favorite`   TINYINT(1)       NOT NULL DEFAULT 0,
  `size_bytes` INT UNSIGNED     NOT NULL DEFAULT 0,
  `location`   VARCHAR(80)      NULL,
  `created_at` TIMESTAMP        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_photos_device_id` (`device_id`, `id`),
  CONSTRAINT `fk_photos_device` FOREIGN KEY (`device_id`)
    REFERENCES `toxic_ipad_devices` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
