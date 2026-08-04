# Database Design

[← Back to README](../README.md)

This document describes the schema used to persist TimeFlip data locally. DDL files for each table live in [`database/`](../database), numbered in the order they should be applied. See [`database/CLAUDE.md`](../database/CLAUDE.md) for the storage conventions referenced below.

## Rule: sections follow the DDL numbering

The `## Tables` sections below appear in the **same order as the tables are created** — `001`, then `002`, and so on — not grouped by topic or importance. When a table is added or renumbered, its section moves to match.

This isn't housekeeping. Foreign keys are enforced, so the numbering already guarantees a table is created after everything it references (see the design principle below). Mirroring that order here means **every foreign key a section mentions points at a table already described above it** — the document reads top to bottom without forward references, and each `Foreign keys` list can say "described above" and be reliably true.

## Design principle: decoded, not raw

The TimeFlip device reports events over Bluetooth as raw hex payloads (e.g. a face byte, a big-endian duration, a status flag). This database never stores those raw bytes directly — every column holds the *decoded, human-readable* value instead. For example, the device's raw face byte is converted to a plain face number (`1`-`12`) before it's written to the `face` column, so the table can be read and reasoned about directly (in a SQLite browser, in `sqlite3`, etc.) without needing to know the device's wire format.

## Design principle: local time + timezone

Date/time columns store **local time**, not UTC. The timestamp itself omits any UTC offset/`Z` suffix (e.g. `2026-07-16T09:30:00`) so it always reads the same as the wall-clock time at the moment it was recorded, regardless of the reader's timezone. The IANA zone that local time was captured in — needed to recover the offset — is held in a **foreign key to the `timezone` table**, not repeated as inline text on every row: a single `timezone_id` column when the table has one timestamp (e.g. `device_event.timezone_id`), or short per-timestamp `<prefix>_timezone_id` columns when it has several (e.g. `time_entry.start_timezone_id` / `end_timezone_id` for `started_at` / `ended_at`). The app resolves the current zone's id once at startup (`AppDataStore.resolveTimezoneID`, get-or-create) and binds it into each row. These columns are `NOT NULL DEFAULT 0`, and `timezone` is seeded with an id-`0` `Unknown` row, so the FK is always satisfiable — a lookup that fails falls back to that sentinel rather than a null or a dangling id.

## Design principle: foreign keys enforced

