# Database Conventions

## Primary keys

- Every autoincrementing primary key column must be named `<tablename>_id` (e.g. the `device_events`
  table's primary key is `device_events_id`, not `id`).

## Column naming

- No column may be called just `name` — use `<tablename>_name` instead (e.g. the `icon` table's
  name column is `icon_name`, not `name`).

## Date/time storage

- All date/time columns must store **local time**, not UTC.
- Every table with a date/time column must also have a companion column recording the IANA
  timezone identifier (e.g. `America/New_York`) that the local time was captured in, so the
  stored value can be unambiguously converted to UTC or any other timezone later.
- Naming: for a date/time column named `<name>`, the companion column is `<name>_timezone`
  (e.g. `started_at` / `started_at_timezone`).
- Store local time as ISO 8601 text without a UTC offset/`Z` suffix (e.g.
  `2026-07-16T09:30:00`) — the offset lives in the timezone column, not the timestamp itself.

## Seed inserts

- Every seed `INSERT` must be idempotent via the guarded pattern in `005_category.sql`:
  `INSERT INTO <table> (<columns>) SELECT <values> WHERE NOT EXISTS (SELECT 1 FROM <table> WHERE
  <uniqueness condition>);` — never `INSERT ... VALUES (...) ON CONFLICT DO NOTHING`.
- Each seed row is its own separate guarded `INSERT` statement (see `001_event_type.sql`,
  `003_icon.sql`, `004_colour.sql`, `009_setting.sql`) — do not combine multiple rows into one
  statement with `UNION ALL`. This keeps each row's existence check self-contained, so a DDL file
  that adds a new seed row to an otherwise-already-seeded table still inserts just the new row.
