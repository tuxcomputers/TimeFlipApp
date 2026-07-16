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
