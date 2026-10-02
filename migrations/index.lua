---Ordered list of database migrations (docs/DATABASE.md §6). Same rules as
---toxic_core: never renumber, never edit an applied file (checksum guard),
---additive and idempotent statements only, and no `?` or `:name` anywhere in
---a migration file (oxmysql placeholders).

return {
    { version = 1, name = 'ipad', file = '0001_ipad.sql' },
    { version = 2, name = 'app_removals', file = '0002_app_removals.sql' },
    { version = 3, name = 'photos', file = '0003_photos.sql' },
    { version = 4, name = 'device_status', file = '0004_device_status.sql' },
}
