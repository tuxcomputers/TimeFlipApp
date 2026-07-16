# Operation Spec: Device Event → Time Entry

[← Back to README](../README.md) · [Workflow](workflow.md) · [Database Design](database-design.md)

This document describes how the app is meant to turn a TimeFlip device's raw Bluetooth activity
into the rows stored by the schema in [Database Design](database-design.md). It's the intended
data flow for the redesigned schema (`event_type`, `device_events`, `icon`, `category`, `face`,
`time_entry`, `device_notifications`) — not a description of the app's current (pre-redesign)
behavior, which this schema is replacing. For *why* the schema is shaped this way — how the
device owner wants to organize activities and faces — see [Workflow](workflow.md).

## Overview

```
TimeFlip device (BLE)
      │
      ▼
Decode raw notification/history frame
      │
      ├─ Timing segment (facet flip / pause) ──► device_events ──► time_entry ──► Google Calendar
      │                                                 ▲
      └─ Point-in-time notification ──────────► device_notifications
                                       (double tap, battery, system state, device info, event log)
```

Every device notification is classified into one `event_type` row first. That classification
decides which of the two tables below it lands in.

## 1. Classifying a device notification

When the app receives a decoded event from the BLE driver (`TimeFlipEvent` today), it's matched
to an `event_type` row by name:

- `facet_flip`, `pause` → come only from the **history stream** (the `...58` characteristic).
  These carry a duration and belong to a timing segment → go to `device_events`.
- `double_tap`, `auto_pause_minutes`, `battery_level`, `system_state`, `device_info`,
  `event_log` → live BLE notifications with no duration → go to `device_notifications`.

## 2. Recording a timing segment (`device_events`)

1. The device's history stream reports a frame: event number, facet byte, timestamp, duration.
   The app decodes this into human-readable values (never stores the raw hex) — see
   [Database Design § decoded, not raw](database-design.md#design-principle-decoded-not-raw).
2. The facet byte's high bit determines `event_type_id` (`facet_flip` vs `pause`) and the decoded
   `face` number (`1`-`12`).
3. The app inserts a `device_events` row: `event_number`, `event_type_id`, `face`, `started_at` /
   `started_at_timezone` (captured in the local timezone at the moment the segment started —
   see [Database Design § local time + timezone](database-design.md#design-principle-local-time--timezone)),
   `duration_seconds`, `is_paused`.
4. `event_number` is `UNIQUE`, so re-ingesting a frame already seen (e.g. after a reconnect) is a
   no-op rather than a duplicate row — the device's history buffer can and does replay frames the
   app has already processed.
5. Per the device's own behavior (see `docs/timeflip.md` §5), the **last frame in every history
   dump is the current, still-open interval** — its duration keeps growing until the segment
   ends. The app should treat this last frame as provisional: keep updating the same
   `device_events` row (matched by `event_number`) rather than creating a new one, until a
   subsequent flip/pause frame finalizes it.

## 3. Turning a finalized segment into a `time_entry`

A `device_events` row becomes a `time_entry` once its segment is finalized (i.e. it's no longer
the device's in-progress last frame — a later event has closed it out):

1. Resolve which `category` the segment belongs to: look up `face.category_id` for the
   `device_events.device_face` value **as it was mapped at the time the segment occurred** — if the
   user re-maps a face to a different category later, already-created `time_entry` rows keep
   their original `category_id` rather than retroactively changing.
2. Insert a `time_entry` row: `category_id`, `device_events_id` (the `device_events` row it came
   from), `started_at`/`started_at_timezone` (copied from the `device_events` row),
   `ended_at`/`ended_at_timezone` (`started_at` + `duration_seconds`, converted back to local
   time), `duration_seconds`, and `synced_to_google_calendar = 0`.
3. Not every `device_events` row necessarily becomes a `time_entry` — see applying `blip_time`
   below.

### Applying `blip_time`

While picking the device up and turning it to find the desired face, it can briefly pass over
other faces, creating short, unwanted `device_events` segments for them before landing on the
intended one. The `blip_time` setting (see [Database Design § `setting`](database-design.md),
seeded to `5` seconds) filters these out:

- When a segment is finalized (step 3 above), compare its `duration_seconds` to `blip_time`.
- If `duration_seconds < blip_time`, don't create a `time_entry` for it — instead, merge it into
  the *following* segment: that next segment's `time_entry` should start from the short
  segment's `started_at` rather than its own, so the accidental blip's duration counts toward
  whichever face the user actually settled on, rather than being recorded against the
  momentarily-passed-over face or lost entirely.
- The `device_events` row for the merged-away segment is still kept as-is (per the "decoded, not
  raw" principle nothing there is deleted) — only `time_entry` creation is affected.

## 4. Recording a point-in-time notification (`device_notifications`)

For any non-timing event type (`double_tap`, `battery_level`, `system_state`, `device_info`,
`event_log`, `auto_pause_minutes`): insert a `device_notifications` row with `event_type_id`,
`occurred_at`/`occurred_at_timezone` (now, in local time), and `payload` — the decoded value for
that event type (e.g. a battery percentage, a system state name), not the device's raw encoding.

## 5. Syncing to Google Calendar

A background process periodically selects `time_entry` rows where
`synced_to_google_calendar = 0`, creates the corresponding Google Calendar event (using the
entry's `category` name, `started_at`, `ended_at`), and on success sets
`synced_to_google_calendar = 1`. A failed delivery leaves the flag at `0` so the row is retried
on the next pass — there's no separate retry-count/backoff column, unlike the old
`integration_event_cursors` design, since idempotent re-delivery is cheap enough not to need one.

## 6. Displaying a category's elapsed time

The menu bar (and any other "how long have I spent on X today" display) must show only **today's**
accumulated time for a category — never a running total that carries over from a previous day.
This was previously observed to be broken (a category showed elapsed time left over from
yesterday); the rule below is the intended, correct behavior:

1. "Today" starts at local midnight (`00:00`) of the current day, in the timezone the entries
   were recorded in (see [Database Design § local time + timezone](database-design.md#design-principle-local-time--timezone)).
2. The displayed total for a category = the sum of `time_entry.duration_seconds` for every
   `time_entry` row with that `category_id` whose `started_at` falls on or after today's
   midnight, **plus** the elapsed time of a currently in-progress segment if the device is right
   now on a face mapped to that category (the same "stored total + live segment" pattern the app
   already uses per-facet — see `MenuBarController.currentDuration`).
3. Because faces map to categories many-to-one (see [Workflow § faces map to categories
   many-to-one](workflow.md#faces-map-to-categories-many-to-one)), this sum must include
   `time_entry` rows created from *every* face mapped to that category, not just whichever face
   is currently active.
4. At midnight, every category's displayed total resets to zero, regardless of whether a segment
   happens to be in progress at that moment — a live segment that spans midnight should only
   count the portion of its elapsed time that falls after midnight toward "today's" total; the
   portion before midnight belongs to the previous day.

## Related documents

- [Workflow](workflow.md) — the intended usage this pipeline serves: recurring vs. short-lived
  categories, and how faces map to categories.
- [Database Design](database-design.md) — full schema, column-by-column.
- [`database/CLAUDE.md`](../database/CLAUDE.md) — naming and storage conventions the schema
  follows.
- [`docs/timeflip.md`](timeflip.md) / [`docs/TimeFlip2 BLE Protocol v4.3.md`](TimeFlip2%20BLE%20Protocol%20v4.3.md) —
  the device's wire protocol this pipeline decodes (official spec takes priority per the root
  [`CLAUDE.md`](../CLAUDE.md)).
