# Operation Spec: Device Event → Time Entry

[← Back to README](../README.md) · [Workflow](workflow.md) · [Database Design](database-design.md)

This document describes how the app is meant to turn a TimeFlip device's raw Bluetooth activity into the rows stored by the schema in [Database Design](database-design.md). It's the intended data flow for the redesigned schema (`event_type`, `device_event`, `icon`, `category`, `face`, `time_entry`, `device_notification`) — not a description of the app's current (pre-redesign) behavior, which this schema is replacing. For *why* the schema is shaped this way — how the device owner wants to organize activities and faces — see [Workflow](workflow.md).

## Overview

```
TimeFlip device (BLE)
      │
      ▼
Decode raw notification/history frame
      │
      ├─ Timing segment (face flip / pause) ──► device_event ──► time_entry ──► Google Calendar
      │                                                 ▲
      └─ Point-in-time notification ──────────► device_notification
                                       (double tap, battery, system state, device info, event log)
```

Every device notification is classified into one `event_type` row first. That classification decides which of the two tables below it lands in.

## 1. Classifying a device notification

When the app receives a decoded event from the BLE driver (`TimeFlipEvent` today), it's matched to an `event_type` row by name:

- `face_flip`, `pause` → come only from the **history stream** (the `...58` characteristic). These carry a duration and belong to a timing segment → go to `device_event`.
- `double_tap`, `auto_pause_minutes`, `battery_level`, `system_state`, `device_info`, `event_log` → live BLE notifications with no duration → go to `device_notification`.

## 2. Recording a timing segment (`device_event`)

