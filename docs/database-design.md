# Database Design

[← Back to README](../README.md)

This document describes the schema used to persist TimeFlip data locally. DDL files for each
table live in [`database/`](../database), numbered in the order they should be applied. See
[`database/CLAUDE.md`](../database/CLAUDE.md) for the storage conventions referenced below.

## Design principle: decoded, not raw

The TimeFlip device reports events over Bluetooth as raw hex payloads (e.g. a facet byte, a
big-endian duration, a status flag). This database never stores those raw bytes directly —
every column holds the *decoded, human-readable* value instead. For example, the device's raw
facet byte is converted to a plain facet number (`1`-`12`) before it's written to the `face`
column, so the table can be read and reasoned about directly (in a SQLite browser, in `sqlite3`,
etc.) without needing to know the device's wire format.

## Design principle: local time + timezone

Date/time columns store **local time**, not UTC, paired with a companion `<name>_timezone`
column holding the IANA timezone identifier the local time was captured in (e.g.
`America/New_York`). The timestamp itself omits any UTC offset/`Z` suffix — the offset is only
recoverable via the timezone column — so it always reads the same as the wall-clock time at the
moment it was recorded, regardless of what timezone the reader is in.

## Tables

### `event_type` (`database/001_event_type.sql`)

Reference table of the different event types the TimeFlip device can trigger. Most of these
(`double_tap`, `battery_level`, `system_state`, `device_info`, `event_log`) are live BLE
notifications the device sends outside the history stream, not timing segments, and so never
appear in `device_events` — only `facet_flip` and `pause` come from the history stream that
populates `device_events` (see `Sources/TimeFlipApp/TimeFlipEvent.swift` and
`docs/timeflip.md` §4-5 for the full notification/history breakdown).

| Column           | Type    | Description                                              |
|-------------------|---------|-------------------------------------------------------------|
| `event_type_id`   | INTEGER | Primary key. Not autoincrementing — seeded with fixed IDs.  |
| `event_name`      | TEXT    | Event type name, e.g. `facet_flip`, `pause`, `double_tap`.   |

Constraints:
- `event_name` is `UNIQUE` — each event type is only represented by one row.
- Seeded with all known device event types: `facet_flip`, `pause`, `double_tap`,
  `auto_pause_minutes`, `battery_level`, `system_state`, `device_info`, `event_log`.

### `device_events` (`database/002_device_events.sql`)

One row per device-reported timing segment — created whenever the device is flipped to a new
facet or paused/resumed, marking the end of the previous segment.

| Column             | Type    | Description                                                                 |
|---------------------|---------|-------------------------------------------------------------------------------|
| `device_events_id`  | INTEGER | Row identifier, primary key, autoincrementing.                              |
| `event_number`      | INTEGER | The device's own sequence number for this event. Unique — used to detect duplicate/replayed events from the device's history buffer. |
| `event_type_id`     | INTEGER | References `event_type.event_type_id` — always `facet_flip` or `pause` for rows in this table. |
| `device_face`       | INTEGER | Decoded facet number, `1`-`12`. Decoded from the device's raw facet byte, not stored as hex. |
| `started_at`        | TEXT    | When the segment started, as a local-time ISO 8601 timestamp with no UTC offset (e.g. `2026-07-16T09:30:00`). Decoded from the device's raw timestamp encoding. |
| `started_at_timezone` | TEXT  | IANA timezone identifier (e.g. `America/New_York`) `started_at` was recorded in.            |
| `duration_seconds`  | REAL    | How long the segment lasted, in seconds.                                    |
| `is_paused`         | INTEGER | `1` if this segment was a paused interval, `0` otherwise.                   |
| `finalised`         | INTEGER | `1` once the segment is closed out, `0` while it's still the device's in-progress interval. |
| `processed`         | INTEGER | `1` once this segment has been turned into a `time_entry` (or merged away per `blip_time`), `0` otherwise. |

Constraints:
- `event_number` is `UNIQUE` so re-ingesting an event already seen (e.g. after a reconnect) is a
  no-op rather than a duplicate row.
