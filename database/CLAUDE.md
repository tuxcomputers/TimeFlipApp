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
- If a table needs to *order by* or *compare* a date/time column (not just display it), also add
  an indexed `<name>_epoch` INTEGER column (Unix epoch seconds, same moment as `<name>`) and
  compare/sort on that instead of the text column or any device-supplied sequence number. A
  device-side counter (e.g. an event number) can reset independently of wall-clock time, so it
  isn't safe to use for ordering — see `device_events`/`device_notifications` (`start_time` /
  `start_time_timezone` / `start_epoch`) for the pattern.

## Naming: primary keys, indexes, and unique constraints

- Primary key: `PK_<tablename>` (e.g. `CONSTRAINT PK_device_events PRIMARY KEY AUTOINCREMENT`).
  This is part of the column/table definition inside `CREATE TABLE` — SQLite requires
  `PRIMARY KEY AUTOINCREMENT` to be declared on the column itself for rowid-aliasing to work, so
  it can't be split into a separate statement the way indexes and unique constraints are below.
- Non-unique index: `IN<n>_<tablename>` (e.g. `IN1_device_events`), as a separate `CREATE INDEX`
  statement after the `CREATE TABLE`.
- Unique constraint: `UN<n>_<tablename>` (e.g. `UN1_setting`), as a separate
  `CREATE UNIQUE INDEX` statement after the `CREATE TABLE` — not an inline `UNIQUE` column
  constraint. SQLite has no `ALTER TABLE ADD CONSTRAINT`, so a named unique index is the
  idiomatic equivalent.
- `<n>` starts at `1` for each table and increases per additional index/unique constraint on that
  same table (e.g. a table's second index is `IN2_<tablename>`, regardless of how many unique
  constraints it also has — the two sequences are independent).
- Always add `IF NOT EXISTS` to these `CREATE INDEX`/`CREATE UNIQUE INDEX` statements, matching
  every other DDL statement in this folder.

## Seed inserts

- Every seed `INSERT` must be idempotent via the guarded pattern in `006_category.sql`:
  `INSERT INTO <table> (<columns>) SELECT <values> WHERE NOT EXISTS (SELECT 1 FROM <table> WHERE
  <uniqueness condition>);` — never `INSERT ... VALUES (...) ON CONFLICT DO NOTHING`.
- Each seed row is its own separate guarded `INSERT` statement (see `001_event_type.sql`,
  `003_icon.sql`, `004_colour.sql`, `010_setting.sql`) — do not combine multiple rows into one
  statement with `UNION ALL`. This keeps each row's existence check self-contained, so a DDL file
  that adds a new seed row to an otherwise-already-seeded table still inserts just the new row.

## File numbering and dependency order

- DDL files are named `<NNN>_<tablename>.sql` and applied in ascending filename order (see
  `AppDataStore.runDatabaseDDL`). Foreign keys are **enforced** (`PRAGMA foreign_keys = ON`), so a
  table must be numbered **after every table it references** — a parent is created and seeded before
  any child that points at it, otherwise the child's seed insert fails on a missing parent row. For
  example `003_icon`, `004_colour`, and `005_project` all precede `006_category`, which references
  all three.
- To insert a new table at a given position: rename every file numbered `>=` the target position up
  by one (highest number first, so no rename overwrites another), add the new file at that number,
  then grep for and fix **every** reference to the old filenames — DDL files, `docs/`, code comments
  (`Sources/`), and the test checklists (`Tests/`) all cite them by name. This mirrors the checklist
  renumber rule in [`../Tests/CLAUDE.md`](../Tests/CLAUDE.md).
