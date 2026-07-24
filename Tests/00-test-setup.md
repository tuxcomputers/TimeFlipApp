# Test Setup

Common one-time setup, run by the supervisor at the very start of **every** test run --
whatever subset is requested, Bench or Interactive -- before any feature checklist. This is the
**only** place the test database is (re)built, so no feature checklist ever re-switches.

It first checks which database is active. On **production** it records real device history (a
forced startup fetch), then switches to the test database. If the app is **not** on production it
asks whether to switch to production and record its history first (`y`) or skip straight to the
test database (`n`) -- so a run started on the test DB doesn't hard-fail. On `n`, the
history-recording steps (2--6) read that choice and tick themselves without doing anything, and the
run jumps to the switch-to-test steps.

Not a feature test: it establishes the known state (`db_type = test`, device connected) that
every checklist assumes. The supervisor always runs it fresh (its boxes are cleared first) and
aborts the run if any step here fails.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Setup

- [ ] Step 1: Check which database is active and decide whether to record production history. On production, record it. Otherwise ask whether to switch to production and record first, or skip straight to the test DB. Sets `record_history` (`y`/`n`) that steps 2--6 read, and `want_switch` (`y` only in the not-on-production + chose-to-switch case).
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
- [ ] Step 2: Switch to the production database so the history fetch below runs against it. Only when Step 1 chose to switch (`want_switch = y`); relinks the `appdata.sqlite` symlink at `production.sqlite` (the running app keeps the old file open until the restart in Step 4 picks this up).
```toml step
when = '$want_switch == y'
action = "shell"
command = "scripts/use-production-database.sh"
```
- [ ] Step 3: Capture production's current max `debug_log_id` as the baseline for the forced history fetch below. Skipped (and ticked) when Step 1 chose not to record history.
```toml step
when = '$record_history == y'
action = "sql_query"
query = "SELECT MAX(debug_log_id) FROM debug_log;"
capture = "prod_before_id"
```
- [ ] Step 4: Restart the app so it does a fresh history fetch against production -- this makes sure all real device history is recorded to production.sqlite before we switch away from it (the end-of-run factory reset later wipes the device's own counter). Skipped when not recording history.
```toml step
when = '$record_history == y'

[[actions]]
action = "shell"
command = "osascript -e 'tell application \"TimeFlip\" to quit' ; sleep 2"

[[actions]]
action = "shell"
command = "nohup ./.build/bundler/apps/TimeFlip/TimeFlip.app/Contents/MacOS/TimeFlip > /dev/null 2>&1 &"
```
- [ ] Step 5: Confirm the app reconnected to the device against production (a fresh `Login accepted` after the restart above). Skipped when not recording history.
```toml step
when = '$record_history == y'
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Login accepted%' AND debug_log_id > $prod_before_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Login accepted"
timeout_seconds = 30
```
- [ ] Step 6: Confirm that forced production history fetch actually completed (`history fetch complete: trigger=startup`), so real history is fully synced before the switch. Skipped when not recording history.
```toml step
when = '$record_history == y'
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='hist-done' AND message = 'history fetch complete: trigger=startup' AND debug_log_id > $prod_before_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "history fetch complete: trigger=startup"
timeout_seconds = 60
```
- [ ] Step 7: Switch to the test database -- quit the app, run `scripts/use-test-database.sh` (creates a fresh empty `test.sqlite` and repoints the `appdata.sqlite` symlink at it), relaunch.
```toml step
[[actions]]
action = "shell"
command = "osascript -e 'tell application \"TimeFlip\" to quit' ; sleep 2"

[[actions]]
action = "shell"
command = "scripts/use-test-database.sh"

[[actions]]
action = "shell"
command = "nohup ./.build/bundler/apps/TimeFlip/TimeFlip.app/Contents/MacOS/TimeFlip > /dev/null 2>&1 &"
```
- [ ] Step 8: Confirm the app reconnected against the fresh test database (`Login accepted` -- test.sqlite starts its own `debug_log_id` sequence, so any login row here is post-switch).
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Login accepted%' ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Login accepted"
timeout_seconds = 30
```
- [ ] Step 9: Confirm `db_type` now reads **test** before any feature checklist runs.
```toml step
action = "sql_query"
query = "SELECT setting_value FROM setting WHERE setting_name='db_type';"
expect = '{"type":"test"}'
```