The app opens every database connection with `PRAGMA foreign_keys = ON` (SQLite defaults this OFF, and it's a per-connection setting, not stored in the file — see `AppDataStore`). So the `REFERENCES` clauses in the schema are real, enforced constraints, not just documentation: an insert or update with a dangling foreign key fails. This keeps local behaviour aligned with the eventual remote server (which enforces them) and lets the same DDL be reused there.

Because enforcement is on, the DDL files are numbered so a **parent table is created and seeded before any table that references it** — e.g. `004_icon`, `005_colour`, and `006_project` all precede `007_category`. Inserting a new table therefore follows the renumber rule in [`database/CLAUDE.md`](../database/CLAUDE.md).

## Tables

### `event_type` (`database/001_event_type.sql`)

Reference table of the different event types the TimeFlip device can trigger. Most of these (`double_tap`, `battery_level`, `system_state`, `device_info`, `event_log`) are live BLE notifications the device sends outside the history stream, not timing segments, and so never appear in `device_event` — only `face_flip` and `pause` come from the history stream that populates `device_event` (see `Sources/TimeFlipApp/TimeFlipEvent.swift` and `docs/timeflip.md` §4-5 for the full notification/history breakdown).

| Column           | Type    | Description                                              |
|-------------------|---------|-------------------------------------------------------------|
| `event_type_id`   | INTEGER | Primary key. Not autoincrementing — seeded with fixed IDs.  |
| `event_name`      | TEXT    | Event type name, e.g. `face_flip`, `pause`, `double_tap`.   |

Constraints:
- `event_name` is `UNIQUE` — each event type is only represented by one row.
- Seeded with all known device event types, with the ids **grouped by which table an event of that type lands in** and a blank line between the groups in the DDL:

  | IDs   | Group                                                | Types                                                                            |
  |-------|------------------------------------------------------|----------------------------------------------------------------------------------|
  | `1`-`2` | → `device_event` — timing segments, carry a duration | `face_flip`, `pause`                                                            |
  | `3`-`8` | → `device_notification` — point-in-time, no duration | `double_tap`, `auto_pause_minutes`, `battery_level`, `system_state`, `device_info`, `event_log` |

  The grouping is a convention of the seed order, not something the schema enforces — nothing stops a row in either table referencing an id from the other group. It exists so the id alone tells you where an event of that type belongs, which is why a **new event type is appended within its matching group rather than interleaved** (see `database/CLAUDE.md` § Seed inserts). Which table a given event actually lands in is decided by the classification step in [Operation Spec § 1](operation-spec.md).

### `timezone` (`database/002_timezone.sql`)

Reference table of IANA time zones. Every date/time table references it by id (see the "local time + timezone" design principle) instead of repeating the identifier string on every row. The app resolves the current zone's id at startup via get-or-create (`AppDataStore.resolveTimezoneID`). It is numbered `002` so it precedes every table that references it (foreign keys are enforced).

| Column          | Type    | Description                                                        |
|-----------------|---------|--------------------------------------------------------------------|
| `timezone_id`   | INTEGER | Row identifier, primary key, autoincrementing.                     |
| `timezone_name` | TEXT    | IANA time zone identifier (e.g. `Australia/Sydney`). `NOT NULL`, `UNIQUE`. |
| `display_name`  | TEXT    | Optional human-friendly label for a picker (e.g. `Sydney`). Nullable. |
| `active`     | INTEGER | `1` if the zone should be offered in a picker, `0` to hide it (e.g. a deprecated IANA alias). `NOT NULL`, defaults to `1`. |

Constraints:
- `timezone_name` is `NOT NULL` and `UNIQUE` (`UN1_timezone`), so get-or-create can look a zone up by identifier and never store it twice.
- `active` is constrained to `0`/`1` (SQLite has no native boolean type) and defaults to `1`.

Seeded with a single sentinel row — `timezone_id 0`, `timezone_name`/`display_name` `Unknown` — which is the value every referencing `timezone_id` column defaults to, so a row can satisfy its foreign key before a real zone has been resolved (and `resolveTimezoneID` falls back to `0` on a lookup failure). Real zones are otherwise populated at runtime from the OS's known identifiers (`TimeZone.knownTimeZoneIdentifiers` / the current zone), not hand-written. Deliberately has **no** UTC-offset column: an offset varies with DST within the same zone, so storing a fixed one would be misleading — the offset is derived from the IANA identifier at read time instead.

### `device_event` (`database/003_device_event.sql`)

One row per device-reported timing segment — created whenever the device is flipped to a new face or paused/resumed, marking the end of the previous segment.

| Column             | Type    | Description                                                                 |
|---------------------|---------|-------------------------------------------------------------------------------|
| `device_event_id`  | INTEGER | Row identifier, primary key, autoincrementing (`PK_device_event`).          |
| `event_number`      | INTEGER | The device's own sequence number for this event. Part of the composite matching key with `start_epoch` — see below — but not unique on its own, and not used for ordering. |
| `event_type_id`     | INTEGER | References `event_type.event_type_id` — always `face_flip` or `pause` for rows in this table. |
| `device_face`       | INTEGER | Decoded face number, `1`-`12`. Decoded from the device's raw face byte, not stored as hex. |
| `start_time`        | TEXT    | When the segment started, as a local-time ISO 8601 timestamp with no UTC offset (e.g. `2026-07-16T09:30:00`). Decoded from the device's raw timestamp encoding. Display only — see `start_epoch` for ordering/comparisons. |
| `timezone_id`       | INTEGER | References `timezone.timezone_id` — the IANA zone (e.g. `America/New_York`) `start_time` was recorded in. |
| `start_epoch`       | INTEGER | The same moment as `start_time`, as Unix epoch seconds. This — not `event_number` — is what `AppDataStore.recordDeviceEvent` compares to decide ordering and the `finalised` flag; also half of the composite matching key (see below). Indexed. |
| `duration_seconds`  | REAL    | How long the segment lasted, in seconds.                                    |
| `paused`         | INTEGER | `1` if this segment was a paused interval, `0` otherwise.                   |
| `finalised`         | INTEGER | `1` once the segment is closed out, `0` while it's still the device's in-progress interval. |
| `processed`         | INTEGER | `1` once the conversion has dealt with this segment: either it became a `time_entry`, or it was skipped as shorter than `blip_time`. `0` otherwise, which includes every paused segment, since a pause is never something the conversion deals with. |

Foreign keys:
- The `event_type_id` column references the PK of the table `event_type` described above. `NOT NULL`. Always `face_flip` or `pause` for rows in this table.
- The `timezone_id` column references the PK of the table `timezone` described above. `NOT NULL DEFAULT 0` — id `0` is the seeded `Unknown` sentinel.

Constraints:
- `(event_number, start_epoch)` has a composite `UNIQUE` index (`UN1_device_event`) — see below for why it's the pair, not `event_number` alone, that's unique.
- `device_face` is constrained to the valid TimeFlip face range (`1`-`12`).
- `duration_seconds` is constrained to be non-negative.
- `paused` is constrained to `0`/`1` (SQLite has no native boolean type).
- `finalised` is constrained to `0`/`1` (SQLite has no native boolean type) and defaults to `0`.
- `processed` is constrained to `0`/`1` (SQLite has no native boolean type) and defaults to `0`.
- `start_epoch` also has its own non-unique index (`IN1_device_event`) for ordering queries that don't also filter on `event_number`.

Why matching and ordering are both keyed off `start_epoch`, and neither trusts `event_number` alone:
- **Ordering** ("is this new segment newer than anything recorded so far?") compares `start_epoch` against `maxKnownStartEpoch`, an in-memory high-water mark. `event_number` is a counter maintained on the device itself — a device-side reset (a battery pull, or a reset from the official app; confirmed happening in practice: a real device's `event_number` sequence jumped from `139` straight back to `1` after an official-app reset) can make it restart from a low number while this table already holds higher `event_number` values from before the reset. Comparing `event_number` magnitudes directly would treat that brand-new event as *older* than history it's actually superseding. `start_epoch` is derived from the device's own timestamp and doesn't reset, so it's safe to compare directly.
- **Matching** ("have I already recorded this exact segment?", used to decide update-in-place vs. insert) uses the composite `(event_number, start_epoch)` pair, not `event_number` alone: after a reset, `event_number` gets reused for a completely different real-world segment, so a bare `UNIQUE` on `event_number` would either block that new segment from ever being inserted, or (if matched on `event_number` alone in the `UPDATE`) silently overwrite the unrelated old row. `start_epoch` alone isn't unique enough to use by itself either — the device only reports whole-second timestamps (`docs/TimeFlip2 BLE Protocol v4.3.md`'s `0x07`/`0x08` commands and the history frame's flip-timestamp field are both "number of seconds", no finer resolution), so two genuinely different segments (e.g. a quick flip across a face while searching for the right one — see the `blip_time` setting) can legitimately share the same `start_epoch` second. The combination of both is what's actually unique: the only way two different real segments collide on `(event_number, start_epoch)` is an exact coincidence of a device reset landing the reused `event_number` in the very same wall-clock second as the old segment it collides with — vanishingly unlikely in practice.

`finalised` vs. `processed`: the device's history stream always reports its still-open, in-progress segment as the last frame in every dump (see `docs/timeflip.md` §5). That frame is inserted with `finalised = 0` and its row is updated in place (matched by `(event_number, start_epoch)`) as the duration keeps growing on each refresh, until a subsequent flip/pause closes it out and a later write sets `finalised = 1`. `processed` is a separate, independent flag — it tracks whether a (finalised) segment has been turned into a `time_entry` yet, and is only ever meaningful once `finalised = 1`; the `finalised` update path never touches it, so an already-`processed` row can't be silently un-flagged by the live segment's growth.

### `icon` (`database/004_icon.sql`)

Reference table of activity icons that can be assigned to a face.

| Column     | Type    | Description                                                                                   |
|------------|---------|-------------------------------------------------------------------------------------------------|
| `icon_id`  | INTEGER | Row identifier, primary key, autoincrementing.                                                  |
| `icon_name`| TEXT    | Identifier the app uses to locate the icon asset (see `ActivityIconLoader`), e.g. `"briefcase"`. |

Constraints:
- `icon_name` is `UNIQUE` — each icon asset is only represented by one row.
- Seeded with a `None` row (`icon_id = 0`) representing "no icon assigned", alongside the real icon assets (`icon_id` 1-42) — so `category.icon_id` can stay a `NOT NULL` foreign key instead of allowing `NULL`.

### `colour` (`database/005_colour.sql`)

Reference table of the colours available to assign to a category.

| Column       | Type    | Description                                              |
|--------------|---------|--------------------------------------------------------------|
| `colour_id`   | INTEGER | Primary key. Not autoincrementing — seeded with fixed IDs.   |
| `colour_name` | TEXT    | Colour name, e.g. `Red`, `Teal`, `Cyan`.                      |
| `device_hex`  | TEXT    | The RGB value shown on the device for this colour, as an `#rrggbb` hex string (`NULL` for `None`). This is the value sent to the tracker's face-colour command (`0x11`, which takes 16-bit R/G/B — see the BLE protocol doc); the app scales each 8-bit channel up when sending. Stored here — rather than derived from an AppKit system colour — so each named colour maps to a fixed, predictable value on the LED. |
| `white_lines` | INTEGER | `1` when the device drawn in this colour should take white inner lines and a white icon, `0` for black ones. `NOT NULL`, defaults to `0`. |

Constraints:
- `colour_name` is `UNIQUE` — each colour is only represented by one row.
- `white_lines` is constrained to `0`/`1` (SQLite has no native boolean type) and defaults to `0`. It is seeded `1` for `Maroon`, `Brown`, `Green`, `Teal`, `Blue`, `Navy` and `Purple`: the seven seeded colours dark enough that black lines disappear into them, by WCAG relative luminance (those below the ~0.179 crossover where white contrasts better than black). Held as data rather than computed from `device_hex` so the choice can be retuned by editing the row. Only the drawn device's **inner** lines and centre icon follow it; the outer outline stays black whatever the face is lit in, so the shape still reads against the window behind it.
- Seeded with a `None` row (`colour_id = 0`, `device_hex` `NULL`) representing "no colour assigned" — so `category.colour_id` can stay a `NOT NULL` foreign key instead of allowing `NULL` — alongside 20 named colours (`colour_id` 1-20).
- The 20 named colours are the categories listed on [html-color.codes](https://html-color.codes), each seeded with the **first** (canonical) colour of its category as `device_hex`: `Red` (`#ff0000`), `Maroon`, `Brown`, `Tan`, `Orange`, `Peach`, `Gold`, `Yellow`, `Lime`, `Olive`, `Green`, `Teal`, `Cyan`, `Blue`, `Navy`, `Purple`, `Magenta`, `Pink` (`#ffc0cb`), `Grey`, `Silver`. `White` and `Black` are deliberately excluded — the device's LED can't render either (black is just off; white isn't reproducible). Nothing reads `device_hex` yet — it's groundwork for matching calendar-entry colours to the device LED.

### `project` (`database/006_project.sql`)

A named project. Id and name only for now — groundwork for a planned projects feature. Numbered `006_*`, before `category`, so it's created and seeded before the tables that reference it — which matters now that foreign keys are enforced (see the design principle above).

| Column         | Type    | Description                                              |
|----------------|---------|----------------------------------------------------------|
| `project_id`   | INTEGER | Row identifier, primary key, autoincrementing.           |
| `project_name` | TEXT    | Project name. `NOT NULL`.                                |

Constraints:
- `project_name` is `NOT NULL`.
- Seeded with a `None` row pinned to `project_id = 0` — a fixed sentinel for "no project assigned", the same id-0 convention used by `category` (`Unassigned`) and `colour` (`None`), so `category.project_id` can stay `NOT NULL` and default to `0` instead of allowing `NULL`.

### `category` (`database/007_category.sql`)

Named activity category, linked to the icon and colour assigned to it.

| Column       | Type    | Description                                              |
|--------------|---------|------------------------------------------------------------|
| `category_id`  | INTEGER | Row identifier, primary key, autoincrementing.             |
| `category_name`| TEXT    | Category name (e.g. an activity mapped to a face).        |
| `icon_id`    | INTEGER | References `icon.icon_id` — the icon assigned to this category. Use `0` (the seeded `None` icon) if no real icon is assigned. |
| `colour_id`  | INTEGER | References `colour.colour_id` — the colour assigned to this category. Use `0` (the seeded `None` colour) if no real colour is assigned. |
| `project_id` | INTEGER | References `project.project_id` — the project this category belongs to. Use `0` (the seeded `None` project) if no project is assigned. |
| `daily_limit`| INTEGER | Whole minutes of tracked time allowed against this category per day (`0` = no limit). Minutes rather than the seconds convention used by `duration_seconds` elsewhere (e.g. `time_entry`): a limit is a coarse user-set budget, and nobody sets one to the nearest 30 seconds. The day boundary is the `setting` table's `daily_reset_time`, not midnight. `NOT NULL`, defaults to `0`. |
| `cost`       | INTEGER | Cost associated with this category, stored as a whole number of **cents** (e.g. `250` = $2.50) to avoid floating-point money; the UI formats it for display as `$x.xx`. `NOT NULL`, defaults to `0`. Nothing reads it yet — groundwork for a planned cost/billing feature. |
| `active`     | INTEGER | `1` while the category is in use, `0` once it has been retired. Retiring is an `UPDATE`, never a `DELETE`, so historical `time_entry` rows and any face still holding the category keep resolving; a retired category simply stops being offered for new assignments. `NOT NULL`, defaults to `1`, constrained to `0`/`1`. |

Foreign keys — all three parents are seeded with an id-`0` sentinel row, which is what lets these columns be `NOT NULL` and still allow "nothing assigned":
- The `icon_id` column references the PK of the table `icon` described above. `NOT NULL DEFAULT 0` (the `None` icon), so a new category can be inserted without specifying one.
- The `colour_id` column references the PK of the table `colour` described above. `NOT NULL DEFAULT 0` (the `None` colour), for the same reason.
- The `project_id` column references the PK of the table `project` described above. `NOT NULL DEFAULT 0` (the `None` project), for the same reason.

Constraints:
- Seeded with an `Unassigned` row (linked to the `None` icon and the `None` colour), a `Break` row (linked to the `ic_break` icon), and a `Meeting` row (linked to the `ic_meeting` icon) -- both seeded with the `None` colour, since none was specified.
- `UN1_category` is a **partial** unique index: `category_name COLLATE NOCASE` where `active = 1`. Only one *active* category may hold a name, while any number of retired ones may share it. That is what makes "create a new category with the same name" a real choice rather than a way to end up with two live categories nobody can tell apart, and it is why the index cannot simply be `UNIQUE (category_name)` the way `colour_name` and `icon_name` are.
- `COLLATE NOCASE` deliberately matches `AppDataStore.findCategory(named:)`, which is also case-insensitive. An index without it would let `email` and `Email` both be active while the app's own collision check considered them the same name, so the two would disagree about what a duplicate is.
- Because a retired category's name can be taken by an active one while it is away, **reinstating can fail**. `AppDataStore.updateCategoryActive` returns whether the write took, since the Categories tab patches its loaded list rather than re-reading and would otherwise show the checkbox ticked over a row that is still retired.
- `AppDataStore.findCategory(named:)` orders `active DESC, category_id ASC` for the same reason: answering with a retired namesake would have the tab offer to reinstate a category whose name is already taken, which this index then refuses.

### `face` (`database/008_face.sql`)

The 12 physical faces of the TimeFlip device, each linked to the category currently assigned to it.

| Column        | Type    | Description                                                        |
|---------------|---------|-----------------------------------------------------------------------|
| `face_id`     | INTEGER | Primary key, `1`-`12` (matches the device's face numbering).         |
| `category_id` | INTEGER | References `category.category_id` — the category currently assigned to this face. |
| `locked`      | INTEGER | `1` to pin this face's category so it can't be reassigned by accident (a face the user wants permanent, e.g. Break or Meeting), `0` if it can be reassigned freely. `NOT NULL`, defaults to `0`. |

Foreign keys:
- The `category_id` column references the PK of the table `category` described above. `NOT NULL`.

Constraints:
- Seeded with all 12 faces pointing at the `Unassigned` category, except face `2` (`Meeting`) and face `8` (`Break`).
- Those same two faces are the only ones seeded **locked**. They are the two the physical test cube carries stickers for, and the two the `locked` column exists for: a face whose meaning is printed on the cube cannot be reassigned without the sticker becoming a lie. Every other face seeds unlocked, since `Unassigned` is exactly the face you would want to reassign.
- `locked` is constrained to `0`/`1` (SQLite has no native boolean type) and defaults to `0`.

### `time_entry` (`database/009_time_entry.sql`)

A single tracked time span, linked to the category it was logged against.

| Column                      | Type    | Description                                                        |
|------------------------------|---------|-----------------------------------------------------------------------|
| `time_entry_id`              | INTEGER | Row identifier, primary key, autoincrementing.                        |
| `category_id`                | INTEGER | References `category.category_id` — the category this entry was logged against. |
| `device_event_id`           | INTEGER | References `device_event.device_event_id` — the device event this entry was created from. Every time entry has exactly one device event, but not every device event becomes a time entry. |
| `started_at`                 | TEXT    | When the entry started, as a local-time ISO 8601 timestamp with no UTC offset. |
| `start_timezone_id`     | INTEGER | References `timezone.timezone_id` — the IANA zone `started_at` was recorded in.        |
| `ended_at`                   | TEXT    | When the entry ended, as a local-time ISO 8601 timestamp with no UTC offset. |
| `end_timezone_id`       | INTEGER | References `timezone.timezone_id` — the IANA zone `ended_at` was recorded in.          |
| `duration_seconds`           | REAL    | How long the entry lasted, in seconds.                                 |
| `total_cost`                 | INTEGER | Total cost of this entry, stored as a whole number of **cents** (e.g. `250` = $2.50) to avoid floating-point money; the UI formats it for display as `$x.xx`. `NOT NULL`, defaults to `0`. Nothing computes it yet — groundwork alongside `category.cost` for a planned cost/billing feature. |
| `synced_to_google_calendar`  | INTEGER | `1` if this entry has been synced to Google Calendar, `0` otherwise.  |

Foreign keys:
- The `category_id` column references the PK of the table `category` described above. `NOT NULL`.
- The `device_event_id` column references the PK of the table `device_event` described above. `NOT NULL`.
- The `start_timezone_id` and `end_timezone_id` columns both reference the PK of the table `timezone` described above — two separate FKs because `started_at` and `ended_at` are each stamped in whatever zone was current at the time, and a span can cross a zone change. Both `NOT NULL DEFAULT 0` — id `0` is the seeded `Unknown` sentinel.

Constraints:
- `duration_seconds` is constrained to be non-negative.
- `synced_to_google_calendar` is constrained to `0`/`1` (SQLite has no native boolean type) and defaults to `0`.
- `device_event_id` has a `UNIQUE` index (`UN1_time_entry`), so a device event can produce at most one time entry. The creation rule (see `docs/operation-spec.md` § 3) already tests that a segment is not in `time_entry` before converting it, but that test races itself: two sweeps overlapping, or a sweep restarted after a crash between the insert and the `processed` update, would both find the same segment eligible. The index is what makes the rule true rather than merely intended, and it is why `time_entry_check` can be re-run at any time without care.

  It also means a time entry can point at only **one** device event, which matters because of `blip_time`: a segment shorter than that setting is merged into the following one, so a single entry can cover several segments of wall-clock time while naming just the one the user actually settled on. The merged-away segments keep their `device_event` rows and never appear here.

### `device_notification` (`database/010_device_notification.sql`)

Point-in-time device notifications that aren't timing segments — `double_tap`, `battery_level`, `system_state`, `device_info`, `event_log` (see `event_type`). Unlike `device_event`, these don't have a duration or a face; each row is a single moment with a decoded value.

| Column                  | Type    | Description                                                              |
|--------------------------|---------|------------------------------------------------------------------------------|
| `device_notification_id`| INTEGER | Row identifier, primary key, autoincrementing.                              |
| `event_type_id`          | INTEGER | References `event_type.event_type_id` — which kind of notification this is. |
| `start_time`             | TEXT    | When the notification was received, as a local-time ISO 8601 timestamp with no UTC offset. Named to match `device_event` rather than e.g. `occurred_at`, so both device tables can be queried/ordered the same way. |
| `timezone_id`          | INTEGER | References `timezone.timezone_id` — the IANA zone `start_time` was recorded in.              |
| `start_epoch`            | INTEGER | The same moment as `start_time`, as Unix epoch seconds. Indexed.            |
| `payload`                | TEXT    | The decoded value this event type carries (e.g. a battery percentage, a system state name), not the device's raw encoding. |

Foreign keys:
- The `event_type_id` column references the PK of the table `event_type` described above. `NOT NULL`. Always one of the point-in-time types for rows in this table.
- The `timezone_id` column references the PK of the table `timezone` described above. `NOT NULL DEFAULT 0` — id `0` is the seeded `Unknown` sentinel.

Constraints:
- `start_epoch` has a non-unique index (`IN1_device_notification`).

### `setting` (`database/011_setting.sql`)

Generic key/value store for device/app settings — one row per setting, rather than a dedicated column per setting.

| Column                 | Type    | Description                                    |
|-------------------------|---------|---------------------------------------------------|
| `setting_id`            | INTEGER | Row identifier, primary key, autoincrementing.     |
| `setting_name`          | TEXT    | The setting's name, e.g. `led_settings`.           |
| `setting_value`         | TEXT    | The setting's value, always a JSON object (even single-value settings) so reading this table never needs to branch on which row it is. |
| `setting_description`   | TEXT    | Human-readable explanation of what this setting controls. |

Constraints:
- `setting_name` is `UNIQUE` — each setting is only represented by one row.
- `setting_value` is `NOT NULL`.

Seeded rows:
- `double_tap_settings` = `{"enabled":true,"clickThreshold":90,"limit":20,"latency":50,"window":50}` — `enabled` controls whether double-tap gesture detection is on; if `false`, double-tap notifications from the device are ignored. `clickThreshold`/`limit`/`latency`/`window` are the accelerometer parameters, seeded from `DoubleTapParameters.default` in `Sources/TimeFlipApp/TimeFlipDoubleTapParameters.swift` -- captured from a real device's actual registers (see `Tests/Bench/device_register_snapshot.json`), not an arbitrary guess.
- `led_settings` = `{"brightness":50,"blink_interval":5}` — a single record for the only two LED properties the vendor protocol exposes (device cmd `0x09`/`0x0A`; see [`docs/TimeFlip2 BLE Protocol v4.3.md`](TimeFlip2%20BLE%20Protocol%20v4.3.md)):
  - `brightness` (%) and `blink_interval` (seconds — the gap from the end of one blink to the start of the next) are seeded from `AppState`'s `ledBrightnessPercent`/`blinkIntervalSeconds` defaults (`Sources/TimeFlipApp/AppState.swift` lines 91-92).
- `auto_pause_minutes` = `{"minutes":0}` — delay after which the device pauses itself if the face hasn't changed (device cmd `0x05`; `0` disables, matching the vendor protocol's own disabled-by-default behavior; the device itself only supports whole-minute granularity, so this can't be made finer). The timer resets every time the face changes.
- `blip_time` = `{"seconds":5}` — while picking up and turning the device to find the desired face, it can briefly pass over other faces, creating unwanted `device_event` segments for them. Any segment shorter than `seconds` gets no `time_entry` and is marked `processed`; it is **not** merged into the following segment. `0` disables the filter. Edited on the App tab as "Ignore flips under", bounded 0-30. See [Operation Spec § applying `blip_time`](operation-spec.md) for why the device does not do this for us and why lowering the value is reversible.
- `firmware_check` = `{"last_alert":"<today>","interval_months":2}` — a single record for the firmware-update reminder:
  - `last_alert` is a local date (`YYYY-MM-DD`, no companion timezone column since only calendar-date granularity matters here), seeded to the date this row was first inserted (`date('now', 'localtime')`, string-concatenated into the JSON literal at seed time, same style as the rest of this file's hand-written JSON — `ON CONFLICT DO NOTHING` means it's never reseeded on later launches).
  - `interval_months` (seeded to `2`) is how many calendar months after `last_alert` before the user is prompted again to connect the device to the official TimeFlip app and check for a firmware update — there's no documented way this app can check the firmware version itself (see `docs/timeflip.md`).
  - The next-due date is `last_alert + interval_months` (calendar months, not a fixed day count). The Settings button that dismisses the alert resets `last_alert` to the current date regardless of whether the user actually performed the check, pushing the next alert out by `interval_months` either way.
- `time_entry_check` = `{"last_check":"…"}` — when the app last swept `device_event` for finalized segments to turn into `time_entry` rows. A local date-time (`YYYY-MM-DDTHH:MM:SS`), seeded to when the row was created (`strftime('%Y-%m-%dT%H:%M:%S', 'now', 'localtime')`, string-concatenated into the JSON literal at seed time, same style as `connection.last_connection`) so the first sweep has a starting point rather than a null to special-case.
  - A segment is eligible when `finalised = 1`, `paused = 0`, `processed = 0`, and its `device_event_id` is not already in `time_entry`. The last of those is enforced by `UN1_time_entry`, not merely tested, so a sweep that overlaps another or restarts after a crash cannot double-count.
  - Eligible is not the same as producing a row: a segment shorter than `blip_time` is merged into the following one instead (see `docs/operation-spec.md` § 3). Those segments still need marking `processed` when the sweep passes over them, or they stay eligible forever, since no `time_entry` will ever reference them.
- `pause_on_lock` = `{"enabled":true}` — when `enabled`, locking the device from the app (command `0x04`) pauses it first (command `0x06`), so no time is recorded against a category while the device is locked and unattended. The lock is what drives the pause, not the other way round. Applies to both ways the app locks: the status item's double-click gesture, and quitting with this setting on (`applicationShouldTerminate` pauses, then locks). Unlocking does **not** auto-resume — that's a deliberate second decision by the user. Nothing here applies to a pause triggered by double-tapping the device itself; that never locks.
- `fetch_history_interval_seconds` = `{"seconds":10}` — how often `HistoryIngestor` sends a history fetch request (command `0x02`) on a repeating timer, independent of the fetches already triggered by live face/pause events, so any entries the device hasn't pushed a live notification for yet still get picked up. Stored in seconds; a future Settings UI will expose this in minutes and convert before saving here.
- `display_seconds` = `{"enabled":true}` — when `enabled`, the menu bar duration display includes a seconds component (`H:MM:SS`) and refreshes every second; when disabled, it shows `H:MM` and refreshes every minute. Hours are unpadded below 10 (`1:23:45`) and two digits from 10 up (`12:23:45`).
- `low_battery_level` = `{"percent":10}` — the battery percentage (from the Battery Level characteristic `0x2A19`) at or below which the menu bar activity text starts blinking red/white (`MenuBarController`'s `updatedLowBatteryLatch`). To avoid flickering the warning on and off when a reading wobbles right around this value, it only clears again once the battery climbs 5 percentage points above the threshold (a fixed hysteresis margin, not stored in this setting) — see `docs/configuration.md`'s Status Indicators section for the user-facing behavior.
- `debug` = `{"enabled":true,"to_file":false,"directory":"~/Documents/TimeFlip"}`:
  - `enabled` — gates every `DeveloperMode.debugPrint` call: when `true` (and the compile-time `DeveloperMode.isEnabled` flag is also on), each message prints to the terminal *and* is recorded into `debug_log` below, so a test session can be analyzed from the database afterward. Lets a user turn this off (or back on) directly in the DB without a rebuild.
  - `to_file` — **not yet implemented**, a placeholder for a planned support feature: let a non-technical user enable debug logging to a file (instead of needing to run the app from a terminal, or query the database directly) and send that file back when a bug can't be reproduced otherwise. Defaults to `false` since the file-writing side isn't built yet.
  - `directory` — where that log file will be written once `to_file` is implemented; unused until then.
  - See `docs/TODO-devmode.md` for the full design of the `to_file` half (log filename format, restart-required behavior).
- `google_account` = `{}` — everything Google, in one row:
  - `name` / `email` — the connected account's identity, from the OpenID Connect userinfo endpoint. Fetched once after sign-in and reused so the endpoint isn't called on every launch or Settings open. These two are reset on sign-out; the keys below are not, since they are configuration rather than identity.
  - `calendar_id` / `calendar_name` — the calendar time entries sync into. Here rather than in their own row because a calendar selection is meaningless without an account.
  - `client_id` — the OAuth client id. Not a secret (it appears in every OAuth URL), which is why it is not in the Keychain alongside the client secret. Developer mode's `config.json` overrides it at launch.
- `connection` = `{"connected":false,"last_connection":"…","connection_lost":"","quit_request":""}` — **connection**: whether the app can reach its paired device right now, and when that last changed. Every field is transient, moving on each connect and drop.
  - `connected` — true between a successful login and the next drop or quit. This is the flag to read for "is the device reachable now?".
  - `last_connection` — the most recent successful login (a new pairing, or any app-start/reconnect login). Seeded to when the row was created.
  - `connection_lost` — when a drop was last detected. Cleared to `""` on a clean quit, so an intentional shutdown isn't later misread as the device having gone away.
  - `quit_request` — when the app was last asked to quit.
  - The three timestamps exist so an observer can tell *connected now* from *lost the device* from *quit deliberately*, rather than inferring it from a single boolean.
- `paired` = `{"paired":false}`, `device_uuid` = `{}` and `device_name` = `{}` — **pairing**: whether the app knows which device to talk to, which one that is, and what that one is called. All three are durable (see [Pairing vs connection](#pairing-vs-connection) below).
  - `paired` answers *whether*. True from a successful first pairing until the user forgets the device — Forget Device, or the end of a confirmed factory reset. Nothing else clears it. Restored at launch, where it decides whether a connection is worth attempting at all.
  - `device_uuid` answers *which*: the CoreBluetooth peripheral identifier used to reconnect to that same device rather than rediscovering it. Absent until a first pairing, and cleared on forget. The identifier is assigned by this Mac's CoreBluetooth stack rather than by the device, so it means nothing on another machine and is not the device's BLE address.
  - `device_name` answers *what it is called*: the name the cube itself is carrying, its GAP Device Name `0x2A00`, which is what device command `0x15` writes and what a scan sees. Read from the peripheral on every connect and mirrored here, so it follows the device rather than leading it. Absent until the first connection, since the name is read rather than guessed.
  - **The name and the uuid have deliberately different lifetimes, which is why they are two rows rather than one.** Forget Device clears `device_uuid` and **keeps** `device_name`: forgetting does not un-rename the cube, and once a device has been renamed off "TimeFlip" that string is the only thing the filtered scan can match it on, so discarding it would discard the way back to the device. A confirmed factory reset (`0xFF`) clears **both**, the cube having reverted to the vendor name. `0xFE` (reset task info) leaves the name alone and so touches neither.
  - The Device tab's "Not paired" placeholder is a rendering of `paired` being false, not a stored value: `AppState.pairedDeviceName` is display-only and never persisted, so a forgotten-but- remembered name is held in `device_name` without the tab claiming a pairing that is gone.
#### Pairing vs connection

Two distinct things, and the schema keeps them apart because conflating them is what made an out-of-band device reset look like nothing had happened:

| | Row | Lifetime | Changed by |
|---|---|---|---|
| **Pairing** | `paired`, `device_uuid` | Durable | Pairing a device; Forget Device |
| **Device name** | `device_name` | Durable, and outlives Forget Device | Connecting (mirrored from the cube); factory reset clears it |
| **Connection** | `connection` | Transient | Every connect, drop, retry, quit |

Connection is **gated by pairing**: an app that isn't paired has no device to be connected to, so `connection.connected` cannot meaningfully be true while `paired` is false. The reverse is routine — a paired device that is switched off, out of range or simply not reached yet is paired and disconnected, and the app keeps retrying because it still knows which device it wants.

Practically, that means going out of range does **not** write to `paired`. To ask "does this need pairing?" read `paired`; to ask "can the app reach it right now?" read `connection.connected`.

### `debug_log` (`database/012_debug_log.sql`)

Every `DeveloperMode.debugPrint` message, recorded here whenever the `debug` setting's `enabled` field is `true` (see above), in addition to being printed to the terminal — lets a failed test session be reconstructed from the database afterward rather than depending on a terminal transcript that was never captured.

| Column                | Type    | Description                                                        |
|------------------------|---------|--------------------------------------------------------------------|
| `debug_log_id`         | INTEGER | Row identifier, primary key, autoincrementing.                     |
| `logged_at`            | TEXT    | When the message was printed, as a local-time ISO 8601 timestamp with no UTC offset. |
| `timezone_id`          | INTEGER | References `timezone.timezone_id` — the IANA zone `logged_at` was recorded in.       |
| `tag`                  | TEXT    | The `DeveloperMode.DebugTag` raw value (e.g. `TimeFlip`, `history`) identifying which subsystem logged this message — matches the bracketed tag in the terminal output. |
| `message`              | TEXT    | The debug message text, exactly as printed (without the timestamp/tag prefix, which are separate columns here). |

Foreign keys:
- The `timezone_id` column references the PK of the table `timezone` described above. `NOT NULL DEFAULT 0` — id `0` is the seeded `Unknown` sentinel.

Constraints:
- `logged_at`, `timezone_id`, `tag`, `message` are all `NOT NULL`.

No retention/cleanup is implemented yet — this table grows for as long as `debug.enabled` stays `true`.
