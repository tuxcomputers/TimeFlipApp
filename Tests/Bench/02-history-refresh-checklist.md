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

- [x] Launch the app with the device already paired and connected (see "Driving the app directly"
      in `../CLAUDE.md`); confirm via a fresh `debug_log` `"Login accepted, code=0x02"` row.
- [x] Query the current state as a baseline:
      `sqlite3 ~/Library/Application\ Support/TimeFlip/appdata.sqlite "SELECT event_number, device_face, duration_seconds, finalised FROM device_events ORDER BY event_number DESC LIMIT 3;"`
      (Run immediately after `01-reset-device-checklist.md` in the same session -- the device has
      just been factory reset and has **zero** events (`device_last_event=nil` on every fetch), no
      currently-open facet to track. The row returned is a stale pre-reset row, not live.)

## Scenario A -- nothing changes (skip path + duration refresh)

**Preconditions:** an already-open, actively-growing `device_events` row (i.e. the device has
real, non-post-reset history and a currently-open facet) -- check this via the Setup baseline
query above before starting; if the most recent row is post-reset with nothing open yet, this
scenario isn't verifiable this run (see below), not a failure.

**Not verifiable this run** -- this scenario needs an already-open, actively-growing event to
confirm "duration keeps increasing while nothing else changes." Post-reset, with no facet flip yet
(that's Interactive 01's job, which runs after the entire Bench phase, not before), there is no
such event. Noted and skipped per the user's call rather than forced or faked; revisit on a normal
(non-just-reset) session, or after Interactive 01 has run once.

## Scenario D -- quit and relaunch resumes from the persisted cursor

**Preconditions:** an existing `device-history` row in `integration_event_cursors` (i.e. at least
one prior successful history fetch to have resumed from) -- check via `SELECT * FROM
integration_event_cursors WHERE cursor_name = 'device-history';` before starting; if it's empty,
this scenario isn't verifiable this run (see below), not a failure.

**Not verifiable this run**, same root cause -- `integration_event_cursors` has no
`device-history`/local row at all yet (nothing to have resumed from), so "confirm it resumes from
the persisted cursor rather than re-fetching everything" has nothing meaningful to check against
post-reset. Noted and skipped; revisit once the device has real history again.
