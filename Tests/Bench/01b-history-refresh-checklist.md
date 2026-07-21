# History Refresh Checklist

Covers the periodic/live-event history refresh rework: the cheap max-event-number check, the
skip-and-refresh-duration fast path, and the ambiguous/cut-short-stream safeguards (see
`HistoryIngestor.refreshHistory`). Requires a paired physical TimeFlip device and the app running
with Developer Mode enabled and the `debug` setting's `enabled` field `true` (see
`011_setting.sql`) -- every dev-only debug message is then also recorded to the `debug_log` table,
so all log-reading steps below are plain `sqlite3` queries against it, not a terminal transcript
that has to be captured live.

The scenarios here need no human hand on the cube: they either wait on the refresh timer or
quit/relaunch the app, and assert entirely from the DB. The scenarios that require physically
flipping the device (a normal flip, and the out-of-range backlog) live in
`Tests/Interactive/01i-history-refresh-checklist.md`, run after the whole Bench phase.

**Runs before `02b-reset-device-checklist.md`, deliberately** -- `02b`'s factory reset wipes the
device's own onboard event counter, and `HistoryIngestor.nextStartCursor()` starts a fresh
`test.sqlite`'s first fetch at event 0 (no persisted cursor yet), so that first fetch pulls in
however much real history the device still has onboard. Running this checklist first, while that
real history is still intact, is what gives Scenario A (an already-open, growing row) and Scenario
B (an existing persisted cursor) something real to check against, without depending on any flip
happening first.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Setup

- [x] Confirm `db_type` currently reads `{"type":"production"}` and the device is connected.
      (Confirmed: `db_type` setting = `{"type":"production"}`; `history` debug_log rows show
      periodic fetches succeeding against a connected device.)
- [x] Query `device_event` (`ORDER BY device_event_id DESC LIMIT 1`) and confirm the largest
      `event_number` is at least 10 -- enough real history for Scenario A/B below to have something
      substantial to observe, not just a couple of events. If it's lower, let the device accumulate
      more real use first rather than proceeding on thin history. (Confirmed: latest
      `event_number`=13, row open with `finalised=0`, `duration_seconds=3802.0`.)
- [x] Quit the app. Method: Quit the app (`../Methods.md`). (Confirmed: `osascript ... quit`, no
      `TimeFlip.app` process remained.)
- [x] Run `scripts/use-test-database.sh`. Method: Switch to the test database (`../Methods.md`) --
      this creates a fresh, empty `test.sqlite`, with no persisted cursor. (Confirmed: script
      created a fresh `test.sqlite` and repointed the `appdata.sqlite` symlink at it.)
- [ ] Start the app and confirm it reconnects to the device. Method: Launch the app for a
      Claude-driven step, Confirm device reconnect (`../Methods.md`).
- [ ] Query `db_type` and confirm it reads `{"type":"test"}` before proceeding.
- [ ] Confirm the fresh test DB actually read the device's real history on this first fetch: query
      `debug_log` for the `history`-tagged startup fetch and confirm it pulled in events (not
      `known_max=0` with nothing following), then query `device_event` and confirm the baseline
      noted above is now reflected locally, with the latest row open/growing:
      `sqlite3 ~/Library/Application\ Support/TimeFlip/appdata.sqlite "SELECT event_number, device_face, duration_seconds, finalised FROM device_event ORDER BY event_number DESC LIMIT 3;"`

## Scenario A -- nothing changes (skip path + duration refresh)

**Preconditions:** an already-open, actively-growing `device_event` row -- established by Setup
immediately above, which this scenario runs straight on from.

- [ ] Note the currently-open `device_event` row's `event_number` and `duration_seconds` (call the
      latter D0).
- [ ] Wait for at least one periodic refresh interval (`SELECT setting_value FROM setting WHERE
      setting_name = 'fetch_history_interval_seconds';`) without touching the device.
- [ ] Query `debug_log` and confirm a `history` row logged `"history fetch: device
      max_event_number=<event_number> unchanged; DB refreshed"` -- the cheap-check skip path was
      taken, not a full stream fetch.
- [ ] Re-query the same `device_event` row: confirm `event_number` is unchanged but
      `duration_seconds` increased beyond D0 -- the skip path still refreshes the open row's
      duration.

## Scenario B -- quit and relaunch resumes from the persisted cursor

**Preconditions:** an existing `device-history` row in `integration_event_cursors` --
`HistoryIngestor.persistDeviceCursor()` writes this once `lastCommittedEventNumber` is non-nil,
which Setup's own backfill above (multiple real, already-closed historical events) should already
have triggered. Confirm via `SELECT * FROM integration_event_cursors WHERE cursor_name =
'device-history';` before starting; if it's somehow still empty, this scenario isn't verifiable this
run -- note that plainly and move on rather than forcing it.

- [ ] Query `integration_event_cursors` for the `device-history` row's persisted event number (call
      it C).
- [ ] Quit the app. Method: Quit the app (`../Methods.md`).
- [ ] Start the app again and confirm reconnect. Method: Launch the app for a Claude-driven step,
      Confirm device reconnect (`../Methods.md`).
- [ ] Query `debug_log` for the startup fetch's `"history fetch triggered: trigger=startup
      known_max=<N>"` line and confirm `known_max` equals C -- it resumed from the persisted
      cursor rather than re-fetching from scratch (which would show `known_max=0`).
