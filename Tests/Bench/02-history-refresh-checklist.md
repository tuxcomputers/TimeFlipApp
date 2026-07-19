# History Refresh Checklist

Covers the periodic/live-event history refresh rework: the cheap max-event-number check, the
skip-and-refresh-duration fast path, and the ambiguous/cut-short-stream safeguards (see
`HistoryIngestor.refreshHistory`). Requires a paired physical TimeFlip device and the app running
with Developer Mode enabled and the `debug` setting's `enabled` field `true` (see
`009_setting.sql`) -- every dev-only debug message is then also recorded to the `debug_log` table,
so all log-reading steps below are plain `sqlite3` queries against it, not a terminal transcript
that has to be captured live.

The scenarios here need no human hand on the cube: they either wait on the refresh timer or
quit/relaunch the app, and assert entirely from the DB. The scenarios that require physically
flipping the device (a normal flip, and the out-of-range backlog) live in
`Tests/Interactive/02-history-refresh-checklist.md`, run after this one.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Setup

- [ ] Launch the app with the device already paired and connected (see "Driving the app directly"
      in `../CLAUDE.md`); confirm via a fresh `debug_log` `"Login accepted, code=0x02"` row.
- [ ] Query the current state as a baseline:
      `sqlite3 ~/Library/Application\ Support/TimeFlip/appdata.sqlite "SELECT event_number, device_face, duration_seconds, finalised FROM device_events ORDER BY event_number DESC LIMIT 3;"`

## Scenario A -- nothing changes (skip path + duration refresh)

- [ ] Note the current max `event_number` and its `duration_seconds` from Setup.
- [ ] Wait out at least one full `fetch_history_interval_seconds` period (check the setting;
      default is short enough to not need a long wait), leaving the device untouched (same facet,
      not paused).
- [ ] Query `debug_log` for a `history` row containing `device max_event_number=<N> unchanged; DB
      refreshed` (not a full stream fetch) logged after the baseline query.
- [ ] Re-query `device_events` for that same `event_number` and confirm `duration_seconds`
      increased since the baseline, with no new rows added.

## Scenario D -- quit and relaunch resumes from the persisted cursor

- [ ] Note the current `integration_event_cursors.last_sent_ev` for `identifier = 'device-history'`.
- [ ] Quit the app (`osascript -e 'tell application "TimeFlip" to quit'`), then relaunch it;
      confirm via a fresh `debug_log` `"Login accepted, code=0x02"` row.
- [ ] Query `debug_log` for the startup history fetch's `known_max=` value and confirm it matches
      that persisted cursor (not `known_max=0` / a full re-fetch of all history). (Confirmed:
      `trigger=startup known_max=36` -- the cursor had legitimately advanced from 35 to 36 between
      the baseline note and quitting, since event 36 was finalised in that window, and startup
      correctly resumed from that persisted value rather than re-fetching all history.)
- [ ] Confirm the menu bar's displayed facet/duration matches the DB-derived state immediately
      after reconnecting -- the accumulated total of today's non-paused, finalized segments for the
      current facet, from `device_events`, per the `dailyFacetDurations`/`isPaused` logic in
      `MenuBarController.swift`/`DailyFacetTotals.swift`, not the still-open event's own
      `duration_seconds`. Read the status item's title directly via accessibility (`get name of
      every menu bar item of menu bar 2` for process `"TimeFlip"` -- see "Driving the app directly"
      in `../CLAUDE.md`), no screenshot needed. (Confirmed: menu bar showed "Meeting" at 20:07,
      paused -- events 18, 20, 23, 27, 32, 34, 36: 1+301+301+33+5+265+302 = 1208s = 20:08 -- the
      still-open event 37 is excluded both because it isn't finalized yet and because it's
      currently paused (`is_paused=1`).)
