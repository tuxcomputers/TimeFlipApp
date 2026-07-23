# Test Setup

Common one-time setup, run by the supervisor at the very start of **every** test run --
whatever subset is requested, Bench or Interactive -- before any feature checklist. It
preserves real history against production, then switches to the test database. This is the
**only** place the test database is (re)built, so no feature checklist ever re-switches.

Not a feature test: it establishes the known state (`db_type = test`, device connected) that
every checklist assumes. The supervisor always runs it fresh (its boxes are cleared first) and
aborts the run if any step here fails.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Setup

- [ ] Step 1: Confirm the app is on the **production** database before switching. If this fails, the app is not on production -- quit it and run `scripts/use-production-database.sh`, then re-run.
```toml step
action = "sql_query"
query = "SELECT setting_value FROM setting WHERE setting_name='db_type';"
expect = '{"type":"production"}'
```
- [ ] Step 2: Capture production's current max `debug_log_id` as the baseline for the forced history fetch below.
```toml step
action = "sql_query"
query = "SELECT MAX(debug_log_id) FROM debug_log;"
capture = "prod_before_id"
```
- [ ] Step 3: Restart the app so it does a fresh history fetch against production -- this makes sure all real device history is recorded to production.sqlite before we switch away from it (the end-of-run factory reset later wipes the device's own counter).
```toml step
[[actions]]
action = "shell"
command = "osascript -e 'tell application \"TimeFlip\" to quit' ; sleep 2"

[[actions]]
action = "shell"
command = "nohup ./.build/bundler/apps/TimeFlip/TimeFlip.app/Contents/MacOS/TimeFlip > /dev/null 2>&1 &"
```
- [ ] Step 4: Confirm the app reconnected to the device against production (a fresh `Login accepted` after the restart above).
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Login accepted%' AND debug_log_id > $prod_before_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Login accepted"
timeout_seconds = 30
```
- [ ] Step 5: Confirm that forced production history fetch actually completed (`history fetch complete: trigger=startup`), so real history is fully synced before the switch.
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='hist-done' AND message = 'history fetch complete: trigger=startup' AND debug_log_id > $prod_before_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "history fetch complete: trigger=startup"
timeout_seconds = 60
```
- [ ] Step 6: Switch to the test database -- quit the app, run `scripts/use-test-database.sh` (creates a fresh empty `test.sqlite` and repoints the `appdata.sqlite` symlink at it), relaunch.
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
- [ ] Step 7: Confirm the app reconnected against the fresh test database (`Login accepted` -- test.sqlite starts its own `debug_log_id` sequence, so any login row here is post-switch).
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Login accepted%' ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Login accepted"
timeout_seconds = 30
```
- [ ] Step 8: Confirm `db_type` now reads **test** before any feature checklist runs.
```toml step
action = "sql_query"
query = "SELECT setting_value FROM setting WHERE setting_name='db_type';"
expect = '{"type":"test"}'
```