- `event_type_id` is a foreign key referencing `event_type(event_type_id)`, `NOT NULL`.
- `device_face` is constrained to the valid TimeFlip facet range (`1`-`12`).
- `duration_seconds` is constrained to be non-negative.
- `is_paused` is constrained to `0`/`1` (SQLite has no native boolean type).
- `finalised` is constrained to `0`/`1` (SQLite has no native boolean type) and defaults to `0`.
- `processed` is constrained to `0`/`1` (SQLite has no native boolean type) and defaults to `0`.

`finalised` vs. `processed`: the device's history stream always reports its still-open,
in-progress segment as the last frame in every dump (see `docs/timeflip.md` §5). That frame is
inserted with `finalised = 0` and its row is updated in place (matched by `event_number`,
`ON CONFLICT ... DO UPDATE`) as the duration keeps growing on each refresh, until a subsequent
flip/pause closes it out and a later write sets `finalised = 1`. `processed` is a separate,
independent flag — it tracks whether a (finalised) segment has been turned into a `time_entry`
yet, and is only ever meaningful once `finalised = 1`; the `finalised` update path never touches
it, so an already-`processed` row can't be silently un-flagged by the live segment's growth.

### `icon` (`database/003_icon.sql`)

Reference table of activity icons that can be assigned to a facet.

| Column     | Type    | Description                                                                                   |
|------------|---------|-------------------------------------------------------------------------------------------------|
| `icon_id`  | INTEGER | Row identifier, primary key, autoincrementing.                                                  |
| `icon_name`| TEXT    | Identifier the app uses to locate the icon asset (see `ActivityIconLoader`), e.g. `"briefcase"`. |

Constraints:
- `icon_name` is `UNIQUE` — each icon asset is only represented by one row.
- Seeded with a `blank` row (`icon_id = 0`) representing "no icon assigned", alongside the real
  icon assets (`icon_id` 1-42) — so `category.icon_id` can stay a `NOT NULL` foreign key instead
  of allowing `NULL`.

### `colour` (`database/004_colour.sql`)

Reference table of the colours available to assign to a category.

| Column      | Type    | Description                                              |
|-------------|---------|--------------------------------------------------------------|
| `colour_id`   | INTEGER | Primary key. Not autoincrementing — seeded with fixed IDs.   |
| `colour_name` | TEXT    | Colour name, e.g. `Red`, `Teal`, `Cyan`.                      |

Constraints:
- `colour_name` is `UNIQUE` — each colour is only represented by one row.
- Seeded with a `blank` row (`colour_id = 0`) representing "no colour assigned", alongside the 12
  selectable system colours (`colour_id` 1-12: `Red`, `Green`, `Blue`, `Orange`, `Yellow`,
  `Brown`, `Pink`, `Purple`, `Teal`, `Indigo`, `Mint`, `Cyan`) — matching
  `ActivityLibrary.colorOptions` in the app's facet color picker — so `category.colour_id` can
  stay a `NOT NULL` foreign key instead of allowing `NULL`.

### `category` (`database/005_category.sql`)

Named activity category, linked to the icon and colour assigned to it.

| Column       | Type    | Description                                              |
|--------------|---------|------------------------------------------------------------|
| `category_id`  | INTEGER | Row identifier, primary key, autoincrementing.             |
| `category_name`| TEXT    | Category name (e.g. an activity mapped to a facet).        |
| `icon_id`    | INTEGER | References `icon.icon_id` — the icon assigned to this category. Use `0` (the seeded `blank` icon) if no real icon is assigned. |
| `colour_id`  | INTEGER | References `colour.colour_id` — the colour assigned to this category. Use `0` (the seeded `blank` colour) if no real colour is assigned. |

Constraints:
- `icon_id` is a foreign key referencing `icon(icon_id)`, `NOT NULL`, defaulting to `0` (`blank`)
  so a new category can be inserted without specifying one.
- `colour_id` is a foreign key referencing `colour(colour_id)`, `NOT NULL`, defaulting to `0`
  (`blank`) for the same reason.
- Seeded with an `Unassigned` row, linked to the `blank` icon and the `blank` colour.

### `face` (`database/006_face.sql`)

The 12 physical facets of the TimeFlip device, each linked to the category currently assigned to
it.

