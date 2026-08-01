# Database Conventions

## Legacy tables (`000_*`)

- The `000_`-numbered file (`000_logbook.sql`) is a **legacy** pre-redesign table, kept only
  until the code that still reads it is migrated onto the `device_event`/`time_entry` schema.
  It will eventually be deleted from the repo, as `000_integration_event_cursors.sql` already
  has been — the history resume position is now derived from `device_event` instead.
- Treat them as **out of scope for these conventions** — don't reformat them, renumber them, or
  bring them into line with the rules below (naming, primary keys, seeds, etc.), and don't count
  them when reasoning about the schema. Leave them exactly as they are until they're removed.

## Comments in DDL files

- A DDL file opens with exactly **two** comment lines: the table name, then a single line saying
  what the table holds. Nothing else in the file is commented -- no per-column notes, no rationale,
  no section headers between statements.
- Everything past that one line -- what each column means, why a constraint exists, what the seed
  rows are for -- goes in [`../docs/database-design.md`](../docs/database-design.md), which
  describes every table in DDL order. One home for the prose keeps the two from drifting apart, and
  the DDL stays readable as pure schema.
- `000_logbook.sql` is the one exception, per the legacy rule above -- leave its header as it is.

## Table naming

- Every table name is **singular** — `device_event`, not `device_events`; `device_notification`,
  not `device_notifications`. The singular form flows through to every derived identifier: the
  primary key column (`device_event_id`), the constraint name (`PK_device_event`), and index names
  (`IN1_device_event`, `UN1_device_event`).

## Primary keys

- Every autoincrementing primary key column must be named `<tablename>_id` (e.g. the `device_event`
  table's primary key is `device_event_id`, not `id`).

## Column naming

- No column may be called just `name` — use `<tablename>_name` instead (e.g. the `icon` table's
  name column is `icon_name`, not `name`).

## Date/time storage

- All date/time columns must store **local time**, not UTC.
- Every table with a date/time column must also record the IANA time zone (e.g.
  `America/New_York`) the local time was captured in, so the stored value can be unambiguously
  converted to UTC or any other zone later. This is a **foreign key to the `timezone` table**
  (`002_timezone.sql`), not an inline text column — the zone identifier is stored once in `timezone`
  and referenced by id. The app resolves the current zone's id once at startup (get-or-create; see
  `AppDataStore.resolveTimezoneID`).
- Naming: when a table has a **single** timestamp/zone, name the FK column simply `timezone_id`
  (referencing `timezone(timezone_id)`) — e.g. `device_event.timezone_id`. When a table has
  **more than one** timestamp that each need a zone, disambiguate per timestamp with a short
  `<prefix>_timezone_id` column — e.g. `time_entry.start_timezone_id` / `end_timezone_id` for its
  `started_at` / `ended_at` timestamps.
- Every `timezone_id` / `<prefix>_timezone_id` column is `NOT NULL DEFAULT 0` — id `0` is the
  seeded `Unknown` sentinel row in `timezone` (see `002_timezone.sql`), so a row can always satisfy
  the FK even before a real zone has been resolved. `AppDataStore.resolveTimezoneID` likewise falls
  back to `0` when a lookup fails.
- Store local time as ISO 8601 text without a UTC offset/`Z` suffix (e.g. `2026-07-16T09:30:00`) —
  the offset is recoverable via the referenced `timezone` row, not the timestamp itself.
- Whole seconds, with one exception: `debug_log.logged_at` records milliseconds
  (`2026-07-16T09:30:00.123`, see `AppDataStore.debugLogTimeFormatter`). It is the diagnostic record a
  test session is reconstructed from, and every BLE round trip this app makes is sub-second, so at
  second resolution a duration can only be recovered statistically rather than measured. The columns
  that sit beside an `<name>_epoch` INTEGER stay at whole seconds so the text can't disagree with the
  key that actually orders them.
- If a table needs to *order by* or *compare* a date/time column (not just display it), also add
  an indexed `<name>_epoch` INTEGER column (Unix epoch seconds, same moment as `<name>`) and
  compare/sort on that instead of the text column or any device-supplied sequence number. A
  device-side counter (e.g. an event number) can reset independently of wall-clock time, so it
  isn't safe to use for ordering — see `device_event`/`device_notification` (`start_time` /
  `timezone_id` / `start_epoch`) for the pattern.

## Naming: primary keys, indexes, and unique constraints

- Primary key: `PK_<tablename>` (e.g. `CONSTRAINT PK_device_event PRIMARY KEY AUTOINCREMENT`).
  This is part of the column/table definition inside `CREATE TABLE` — SQLite requires
  `PRIMARY KEY AUTOINCREMENT` to be declared on the column itself for rowid-aliasing to work, so
  it can't be split into a separate statement the way indexes and unique constraints are below.
- Non-unique index: `IN<n>_<tablename>` (e.g. `IN1_device_event`), as a separate `CREATE INDEX`
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

