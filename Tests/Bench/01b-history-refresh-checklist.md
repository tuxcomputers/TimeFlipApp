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
`test.sqlite`, confirm reconnect and `db_type=test`) is done once by `Tests/00-test-setup.md`,
which the supervisor always runs first -- it's not repeated here. These steps only check the
extra precondition Scenario A/B need: that the fresh test DB pulled in enough real device
history to observe.

- [ ] Step 1: Take the device off lock/pause, then make sure Scenario A/B have enough real history (latest `event_number` >= 10). If there are already 10 events this passes straight away; if not, it prints an "ACTION NEEDED: start flipping" prompt and triggers the moment your flips push the count to 10 (a device sitting still won't accumulate events on its own). Polls up to 4 minutes.
```toml step
[[actions]]
action = "ensure_unlocked_unpaused"

[[actions]]
action = "wait_for_sql"
query = "SELECT CASE WHEN event_number >= 10 THEN 'ok' ELSE 'keep_flipping=' || event_number END FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
expect = "ok"
prompt = "Start flipping the device between the Break and Meeting faces until at least 10 events have accumulated."
timeout_seconds = 240
poll_interval = 3
```
- [ ] Step 2: **Stop moving the device** and leave it resting on one face, so the scenarios below run against a stable, actively-open segment. Confirm you've stopped.
```toml step
action = "ask_user"
prompt = "Stop moving the device and leave it on one face. Have you stopped? (y once it's resting)"
```
- [ ] Step 3: Confirm the latest `device_event` row is open/growing (`finalised=0`) -- the actively-open row Scenario A's skip-path check relies on.
```toml step
action = "sql_query"
query = "SELECT finalised FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
expect = "0"
```

## Scenario A -- nothing changes (skip path + duration refresh)

**Preconditions:** an already-open, actively-growing `device_event` row -- established by Setup
immediately above, which this scenario runs straight on from.

- [ ] Step 1: Note the currently-open `device_event` row's `event_number` and `duration_seconds` (call the
      latter D0). (event_number=13, D0=4878.0.)
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
- [ ] Step 2: Wait for at least one periodic refresh interval (`SELECT setting_value FROM setting WHERE
      setting_name = 'fetch_history_interval_seconds';`) without touching the device. (Interval is
      10s; waited 12s.)
```toml step
[[actions]]
action = "sql_query"
query = "SELECT setting_value FROM setting WHERE setting_name = 'fetch_history_interval_seconds';"
capture = "refresh_interval"

[[actions]]
action = "shell"
command = "sleep 15"
```
- [ ] Step 3: Query `debug_log` and confirm a `history` row logged `"history fetch: device
      max_event_number=<event_number> unchanged; DB refreshed"` -- the cheap-check skip path was
      taken, not a full stream fetch. (Confirmed: `"history fetch: device max_event_number=13
      unchanged; DB refreshed"`.)
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='history' ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "history fetch: device max_event_number=$event_number_d0 unchanged; DB refreshed"
timeout_seconds = 15
```
- [ ] Step 4: Re-query the same `device_event` row: confirm `event_number` is unchanged but
      `duration_seconds` increased beyond D0 -- the skip path still refreshes the open row's
      duration. (Confirmed: event_number still 13, duration_seconds 4878.0 -> 4898.0.)
```toml step
[[actions]]
action = "sql_query"
query = "SELECT event_number FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
expect = "$event_number_d0"

[[actions]]
action = "wait_for_sql"
query = "SELECT CASE WHEN duration_seconds > $duration_d0 THEN 'increased' ELSE duration_seconds END FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
expect = "increased"
timeout_seconds = 15
poll_interval = 3
```

## Scenario B -- quit and relaunch resumes from the persisted cursor

**Preconditions:** an existing `identifier='device-history'` row in `integration_event_cursors` --
`HistoryIngestor.persistDeviceCursor()` writes this once a committed event number is non-nil, which
Setup's own backfill above (multiple real, already-closed historical events) should already have
triggered. Confirm via `SELECT * FROM integration_event_cursors WHERE target = 'local' AND
identifier = 'device-history';` before starting (the row's actual columns are `target`/`identifier`/
`last_success_ev`, not `cursor_name`/a `lastCommittedEventNumber` field -- corrected here); if it's
somehow still empty, this scenario isn't verifiable this run -- note that plainly and move on rather
than forcing it.

- [ ] Step 1: Query `integration_event_cursors` for the `device-history` row's persisted event number (call
      it C). (Confirmed: row `local|device-history|last_sent_ev=12|attempts=0|last_success_ev=12`;
      C=12.)
```toml step
action = "sql_query"
query = "SELECT last_success_ev FROM integration_event_cursors WHERE target='local' AND identifier='device-history';"
capture = "cursor_c"
```
- [ ] Step 2: Quit the app. Method: Quit the app (`../Methods.md`). (Confirmed: no `TimeFlip.app` process
      remained.)
```toml step
[[actions]]
action = "sql_query"
query = "SELECT MAX(debug_log_id) FROM debug_log;"
capture = "before_quit_id"

[[actions]]
action = "shell"
command = "osascript -e 'tell application \"TimeFlip\" to quit'"
```
- [ ] Step 3: Start the app again and confirm reconnect. Method: Launch the app for a Claude-driven step,
      Confirm device reconnect (`../Methods.md`). (Confirmed: fresh `"Login accepted, code=0x02"`
      row.)
```toml step
[[actions]]
action = "shell"
command = "nohup ./.build/bundler/apps/TimeFlip/TimeFlip.app/Contents/MacOS/TimeFlip > /dev/null 2>&1 &"

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Login accepted%' AND debug_log_id > $before_quit_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Login accepted"
timeout_seconds = 30
```
- [ ] Step 4: Query `debug_log` for the startup fetch's `"history fetch triggered: trigger=startup
      known_max=<N>"` line and confirm `known_max` equals C -- it resumed from the persisted
      cursor rather than re-fetching from scratch (which would show `known_max=0`). (Confirmed:
      `"history fetch triggered: trigger=startup known_max=12"` -- equals C.)
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='history' AND message LIKE 'history fetch triggered: trigger=startup%' AND debug_log_id > $before_quit_id ORDER BY debug_log_id ASC LIMIT 1;"
expect_contains = "history fetch triggered: trigger=startup known_max=$cursor_c"
timeout_seconds = 15
```