| Column        | Type    | Description                                                        |
|---------------|---------|-----------------------------------------------------------------------|
| `face_id`     | INTEGER | Primary key, `1`-`12` (matches the device's facet numbering).         |
| `category_id` | INTEGER | References `category.category_id` — the category currently assigned to this facet. |

Constraints:
- `category_id` is a foreign key referencing `category(category_id)`, `NOT NULL`.
- Seeded with all 12 faces pointing at the `Unassigned` category.

### `time_entry` (`database/007_time_entry.sql`)

A single tracked time span, linked to the category it was logged against.

| Column                      | Type    | Description                                                        |
|------------------------------|---------|-----------------------------------------------------------------------|
| `time_entry_id`              | INTEGER | Row identifier, primary key, autoincrementing.                        |
| `category_id`                | INTEGER | References `category.category_id` — the category this entry was logged against. |
| `device_events_id`           | INTEGER | References `device_events.device_events_id` — the device event this entry was created from. Every time entry has exactly one device event, but not every device event becomes a time entry. |
| `started_at`                 | TEXT    | When the entry started, as a local-time ISO 8601 timestamp with no UTC offset. |
| `started_at_timezone`        | TEXT    | IANA timezone identifier `started_at` was recorded in.                |
| `ended_at`                   | TEXT    | When the entry ended, as a local-time ISO 8601 timestamp with no UTC offset. |
| `ended_at_timezone`          | TEXT    | IANA timezone identifier `ended_at` was recorded in.                   |
| `duration_seconds`           | REAL    | How long the entry lasted, in seconds.                                 |
| `synced_to_google_calendar`  | INTEGER | `1` if this entry has been synced to Google Calendar, `0` otherwise.  |

Constraints:
- `category_id` is a foreign key referencing `category(category_id)`, `NOT NULL`.
- `device_events_id` is a foreign key referencing `device_events(device_events_id)`, `NOT NULL`.
- `duration_seconds` is constrained to be non-negative.
- `synced_to_google_calendar` is constrained to `0`/`1` (SQLite has no native boolean type) and
  defaults to `0`.

### `device_notifications` (`database/008_device_notifications.sql`)

Point-in-time device notifications that aren't timing segments — `double_tap`, `battery_level`,
`system_state`, `device_info`, `event_log` (see `event_type`). Unlike `device_events`, these don't
have a duration or a facet; each row is a single moment with a decoded value.

| Column                  | Type    | Description                                                              |
|--------------------------|---------|------------------------------------------------------------------------------|
| `device_notifications_id`| INTEGER | Row identifier, primary key, autoincrementing.                              |
| `event_type_id`          | INTEGER | References `event_type.event_type_id` — which kind of notification this is. |
| `occurred_at`            | TEXT    | When the notification was received, as a local-time ISO 8601 timestamp with no UTC offset. |
| `occurred_at_timezone`   | TEXT    | IANA timezone identifier `occurred_at` was recorded in.                     |
| `payload`                | TEXT    | The decoded value this event type carries (e.g. a battery percentage, a system state name), not the device's raw encoding. |

Constraints:
- `event_type_id` is a foreign key referencing `event_type(event_type_id)`, `NOT NULL`.

### `setting` (`database/009_setting.sql`)

Generic key/value store for device/app settings — one row per setting, rather than a dedicated
column per setting.

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
- `double_tap_settings` = `{"enabled":true,"clickThreshold":20,"limit":10,"latency":20,"window":40}`
  — `enabled` controls whether double-tap gesture detection is on; if `false`, double-tap
  notifications from the device are ignored. `clickThreshold`/`limit`/`latency`/`window` are the
  accelerometer parameters, seeded from `DoubleTapParameters.default` in
  `Sources/TimeFlipApp/TimeFlipDoubleTapParameters.swift`.
- `led_settings` = `{"brightness":50,"blink_interval":5,"blink_length":0,"blink_speed":0}` — a
  single record for all LED settings:
  - `brightness` (%) and `blink_interval` (seconds — the gap from the end of one blink to the
    start of the next) are seeded from `AppState`'s `ledBrightnessPercent`/`blinkIntervalSeconds`
    defaults (`Sources/TimeFlipApp/AppState.swift` lines 91-92).
  - `blink_length` (seconds — the full duration of one blink, start to end) and `blink_speed`
    (`0`-`100`%) have no code equivalent yet, so `0` is a placeholder. Their intended behavior:
    `blink_speed` is the percentage of `blink_length` spent ramping up from `0` to `brightness`,
    before immediately fading back down. Precisely:
    - `ramp = blink_length × (blink_speed / 100)`
    - if `blink_speed ≤ 50`: fade back down also takes `ramp` seconds, and the LED holds at
      `brightness` for the leftover `blink_length − 2 × ramp` seconds in between.
    - if `blink_speed > 50`: there's no time left for a full symmetric fade, so the fade takes
      whatever time remains (`blink_length − ramp`) and there's no hold at `brightness`.

    Worked examples (`blink_length = 5` seconds):
    | `blink_speed` | Behavior |
    |---|---|
    | `0%` | Instantly on at 100% brightness, holds for all 5s, then turns off instantly. |
    | `20%` | Ramps up over 1s, holds at 100% for 3s, fades off over the last 1s. |
    | `50%` | Ramps up over 2.5s, then immediately starts fading for the remaining 2.5s (no hold). |
    | `80%` | Ramps up over 4s, then fades off over the remaining 1s (no hold). |
    | `100%` | Ramps up over the full 5s, then turns off instantly. |
- `blip_time` = `{"seconds":5}` — while picking up and turning the device to find the desired
  face, it can briefly pass over other faces, creating unwanted `device_events` segments for
  them. Any segment shorter than `seconds` is merged into the *following* segment rather than
  becoming its own `time_entry` — see [Operation Spec § applying `blip_time`](operation-spec.md).
- `firmware_check` = `{"last_alert":"<today>","interval_months":2}` — a single record for the
  firmware-update reminder:
  - `last_alert` is a local date (`YYYY-MM-DD`, no companion timezone column since only
    calendar-date granularity matters here), seeded to the date this row was first inserted
    (`date('now', 'localtime')`, string-concatenated into the JSON literal at seed time, same
    style as the rest of this file's hand-written JSON — `ON CONFLICT DO NOTHING` means it's
    never reseeded on later launches).
  - `interval_months` (seeded to `2`) is how many calendar months after `last_alert` before the
    user is prompted again to connect the device to the official TimeFlip app and check for a
    firmware update — there's no documented way this app can check the firmware version itself
    (see `docs/timeflip.md`).
  - The next-due date is `last_alert + interval_months` (calendar months, not a fixed day count).
    The Settings button that dismisses the alert resets `last_alert` to the current date
    regardless of whether the user actually performed the check, pushing the next alert out by
    `interval_months` either way.
- `pause_on_lock` = `{"enabled":true}` — when `enabled`, pausing via the app (command `0x06`)
  also engages device lock mode (command `0x04`) so the device can't be flipped to a new facet
  while paused. Does not apply when pause is triggered by a double-tap on the device itself —
  that pause is left unlocked.
- `fetch_history_interval_seconds` = `{"seconds":10}` — how often `HistoryIngestor` sends a
  history fetch request (command `0x02`) on a repeating timer, independent of the fetches already
  triggered by live facet/pause events, so any entries the device hasn't pushed a live
  notification for yet still get picked up. Stored in seconds; a future Settings UI will expose
  this in minutes and convert before saving here.
- `display_seconds` = `{"enabled":true}` — when `enabled`, the menu bar duration display includes
  a seconds component (`H:MM:SS`) and refreshes every second; when disabled, it shows `H:MM` and
  refreshes every minute. Hours are unpadded below 10 (`1:23:45`) and two digits from 10 up
  (`12:23:45`).
- `low_battery_level` = `{"percent":5}` — the battery percentage (from the Battery Level
  characteristic `0x2A19`) at or below which the menu bar activity text starts blinking red/white
  (`MenuBarController`'s `updatedLowBatteryLatch`). To avoid flickering the warning on and off when
  a reading wobbles right around this value, it only clears again once the battery climbs 5
  percentage points above the threshold (a fixed hysteresis margin, not stored in this setting) —
  see `docs/configuration.md`'s Status Indicators section for the user-facing behavior.
- `debug` = `{"enabled":true,"to_file":false,"directory":"~/Documents/TimeFlip"}` — **not yet
  implemented**, this is a placeholder seed for a planned support feature: let a non-technical
  user enable debug logging to a file (instead of needing to run the app from a terminal) and
  send that file back when a bug can't be reproduced otherwise. `to_file` defaults to `false`
  since the file-writing side isn't built yet. See `docs/TODO-devmode.md` for the full design
  (log filename format, how this relates to the existing terminal-only `DeveloperMode` logging,
  and restart-required behavior).
