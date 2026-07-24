# Test Setup

Common one-time setup, run by the supervisor at the very start of **every** test run --
whatever subset is requested, Bench or Interactive -- before any feature checklist. This is the
**only** place the test database is (re)built, so no feature checklist ever re-switches.

It first checks which database is active. On **production** it records real device history (a
forced startup fetch), then switches to the test database. If the app is **not** on production it
asks whether to switch to production and record its history first (`y`) or skip straight to the
test database (`n`) -- so a run started on the test DB doesn't hard-fail. On `n`, the
history-recording steps read that choice and tick themselves without doing anything, and the run
jumps to the switch-to-test steps.

Whenever it records production history it does so on **fresh, live** data -- it restarts the app,
waits for the device to reconnect and history to sync, then confirms the device is **not mid-timing
a real activity** (Step 7) before the destructive switch/reset. That live re-check is why the
supervisor's early timing gate only fires when the app is already running: with the app down the
on-disk state is stale. Finally it switches to test and leaves the device **unlocked and unpaused**.

Not a feature test: it establishes the known state (`db_type = test`, device connected, unlocked,
unpaused -- plus **≥ 10 device events** when the run includes a history-refresh checklist, 01b/01i)
that every checklist assumes. The supervisor always runs it fresh (its boxes are cleared
first) and aborts the run if any step here fails. The full state machine -- every current state and
its path to here -- is in [`scripts/testrunner/START-STATES.md`](../scripts/testrunner/START-STATES.md).

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Setup

