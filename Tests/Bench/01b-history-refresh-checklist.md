# History Refresh Checklist

### Last run - 2026-07-21 on the branch 'feature/projects'

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

The switch to the test database (quit, `use-test-database.sh`, relaunch against a fresh
`test.sqlite`, confirm reconnect and `db_type=test`), leaving the device unlocked/unpaused, and
building up **≥ 10 device events** (Scenario A/B need enough real history to observe) are all done
by `Tests/00-test-setup.md`, which the supervisor always runs first -- and the event build runs
there precisely because this history-refresh checklist is in the run. This step only checks the one
extra thing Scenario A relies on.

- [ ] Step 1: Confirm the latest `device_event` row is open/growing.
      (`finalised=0`) -- the actively-open row Scenario A's skip-path check relies on (the device
      is left resting on one face by the setup's flip step).
```toml step
action = "sql_query"
query = "SELECT finalised FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
expect = "0"
```

## Scenario A -- nothing changes (skip path + duration refresh)

**Preconditions:** an already-open, actively-growing `device_event` row -- established by Setup
immediately above, which this scenario runs straight on from.

- [ ] Step 1: Note the currently-open `device_event` row's `event_number` and `duration_seconds`.
```toml step
[[actions]]
action = "sql_query"
query = "SELECT event_number FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
capture = "event_number_d0"

[[actions]]
action = "sql_query"
query = "SELECT duration_seconds FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
capture = "duration_d0"
```
- [ ] Step 2: Wait for at least one periodic refresh interval.
      (`SELECT setting_value FROM setting WHERE setting_name = 'fetch_history_interval_seconds';`)
      without touching the device.
```toml step
[[actions]]
action = "sql_query"
query = "SELECT setting_value FROM setting WHERE setting_name = 'fetch_history_interval_seconds';"
capture = "refresh_interval"

[[actions]]
action = "shell"
command = "sleep 15"
```
- [ ] Step 3: Query `debug_log` and confirm a `history` row logged
`"history fetch: device  max_event_number=<event_number> unchanged; DB refreshed"`  the cheap-check skip path was taken, not a full stream fetch.
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='hist-result' ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "history fetch: device max_event_number=$event_number_d0 unchanged; DB refreshed"
timeout_seconds = 30
```
- [ ] Step 4: Re-query the same `device_event` row.
      Confirm `event_number` is unchanged but `duration_seconds` increased -- the skip path still
      refreshes the open row's duration.
```toml step
[[actions]]
action = "sql_query"
query = "SELECT event_number FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
expect = "$event_number_d0"

[[actions]]
action = "wait_for_sql"
query = "SELECT CASE WHEN duration_seconds > $duration_d0 THEN 'increased' ELSE duration_seconds END FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
expect = "increased"
timeout_seconds = 30
```

## Scenario B -- quit and relaunch resumes from the position derived from `device_event`

**Preconditions:** at least one `device_event` row for the device's current counter generation --
Setup's own backfill above (multiple real historical events) should already have produced plenty.
There is no cursor table: the resume position is derived from `device_event` on each startup, so
nothing separate has to have been written first. If `device_event` is somehow empty, this scenario
isn't verifiable this run -- note that plainly and move on rather than forcing it.

(Note: event numbers repeat across factory resets, so the position is **not** a plain
`MAX(event_number)` over the whole table. The query below first finds the current generation --
the rows after the last point where the counter went *backwards* -- and takes the maximum within
it. On a database spanning resets the two answers differ.)

- [ ] Step 1: Query `device_event` for the current generation's highest `event_number`.
That is the value the app derives its resume position from.
```toml step
action = "sql_query"
query = "WITH ordered AS (SELECT device_event_id, event_number, LAG(event_number) OVER (ORDER BY start_epoch, device_event_id) AS prev FROM device_event) SELECT MAX(event_number) FROM ordered WHERE device_event_id >= COALESCE((SELECT MAX(device_event_id) FROM ordered WHERE prev IS NOT NULL AND event_number < prev), 0);"
capture = "cursor_c"
```
- [ ] Step 2: Quit the app.
[Method: Number 3](../Methods.md#method-3).
```toml step
[[actions]]
use = "method-24.b"
capture = "before_quit_id"

[[actions]]
use = "method-3"
```
- [ ] Step 3: Start the app again and confirm reconnect.
      Methods: [Number 2](../Methods.md#method-2), [Number 4](../Methods.md#method-4).
```toml step
[[actions]]
use = "method-2"

[[actions]]
use = "method-4"
since_id = "$before_quit_id"
```
- [ ] Step 4: Query `debug_log` for the relaunched app's first history fetch
and confirm it resumed from the position derived from `device_event` (`known_max=<N>`) rather than re-fetching from scratch, which would show `known_max=0`. (Note: matches the first `hist-check` after the restart, deliberately **not** a `trigger=startup` line. The periodic timer starts at launch and ticks every 10s on the test database, so on a slow connect it fires before the startup fetch is reached; the startup call is then coalesced into the one already running and the work is logged under `trigger=periodic`. The resume position is what this step is actually about, and it is the same either way -- confirmed live 2026-07-31, where a 6.4s link plus twelve face-colour writes let the timer win.)
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='hist-check' AND debug_log_id > $before_quit_id ORDER BY debug_log_id ASC LIMIT 1;"
expect_contains = "known_max=$cursor_c"
timeout_seconds = 30
```