- Every seed `INSERT` must be idempotent via the guarded pattern in `007_category.sql`:
  `INSERT INTO <table> (<columns>) SELECT <values> WHERE NOT EXISTS (SELECT 1 FROM <table> WHERE
  <uniqueness condition>);` — never `INSERT ... VALUES (...) ON CONFLICT DO NOTHING`.
- Each seed row is its own separate guarded `INSERT` statement (see `001_event_type.sql`,
  `004_icon.sql`, `005_colour.sql`, `011_setting.sql`) — do not combine multiple rows into one
  statement with `UNION ALL`. This keeps each row's existence check self-contained, so a DDL file
  that adds a new seed row to an otherwise-already-seeded table still inserts just the new row.
- `001_event_type.sql`'s seeded ids are grouped by which table an event of that type lands in
  (`device_event` for timing segments, `device_notification` for point-in-time ones — see
  `docs/operation-spec.md` § 1), with a blank line between the groups. Append a new event type
  within its matching group rather than interleaving.

## File numbering and dependency order

- DDL files are named `<NNN>_<tablename>.sql` and applied in ascending filename order (see
  `AppDataStore.runDatabaseDDL`). Foreign keys are **enforced** (`PRAGMA foreign_keys = ON`), so a
  table must be numbered **after every table it references** — a parent is created and seeded before
  any child that points at it, otherwise the child's seed insert fails on a missing parent row. For
  example `004_icon`, `005_colour`, and `006_project` all precede `007_category`, which references
  all three.
- To insert a new table at a given position: rename every file numbered `>=` the target position up
  by one (highest number first, so no rename overwrites another), add the new file at that number,
  then grep for and fix **every** reference to the old filenames — DDL files, `docs/`, code comments
  (`Sources/`), and the test checklists (`Tests/`) all cite them by name. This mirrors the checklist
  renumber rule in [`../Tests/CLAUDE.md`](../Tests/CLAUDE.md).
- Renumbering also **moves that table's section in [`../docs/database-design.md`](../docs/database-design.md)**,
  whose sections are ordered by DDL number so every foreign key points at a table described above it.

## Adding a column to an existing table

- Add the column to the table's `CREATE TABLE IF NOT EXISTS` statement, so a **fresh** database
  gets it at creation.
- **Write the migration for an existing database as a commented-out `ALTER TABLE`**, directly under
  that `CREATE TABLE`, and never as a live statement. It is a record of the change, not something
  the app or any script runs. See `white_lines` in `005_colour.sql` for the shape:
  ```sql
  -- Migration (run by hand against a database that predates this column):
  -- ALTER TABLE colour ADD COLUMN white_lines INTEGER NOT NULL DEFAULT 0 CHECK (white_lines IN (0,1));
  ```
  The statement stays commented **in the file** for the reason below -- a live one breaks every
  fresh database -- but that is about where it lives, not about when it runs. It is the exact text
  to apply, and applying it is the next step, not a later one.
- **Apply the change to `production.sqlite` as part of making it, not later.** A DDL change is not
  finished when the `.sql` file is edited; it is finished when the production database matches.
  Nothing applies these automatically, so a schema change that stops at the file leaves production
  silently behind, and the gap only surfaces the next time someone runs the comparison, by which
  point several changes have piled up and nobody remembers which mattered.

  Run the commented statement against production, then confirm with
  `scripts/compare-database-to-ddl.sh`, which reports exactly what a database is still missing and
  must come back clean before the change is done. This holds for every DDL change, not only column
  additions: new indexes and new tables are the same deal.

  Seed rows are the exception that needs no action: they are live `INSERT ... WHERE NOT EXISTS`
  statements that run on every open, so they reach an existing database on their own. Only opening
  the app against it is required, and the comparison script does not track them.

  (This replaces the earlier convention of deferring these to "the developer runs them by hand
  eventually, once the automated migration feature exists". That feature -- the planned `099`
  script plus a `database_version` setting -- is still worth building, but waiting for it meant
  production drifting from the DDL in the meantime.)
- Why they cannot be live: sqlite has no conditional DDL (no `ADD COLUMN IF NOT EXISTS`), and a
  failed statement abandons the rest of the file, taking that table's indexes and seed rows with
  it. An unconditional `ALTER` therefore breaks every **fresh** database, because the `CREATE TABLE`
  above has already added the column and sqlite reports `duplicate column name`. That is not
  hypothetical: it silently emptied `colour` on a fresh database (the app logs the error and carries
  on, so it self-heals on the second launch) and hard-failed `use-test-database.sh` under `set -e`.
- `AppDataStore.runDatabaseDDL` still carries `skipSatisfiedColumnAdditions`, which comments out a
  live `ALTER ... ADD COLUMN` whose column already exists. With this rule in force nothing reaches
  it, and it cannot help the fresh-database case anyway (it checks the live database, which has no
  such table yet when the file that creates it runs). Leave it until the migration feature lands.