- [x] Step 1: Check which database is active and decide whether to record production history. On production, record it. Otherwise ask whether to switch to production and record first, or skip straight to the test DB. Sets `record_history` (`y`/`n`) that steps 2--7 read, and `want_switch` (`y` only in the not-on-production + chose-to-switch case).
```toml step
[[actions]]
action = "sql_query"
query = "SELECT setting_value FROM setting WHERE setting_name='db_type';"
capture = "db_at_start"

[[actions]]
action = "sql_query"
when = '$db_at_start == {"type":"production"}'
query = "SELECT 'y';"
capture = "record_history"

[[actions]]
action = "ask_user"
when = '$db_at_start != {"type":"production"}'
prompt = "The app is NOT on the production database. Switch to production and record its device history before testing?\ny = switch to prod, record history, then go to the test DB\nn = skip recording and go straight to the test DB"
capture = "want_switch"

[[actions]]
action = "sql_query"
when = '$db_at_start != {"type":"production"}'
query = "SELECT '$want_switch';"
capture = "record_history"
```
- [x] Step 2: Switch to the production database so the history fetch below runs against it. Only when Step 1 chose to switch (`want_switch = y`); relinks the `appdata.sqlite` symlink at `production.sqlite` (the running app keeps the old file open until the restart in Step 4 picks this up).
```toml step
when = '$want_switch == y'
action = "shell"
command = "scripts/use-production-database.sh"
```
- [x] Step 3: Capture production's current max `debug_log_id` as the baseline for the forced history fetch below. Skipped (and ticked) when Step 1 chose not to record history.
```toml step
when = '$record_history == y'
action = "sql_query"
query = "SELECT MAX(debug_log_id) FROM debug_log;"
capture = "prod_before_id"
```
- [x] Step 4: Restart the app so it does a fresh history fetch against production -- this makes sure all real device history is recorded to production.sqlite before we switch away from it (the end-of-run factory reset later wipes the device's own counter). The quit only fires if the app is actually running, so this also just *starts* it when it was shut down. Skipped when not recording history.
```toml step
when = '$record_history == y'

[[actions]]
action = "shell"
command = "pgrep -f 'TimeFlip.app/Contents/MacOS/TimeFlip' > /dev/null 2>&1 && osascript -e 'tell application \"TimeFlip\" to quit' ; sleep 2"

[[actions]]
action = "shell"
command = "nohup ./.build/bundler/apps/TimeFlip/TimeFlip.app/Contents/MacOS/TimeFlip > /dev/null 2>&1 &"
```
- [x] Step 5: Confirm the app reconnected to the device against production (a fresh `Login accepted` after the restart above). If it doesn't reconnect, the device is likely not paired / off / out of range -- the prompt says how to fix it, then this keeps waiting. Skipped when not recording history.
```toml step
when = '$record_history == y'
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Login accepted%' AND debug_log_id > $prod_before_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Login accepted"
prompt = "The device hasn't reconnected. Pair it (Device tab -> Scan for Devices -> click the device), or power it on / bring it in range."
timeout_seconds = 120
```
- [x] Step 6: Confirm that forced production history fetch actually completed (`history fetch complete: trigger=startup`), so real history is fully synced before the switch. Skipped when not recording history.
```toml step
when = '$record_history == y'
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='hist-done' AND message = 'history fetch complete: trigger=startup' AND debug_log_id > $prod_before_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "history fetch complete: trigger=startup"
timeout_seconds = 60
```
- [x] Step 7: On fresh, just-synced data, confirm the device is **not mid-timing a real activity** before the destructive switch/reset -- the latest event must be a pause (or there are no events yet), never an open timing segment. This gate runs whenever we're recording production history, so it also catches the case where Step 2 just switched onto production. Fails (aborting the run) if the device is timing -- pause it and re-run. Skipped when not recording history.
```toml step
when = '$record_history == y'
action = "sql_query"
query = "SELECT COALESCE((SELECT CASE WHEN is_paused = 0 THEN 'TIMING' ELSE 'ok' END FROM device_event ORDER BY start_epoch DESC, device_event_id DESC LIMIT 1), 'ok');"
expect = "ok"
```
- [x] Step 8: Switch to the test database -- quit the app (if running), run `scripts/use-test-database.sh` (creates a fresh empty `test.sqlite` and repoints the `appdata.sqlite` symlink at it), relaunch.
```toml step
[[actions]]
action = "shell"
command = "pgrep -f 'TimeFlip.app/Contents/MacOS/TimeFlip' > /dev/null 2>&1 && osascript -e 'tell application \"TimeFlip\" to quit' ; sleep 2"

[[actions]]
action = "shell"
command = "scripts/use-test-database.sh"

[[actions]]
action = "shell"
command = "nohup ./.build/bundler/apps/TimeFlip/TimeFlip.app/Contents/MacOS/TimeFlip > /dev/null 2>&1 &"
```
- [x] Step 9: Confirm the app reconnected against the fresh test database (`Login accepted` -- test.sqlite starts its own `debug_log_id` sequence, so any login row here is post-switch). Same not-paired prompt as Step 5 if it doesn't come back.
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Login accepted%' ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Login accepted"
prompt = "The device hasn't reconnected on the test database. Pair it (Device tab -> Scan for Devices -> click the device), or power it on / bring it in range."
timeout_seconds = 120
```
- [ ] Step 10: Leave the device unlocked and unpaused so every checklist starts from a clean state -- unlocking first if needed, then resuming if paused (no-op if already clean). Polls over a settle window rather than reading once: the device's lock/pause state can arrive a couple of seconds after the reconnect (Step 9), and until it does the menu looks clean, so a single read would miss a locked/paused device and leave Step 12's flips dead (a lock freezes facet switching).
```toml step
action = "ensure_unlocked_unpaused"
```
- [x] Step 11: Confirm `db_type` now reads **test** before any feature checklist runs.
```toml step
action = "sql_query"
query = "SELECT setting_value FROM setting WHERE setting_name='db_type';"
expect = '{"type":"test"}'
```
- [ ] Step 12: Build up device history to **≥ 10 events** -- but only when this run includes a history-refresh checklist (`needs_history = y`, set by the supervisor from the requested set). Other runs (LED, battery, ...) don't need the history, so they skip this and tick it. Already-≥10 satisfies instantly; otherwise it prompts you to flip and waits (up to 4 min). Confirmed on the test DB (Step 11 above) so real flips record to `test.sqlite`.
```toml step
when = '$needs_history == y'
action = "wait_for_sql"
query = "SELECT COALESCE((SELECT CASE WHEN event_number >= 10 THEN 'ok' ELSE 'building=' || event_number END FROM device_event ORDER BY device_event_id DESC LIMIT 1), 'building=0');"
expect = "ok"
prompt = "The history-refresh checklist needs at least 10 device events. Flip the device between faces (e.g. Break and Meeting) until this proceeds, then leave it resting on one face."
timeout_seconds = 240
poll_interval = 3
```