1. The device's history stream reports a frame: event number, face byte, timestamp, duration. The app decodes this into human-readable values (never stores the raw hex) — see [Database Design § decoded, not raw](database-design.md#design-principle-decoded-not-raw).
2. The face byte's high bit determines `event_type_id` (`face_flip` vs `pause`) and the decoded `face` number (`1`-`12`).
3. The app inserts a `device_event` row: `event_number`, `event_type_id`, `face`, `started_at` / `started_at_timezone` (captured in the local timezone at the moment the segment started — see [Database Design § local time + timezone](database-design.md#design-principle-local-time--timezone)), `duration_seconds`, `paused`.
4. `event_number` is `UNIQUE`, so re-ingesting a frame already seen (e.g. after a reconnect) is a no-op rather than a duplicate row — the device's history buffer can and does replay frames the app has already processed.
5. Per the device's own behavior (see `docs/timeflip.md` §5), the **last frame in every history dump is the current, still-open interval** — its duration keeps growing until the segment ends. The app should treat this last frame as provisional: keep updating the same `device_event` row (matched by `event_number`) rather than creating a new one, until a subsequent flip/pause frame finalizes it.

## 3. Turning a finalized segment into a `time_entry`

A `device_event` row becomes a `time_entry` once its segment is finalized (i.e. it's no longer the device's in-progress last frame — a later event has closed it out). Precisely, a row is eligible when `finalised = 1`, `paused = 0`, `processed = 0`, and its `device_event_id` is not already in `time_entry` — that last one enforced by `UN1_time_entry` rather than merely tested, so a sweep is safe to re-run. `setting.time_entry_check` records when the last sweep ran. `AppDataStore.createTimeEntriesForFinalisedEvents` is that conversion, and `sweepTimeEntries(trigger:)` is the wider pass that drops the `processed` condition in order to find rows wrongly marked done.

1. Resolve which `category` the segment belongs to: look up `face.category_id` for the `device_event.device_face` value **as it was mapped at the time the segment occurred** — if the user re-maps a face to a different category later, already-created `time_entry` rows keep their original `category_id` rather than retroactively changing.
2. Insert a `time_entry` row: `category_id`, `device_event_id` (the `device_event` row it came from), `started_at`/`started_at_timezone` (copied from the `device_event` row), `ended_at`/`ended_at_timezone` (`started_at` + `duration_seconds`, converted back to local time), `duration_seconds`, and `synced_to_google_calendar = 0`.
3. Not every `device_event` row necessarily becomes a `time_entry` — see applying `blip_time` below.

### Applying `blip_time`

While picking the device up and turning it to find the desired face, it can briefly pass over other faces, creating short, unwanted `device_event` segments for them before landing on the intended one. The `blip_time` setting (see [Database Design § `setting`](database-design.md), seeded to `5` seconds, edited on the App tab as "Ignore flips under") filters these out:

- When a segment is finalized (step 3 above), compare its `duration_seconds` to `blip_time`.
- If `duration_seconds < blip_time`, **no `time_entry` is created** and the segment is marked `processed = 1`. Strictly less than, so a segment exactly as long as the threshold is kept. `blip_time = 0` disables the filter, and then even a zero-length segment converts.
- Marking it `processed` is what stops the eligible set growing a permanent tail of rows every later pass has to re-examine. It also means a skipped blip is `processed = 1` with no entry, which is the exact shape of the defect `sweepTimeEntries` reports, so the blip test runs *before* the insert, and a pass-over is never reported as corruption.
- The `device_event` row is kept as-is (per the "decoded, not raw" principle nothing there is deleted); only `time_entry` creation is affected. That is also what makes the threshold reversible: **lowering `blip_time` converts previously-skipped segments** on the next sweep, since they are still absent from `time_entry` and the sweep ignores `processed`. They will be reported as REPAIRED, because from the sweep's position that is indistinguishable from the real defect. Raising it changes nothing; entries already made stay made.

**The blip is not merged into the following segment**, though an earlier version of this spec called for exactly that: the next segment's entry starting from the blip's `started_at`, so the seconds counted toward the face the user settled on. Dropped deliberately. It depends on a `duration_seconds` this data does not reliably have (see the note below), and it was what forced the awkward "processed with no entry" case. Losing a few seconds per pass-over is the cheaper mistake.

**The device does not do this for us, and it looks as though it does.** The vendor spec's "the history will be sent with all intervals that lasted for at least 5 sec" is a property of the `0x02` stream alone, not of what the cube records: it keeps short intervals and returns them happily to a single-event `0x01` read, and `fillHistoryGaps` relies on exactly that. Blips reach this app anyway, by the live path rather than the stream — every flip triggers a history fetch, which writes the now-current segment with the duration it has at that instant, and the next flip closes it out. On 2026-08-02, 13 of 63 finalized unpaused production segments were under 5 seconds and 8 of them read `0.0`. That reasoning removed this section once already; it is written down here so it does not remove it a second time.

Note also that a blip's recorded `duration_seconds` is not trustworthy. It is whatever the last fetch saw, so a segment the following event shows to have lasted 3 seconds can be stored as `0.0` (production `device_event` 28 and 29). Anything built on top of this should treat a sub-`blip_time` duration as "short", not as a measurement.

## 4. Recording a point-in-time notification (`device_notification`)

For any non-timing event type (`double_tap`, `battery_level`, `system_state`, `device_info`, `event_log`, `auto_pause_minutes`): insert a `device_notification` row with `event_type_id`, `occurred_at`/`occurred_at_timezone` (now, in local time), and `payload` — the decoded value for that event type (e.g. a battery percentage, a system state name), not the device's raw encoding.

## 5. Syncing to Google Calendar

A background process periodically selects `time_entry` rows where `synced_to_google_calendar = 0`, creates the corresponding Google Calendar event (using the entry's `category` name, `started_at`, `ended_at`), and on success sets `synced_to_google_calendar = 1`. A failed delivery leaves the flag at `0` so the row is retried on the next pass — there's no separate retry-count/backoff column, unlike the removed cursor-table design that preceded it, since idempotent re-delivery is cheap enough not to need one.

## 6. Displaying a category's elapsed time

The menu bar (and any other "how long have I spent on X today" display) must show only **today's** accumulated time for a category — never a running total that carries over from a previous day. This was previously observed to be broken (a category showed elapsed time left over from yesterday); the rule below is the intended, correct behavior. It is implemented by `DailyCategoryTotals` plus `MenuBarController.currentDuration`.

1. "Today" starts at the `setting` table's `daily_reset_time` (seeded to `03:00`, editable on the App tab), in the timezone the entries were recorded in (see [Database Design § local time + timezone](database-design.md#design-principle-local-time--timezone)). **Not midnight**, which is what this said before the setting existed: a boundary in the small hours means a session running past midnight stays on the day it started, which is the whole reason the setting is configurable. Same boundary the `category.daily_limit` budget is measured against.
2. The displayed total for a category = the sum of `time_entry.duration_seconds` for every `time_entry` row with that `category_id` overlapping the current window, **plus** the elapsed time of a currently in-progress segment if the device is right now on a face mapped to that category. The in-progress segment has no `time_entry` row yet, which is what keeps it from being counted twice.
3. Because faces map to categories many-to-one (see [Workflow § faces map to categories many-to-one](workflow.md#faces-map-to-categories-many-to-one)), this sum must include `time_entry` rows created from *every* face mapped to that category, not just whichever face is currently active. Keying the totals by face instead is exactly how this went wrong: two faces sharing a category each counted alone, so 40 minutes on one and 40 on another left a 60-minute `daily_limit` unreached and the menu bar drew one face's figure beside the shared category's name.
4. `time_entry.category_id` is what the sum groups by, deliberately, rather than re-deriving the category by joining `device_event` to `face`. An entry records the category the face was mapped to **when the segment happened**; the current mapping would move a day's work to whatever the face points at next. This is the same reason `updateFaceCategory` sweeps before it writes.
5. At the reset boundary, every category's displayed total returns to zero, regardless of whether a segment happens to be in progress at that moment — a live segment spanning the boundary counts only the portion after it toward "today's" total; the portion before belongs to the previous day.

## 7. Reaching a category's daily limit

`category.daily_limit` is a **hard** limit, not a warning: the figure from § 6 reaching it stops the cube. Implemented by `DailyLimitEnforcement` (every rule, and the reasoning) plus `MenuBarController.enforceDailyLimit` (the figures and the writes). `daily_limit = 0` means no limit, so nothing below applies to it.

1. When the category on show reaches its limit, the app pauses the device (`0x06 0x01`) and then **refuses to send the unpause** while that category is still the one on show. The refusal is the enforcement, and it is the app's rather than the device's: nothing in the protocol asks the device to hold a pause against its own user, so `0x06 0x02` is honoured whenever it arrives. The limit is therefore exactly as hard as the set of paths that can send it, which is why they are enumerated in point 3.
2. The pause fires on the second the budget is spent, from a one-shot timer, not on the menu bar's display tick — that tick is a whole minute wide when the seconds preference is off, and how far a hard limit overruns must not depend on a display setting.
3. Three paths can unpause a cube, and the limit answers each differently:
   - The dropdown's **Resume** item and the status item's **right half** both reach `MenuBarController.togglePause`, which declines to send while the budget is spent. The dropdown item is also disabled ([`MenuBarDropdownRules.allowsPause`](../Sources/TimeFlipApp/MenuBarDropdownRules.swift)), so the refusal is visible rather than a click that silently does nothing. **Pausing** is never refused, only resuming.
   - A **double tap on the cube** pauses and unpauses it in firmware, telling the app afterwards (see the Double tap characteristic in [the protocol spec](TimeFlip2%20BLE%20Protocol%20v4.3.md)). It cannot be refused, only answered: the history frame reports the cube running, and the pause goes straight back out.
4. Flipping to a face whose category still has budget **resumes** the cube automatically, and flipping back to the spent face pauses it again. Pause is a property of the cube where a limit is a property of a category, so holding the pause across a flip would spend one category's budget and stop the whole day's tracking with it. Only a pause the limit itself asked for is lifted this way — a pause the user asked for is theirs.
5. A category that has reached its limit **stays** reached until the next `daily_reset_time` boundary, or until its `daily_limit` is edited. It deliberately does not follow the total back down, because the total dips on its own: pausing stops the live segment counting, and the segment that ran the budget out is not a `time_entry` until the pause's history fetch ingests it, so for a moment the figure reads under the limit. Re-deriving in that window resumes the cube on the strength of a total the app knows is incomplete. An edit to the limit is answered immediately, being the one signal a stale total cannot imitate.
6. None of this is persisted. The device holds its own pause across a quit, and the totals are re-derived from `time_entry` on launch, so a relaunch onto a paused cube resting on a spent category re-arms the hold from those two facts alone.
7. Manual mode is excluded: the limit is enforced by pausing a cube and a manual session has none, so blocking its Resume would refuse to restart a timer that nothing ever stopped.

## Related documents

- [Workflow](workflow.md) — the intended usage this pipeline serves: recurring vs. short-lived categories, and how faces map to categories.
- [Database Design](database-design.md) — full schema, column-by-column.
- [`database/CLAUDE.md`](../database/CLAUDE.md) — naming and storage conventions the schema follows.
- [`docs/timeflip.md`](timeflip.md) / [`docs/TimeFlip2 BLE Protocol v4.3.md`](TimeFlip2%20BLE%20Protocol%20v4.3.md) — the device's wire protocol this pipeline decodes (official spec takes priority per the root [`CLAUDE.md`](../CLAUDE.md)).
