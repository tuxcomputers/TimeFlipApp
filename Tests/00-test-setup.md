# Test Setup

Common one-time setup, run by the supervisor at the very start of **every** test run --
whatever subset is requested, Bench or Interactive -- before any feature checklist. This is the
**only** place the test database is (re)built, so no feature checklist ever re-switches.

It starts by quitting the app, so the state it works from is the disk's rather than whatever the
previous run happened to leave running. Then it checks which database is active. On **production** it records real device history (a
forced startup fetch), then switches to the test database. If the app is **not** on production it
asks whether to switch to production and record its history first (`y`) or skip straight to the
test database (`n`) -- so a run started on the test DB doesn't hard-fail. On `n`, the
history-recording steps read that choice and tick themselves without doing anything, and the run
jumps to the switch-to-test steps.

Whenever it records production history it does so on **fresh, live** data -- it restarts the app,
waits for the device to reconnect and history to sync, then confirms the device is **not mid-timing
a real activity** (Step 8) before the destructive switch/reset. That live re-check is why the
supervisor's early timing gate only fires when the app is already running: with the app down the
on-disk state is stale. Finally it switches to test and leaves the device **unlocked and unpaused**.

Not a feature test: it establishes the known state (`db_type = test`, device connected, unlocked,
unpaused -- plus **≥ 10 device events** when the run includes a history-refresh checklist, 01b/01i)
that every checklist assumes. The supervisor always runs it fresh (its boxes are cleared
first) and aborts the run if any step here fails. The full state machine -- every current state and
its path to here -- is in [`scripts/testrunner/START-STATES.md`](../scripts/testrunner/START-STATES.md).

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Setup

- [x] Step 1: Quit the app if it is running, so setup starts from a known down state.
Whatever the previous run left behind stops mattering here. A halt leaves the app up with whatever window it was driving still open, and the steps that close a checklist's Settings window are the ones a halt never reaches, so the next run would inherit it. That instance is also the previous binary: `run_tests.sh` rebuilds before the supervisor starts, and anything already running predates that build. Nothing is lost by quitting: the pre-flight timing gate has already read the live state by the time this runs (it is the supervisor's first act, before any prompt), and every path through this file starts the app again -- recording production history restarts it at Step 5, and the switch to test relaunches it at Step 9. [Method: Number 3](Methods.md#method-3), which no-ops when nothing is running, and polls until the process is really gone rather than trusting the quit event's acknowledgement.
```toml step
use = "method-3"
```
- [x] Step 2: Check which database is active and decide whether to record production history.
On production, record it. Otherwise ask whether to switch to production and record first, or skip straight to the test DB. On a resume (`resume = y`) skip this decision entirely -- we're continuing on the existing test DB and must not round-trip to production. Sets `record_history` (`y`/`n`) that steps 3--8 read, and `want_switch` (`y` only in the not-on-production + chose-to-switch case).
```toml step
[[actions]]
use = "method-24.a"
setting = "db_type"
capture = "db_at_start"

[[actions]]
action = "sql_query"
when = '$db_at_start == {"type":"production"}'
query = "SELECT 'y';"
capture = "record_history"

# want_prompt gates the production-switch question: only when off production AND this isn't a
# resume. (`when` takes a single comparison, so it's built in two steps: default y off-production,
# then forced n on a resume.)

[[actions]]
action = "sql_query"
when = '$db_at_start != {"type":"production"}'
query = "SELECT 'y';"
capture = "want_prompt"

[[actions]]
action = "sql_query"
when = '$resume == y'
query = "SELECT 'n';"
capture = "want_prompt"

[[actions]]
action = "ask_user"
when = '$want_prompt == y'
prompt = "The app is NOT on the production database. Switch to production and record its device history before testing?\ny = switch to prod, record history, then go to the test DB\nn = skip recording and go straight to the test DB"
capture = "want_switch"

[[actions]]
action = "sql_query"
when = '$want_prompt == y'
query = "SELECT '$want_switch';"
capture = "record_history"
```
- [x] Step 3: Switch to the production database so the history fetch below runs against it.
Only when Step 2 chose to switch (`want_switch = y`); relinks the `appdata.sqlite` symlink at `production.sqlite`. Step 1 has already quit the app, so nothing is holding the old file open and the relink takes effect for the launch at Step 5. (It used to matter that a running app kept reading the pre-relink file until that restart picked the new one up; quitting first removes the window in which that was true.)
```toml step
when = '$want_switch == y'
action = "shell"
command = "scripts/switch-database.sh prod"
```
- [x] Step 4: Capture production's current max `debug_log_id` as the baseline for the forced history fetch below.
Skipped (and ticked) when Step 2 chose not to record history.
```toml step
use = "method-24.b"
when = '$record_history == y'
capture = "prod_before_id"
```
- [x] Step 5: Restart the app so it does a fresh history fetch against production
-- this makes sure all real device history is recorded to production.sqlite before we switch away from it (the end-of-run factory reset later wipes the device's own counter). The quit only fires if the app is actually running, so this also just *starts* it when it was shut down. Skipped when not recording history. Methods: [Number 3](Methods.md#method-3) to quit, [Number 2](Methods.md#method-2) to start.
```toml step
when = '$record_history == y'

[[actions]]
use = "method-3"

[[actions]]
use = "method-2"
```
- [x] Step 6: Confirm the app reconnected to the device against production
(a fresh `Login accepted` after the restart above). If it doesn't reconnect, the device is likely not paired / off / out of range -- the prompt says how to fix it, then this keeps waiting. Skipped when not recording history.
```toml step
use = "method-4"
since_id = "$prod_before_id"
when = '$record_history == y'
expect_contains = "Login accepted"
prompt = "The device hasn't reconnected. Pair it (Device tab -> Scan for Devices -> click the device), or power it on / bring it in range."
timeout_seconds = 120
```
- [x] Step 7: Confirm that forced production history fetch actually completed
so real history is fully synced before the switch. Skipped when not recording history. (Note: matches **any** completed fetch after the restart's login, not `trigger=startup` specifically. The periodic timer starts at app launch and can tick before the startup fetch is reached on a slow connect; the startup call is then folded into the one already in flight and never produces a `trigger=startup` row, so waiting for that name can hang for the full timeout while the sync it is waiting on has already happened under another name. Scoped to the newest `Login accepted` rather than `$prod_before_id`, because that baseline is captured *before* the quit in Step 5 and a periodic fetch completing in the gap would otherwise satisfy this step without the restart's fetch having run at all.)
```toml step
when = '$record_history == y'
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='hist-done' AND debug_log_id > COALESCE((SELECT MAX(debug_log_id) FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Login accepted%'), 0) ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "history fetch complete:"
timeout_seconds = 60
```
- [x] Step 8: On fresh, just-synced data, confirm the device is **not mid-timing a real activity**
before the destructive switch/reset -- the latest event must be a pause (or there are no events yet), never an open timing segment. This gate runs whenever we're recording production history, so it also catches the case where Step 3 just switched onto production. Fails (aborting the run) if the device is timing -- pause it and re-run. Skipped when not recording history.
```toml step
when = '$record_history == y'
action = "sql_query"
query = "SELECT COALESCE((SELECT CASE WHEN paused = 0 THEN 'TIMING' ELSE 'ok' END FROM device_event ORDER BY start_epoch DESC, device_event_id DESC LIMIT 1), 'ok');"
expect = "ok"
```
- [x] Step 9: Switch to the test database
-- quit the app (if running), run `scripts/switch-database.sh test $db_mode`, relaunch. On a fresh run (`db_mode` empty) the script creates a fresh empty `test.sqlite`; on a resume (`db_mode = -keep`) it preserves the existing `test.sqlite` so state earlier scenarios built survives. Either way it repoints the `appdata.sqlite` symlink at the test DB, and the relaunch still happens (so a rebuilt binary is picked up on resume). A fresh `test.sqlite` also gets production's `paired`/`device_uuid`/`device_name` rows copied into it, before the relaunch, so the app connects to the device it is already paired to rather than pairing again from scratch: those rows are per-database, and the device's PIN is no longer the factory default once a pairing has rotated it. Methods: [Number 3](Methods.md#method-3) to quit, [Number 2](Methods.md#method-2) to start.
```toml step
[[actions]]
use = "method-3"

[[actions]]
action = "shell"
command = "scripts/switch-database.sh test $db_mode"

[[actions]]
action = "sql_exec"
query = "DELETE FROM time_entry WHERE device_event_id IN (SELECT device_event_id FROM device_event WHERE event_number IN (900001, 900002, 900003));"

[[actions]]
action = "sql_exec"
query = "DELETE FROM device_event WHERE event_number IN (900001, 900002, 900003);"

[[actions]]
action = "sql_exec"
query = "UPDATE face SET category_id = 0 WHERE category_id IN (SELECT category_id FROM category WHERE category_name IN ('ZZ Assigned', 'ZZ NoFace', 'ZZ Retired'));"

[[actions]]
action = "sql_exec"
query = "DELETE FROM category WHERE category_name IN ('ZZ Assigned', 'ZZ NoFace', 'ZZ Retired');"

[[actions]]
action = "sql_exec"
query = "INSERT INTO category (category_name, active, daily_limit) VALUES ('ZZ Assigned', 1, 0), ('ZZ NoFace', 1, 0), ('ZZ Retired', 1, 0);"

[[actions]]
action = "sql_exec"
query = "UPDATE face SET category_id = (SELECT category_id FROM category WHERE category_name = 'ZZ Assigned') WHERE face_id = 5;"

[[actions]]
action = "sql_exec"
query = "UPDATE category SET active = 0 WHERE category_name = 'ZZ Retired';"

[[actions]]
action = "sql_query"
query = "WITH r AS (SELECT CAST(json_extract(setting_value,'$.hour') AS INT) h, CAST(json_extract(setting_value,'$.minute') AS INT) m FROM setting WHERE setting_name='daily_reset_time'), t AS (SELECT CAST(strftime('%s', date('now','localtime') || ' ' || substr('0'||h,-2) || ':' || substr('0'||m,-2) || ':00', 'utc') AS INT) AS today_reset FROM r) SELECT CASE WHEN CAST(strftime('%s','now') AS INT) >= today_reset THEN today_reset ELSE today_reset - 86400 END FROM t;"
capture = "seed_window_start"

[[actions]]
action = "sql_exec"
query = "INSERT INTO device_event (event_number, event_type_id, device_face, start_time, timezone_id, start_epoch, duration_seconds, paused, finalised, processed) SELECT 900001, 1, 2, strftime('%Y-%m-%dT%H:%M:%S', $seed_window_start - 432000 + 3600, 'unixepoch', 'localtime'), 0, $seed_window_start - 432000 + 3600, 1800.0, 0, 1, 1;"

[[actions]]
action = "sql_exec"
query = "INSERT INTO device_event (event_number, event_type_id, device_face, start_time, timezone_id, start_epoch, duration_seconds, paused, finalised, processed) SELECT 900002, 1, 2, strftime('%Y-%m-%dT%H:%M:%S', $seed_window_start - 345600 + 3600, 'unixepoch', 'localtime'), 0, $seed_window_start - 345600 + 3600, 2700.0, 0, 1, 1;"

[[actions]]
action = "sql_exec"
query = "INSERT INTO device_event (event_number, event_type_id, device_face, start_time, timezone_id, start_epoch, duration_seconds, paused, finalised, processed) SELECT 900003, 1, 2, strftime('%Y-%m-%dT%H:%M:%S', $seed_window_start - 259200 + 3600, 'unixepoch', 'localtime'), 0, $seed_window_start - 259200 + 3600, 3600.0, 0, 1, 1;"

[[actions]]
action = "sql_exec"
query = "INSERT INTO time_entry (category_id, device_event_id, started_at, start_timezone_id, ended_at, end_timezone_id, duration_seconds) SELECT (SELECT category_id FROM category WHERE category_name = 'ZZ Assigned'), device_event_id, strftime('%Y-%m-%dT%H:%M:%S', start_epoch, 'unixepoch', 'localtime'), timezone_id, strftime('%Y-%m-%dT%H:%M:%S', start_epoch + duration_seconds, 'unixepoch', 'localtime'), timezone_id, duration_seconds FROM device_event WHERE event_number = 900001;"

[[actions]]
action = "sql_exec"
query = "INSERT INTO time_entry (category_id, device_event_id, started_at, start_timezone_id, ended_at, end_timezone_id, duration_seconds) SELECT (SELECT category_id FROM category WHERE category_name = 'ZZ NoFace'), device_event_id, strftime('%Y-%m-%dT%H:%M:%S', start_epoch, 'unixepoch', 'localtime'), timezone_id, strftime('%Y-%m-%dT%H:%M:%S', start_epoch + duration_seconds, 'unixepoch', 'localtime'), timezone_id, duration_seconds FROM device_event WHERE event_number = 900002;"

[[actions]]
action = "sql_exec"
query = "INSERT INTO time_entry (category_id, device_event_id, started_at, start_timezone_id, ended_at, end_timezone_id, duration_seconds) SELECT (SELECT category_id FROM category WHERE category_name = 'ZZ Retired'), device_event_id, strftime('%Y-%m-%dT%H:%M:%S', start_epoch, 'unixepoch', 'localtime'), timezone_id, strftime('%Y-%m-%dT%H:%M:%S', start_epoch + duration_seconds, 'unixepoch', 'localtime'), timezone_id, duration_seconds FROM device_event WHERE event_number = 900003;"

[[actions]]
use = "method-2"
```
- [x] Step 10: Read whether the app is paired to a device
 -- the `paired` setting, written only when a pairing succeeds or the user forgets the device, so it survives the relaunch above and says nothing about whether the device is currently reachable (that's `connection.connected`). Capture `paired_state` (`1` = paired, `0` = not). Normally `1`, since Step 9 copied production's pairing across. It is `0` only when production was not paired either, or after a cleanup reset left the device never-paired -- then Step 11 pairs the device; the connectivity confirm (Step 12) only matters once paired. The short wait just lets the relaunched app settle before the read.
```toml step
[[actions]]
action = "shell"
command = "sleep 5"

[[actions]]
action = "sql_query"
query = "SELECT COALESCE((SELECT json_extract(setting_value, '$.paired') FROM setting WHERE setting_name='paired'), 0);"
capture = "paired_state"
```
- [x] Step 11: Pair the device by script
 -- only when it isn't paired (`paired_state != 1`; e.g. a prior run's cleanup reset left it never-paired). Open the Device tab, click **Scan for Devices**, coordinate-click the discovered row ([Method: Number 9](Methods.md#method-9) / `cgevent_click_element`), and wait for the pairing-complete marker (`"Device password confirmed set to:"`, `> current_log_id`). Skipped (and ticked) when already paired. If the automated click doesn't land, the prompt asks you to click the row yourself. Closes the Settings window afterwards ([Method: Number 23](Methods.md#method-23)) so setup leaves no stray window open.
```toml step
when = '$paired_state != 1'

[[actions]]
use = "method-6"
item = "Settings..."

[[actions]]
use = "method-10"
tab = "Device"

[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        click button 1 of group 3 of scroll area 1 of group 1 of window "TimeFlip Settings"
    end tell
end tell'''

[[actions]]
action = "cgevent_click_element"
element = 'first static text of group 3 of scroll area 1 of group 1 of window "TimeFlip Settings" whose name contains "TimeFlip"'

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Device password confirmed set to:%' AND debug_log_id > $current_log_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Device password confirmed set to:"
prompt = "Pairing the device automatically -- if it doesn't complete within a few seconds, click its row in the discovered list yourself."
timeout_seconds = 60

[[actions]]
use = "method-23"
```
- [x] Step 12: Confirm the device is connected against the fresh test database
 -- a `Login accepted` (an auto-reconnect if it was already paired, or the pairing login from Step 11). `test.sqlite` starts its own `debug_log_id` sequence, so any login here is post-switch. If it never connects -- paired but off / out of range -- the prompt says how to fix it.
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Login accepted%' ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Login accepted"
prompt = "The device isn't connecting on the test database. It's already paired -- power it on / bring it in range and it will reconnect."
timeout_seconds = 120
```
- [x] Step 13: Leave the device unlocked and unpaused
 so every checklist starts from a clean state -- unlocking first if needed, then resuming if paused (no-op if already clean). Polls over a settle window rather than reading once: the device's lock/pause state can arrive a couple of seconds after the reconnect, and until it does the menu looks clean, so a single read would miss a locked/paused device and leave Step 15's flips dead (a lock freezes face switching).
```toml step
action = "ensure_unlocked_unpaused"
```
- [x] Step 14: Confirm `db_type` now reads **test** before any feature checklist runs.
```toml step
use = "method-24.a"
setting = "db_type"
expect = '{"type":"test"}'
```
- [x] Step 15: Build up device history to **≥ 10 events**
-- but only when this run includes a history-refresh checklist (`needs_history = y`, set by the supervisor from the requested set). Other runs (LED, battery, ...) don't need the history, so they skip this and tick it. Already-≥10 satisfies instantly; otherwise it prompts you to flip and polls with **no timeout** -- take as long as you need, it won't fail the run. Confirmed on the test DB (Step 14 above) so real flips record to `test.sqlite`.
```toml step
when = '$needs_history == y'
action = "wait_for_sql"
query = "SELECT COALESCE((SELECT CASE WHEN event_number >= 10 THEN 'ok' ELSE 'building=' || event_number END FROM device_event ORDER BY device_event_id DESC LIMIT 1), 'building=0');"
expect = "ok"
prompt = "The history-refresh checklist needs at least 10 device events. Flip the device between faces (e.g. Break and Meeting) until this proceeds, then leave it resting on one face."
timeout_seconds = 0
poll_interval = 3
```
- [x] Step 16: Confirm you've **stopped flipping**
 and the device is resting on one face before any checklist runs -- the ≥10 monitor above returns the instant the count hits 10, which can be mid-flip, so `01b`'s "event count unchanged" scenario would otherwise race a still-climbing counter. Only when history was being built (`needs_history = y`).
```toml step
when = '$needs_history == y'
action = "ask_user"
prompt = "Stop flipping and leave the device resting on one face. Is it resting and settled now? (y once it's stopped)"
```
- [x] Step 17: Confirm the report fixture is in place, and behind everything the run records
 -- the three categories and three segments `Bench/11b` measures, seeded back in Step 9. **Seeded there, not here, and the position is the whole point.** These rows are synthetic `device_event`s, and several checklists read *the latest* `device_event` by `device_event_id` -- `01b` Setup asserts it is the open, growing one (`finalised = 0`), and `Method 24.c` hands that row to whoever asks. Seeded at the end of setup they took the highest ids and became that row, failing `01b` with `finalised = 1` (measured 2026-08-08, ids 10-12 against real rows 1-9). Inserted into the freshly-created `test.sqlite` before the app has ever launched, they take ids 1-3 instead and every real row lands after them, so the newest is always a real one. The fixture is three categories in three states -- active on a face, active on no face, and retired -- because a report shows *time*, not *current* categories: it must include one the Faces list and `loadCategories()` both filter out. Durations of 30, 45 and 60 minutes on the days 5, 4 and 3 back make every range `11b` asserts a different figure, and dating them days back keeps them clear of anything the cube records today. No teardown: `test.sqlite` is rebuilt every run. (Note: on a **resume** the database is kept, so Step 9's re-seed re-inserts at whatever ids are free by then -- acceptable, since a resume only re-enters a run whose earlier checklists have already passed.)
```toml step
[[actions]]
action = "sql_query"
query = "SELECT (SELECT CAST(SUM(te.duration_seconds) AS INT) FROM time_entry te JOIN category c ON c.category_id = te.category_id WHERE c.category_name IN ('ZZ Assigned','ZZ NoFace','ZZ Retired')) || '/' || (SELECT active FROM category WHERE category_name='ZZ Retired') || '/' || (SELECT COUNT(*) FROM face WHERE category_id = (SELECT category_id FROM category WHERE category_name='ZZ Assigned'));"
expect = "8100/0/1"

[[actions]]
action = "sql_query"
query = "SELECT CASE WHEN (SELECT event_number FROM device_event ORDER BY device_event_id DESC LIMIT 1) >= 900000 THEN 'a seeded row is the newest device_event -- it would be read as the live segment' ELSE 'ok' END;"
expect = "ok"
```
- [x] Step 18: Retire bug history belonging to another branch, on the checklists this run will cover.
`Tests/CLAUDE.md`'s rule is that a **Bugs found and fixed** entry belongs to the branch that found
it, so arriving on a new branch retires it -- and that a checklist this run does not reach keeps
both its entries and its `Last run` heading exactly as the previous branch left them. This does the
first half; the supervisor does the second, stamping each file's `Last run` as it starts it rather
than here (see `scripts/testrunner/checklist_header.py`).
**Last in Setup on purpose.** It is the one step that destroys recorded evidence, so it runs only
once everything else has passed: a setup that fails at the database switch or the pairing leaves
every checklist's history untouched. `$checklist_files` is the list the supervisor actually
resolved, not a fresh discovery -- `-f`/`-s` and explicit paths all narrow a run, and sweeping wider
than the run would clear history nobody asked to lose.
```toml step
action = "shell"
command = "python3 scripts/testrunner/checklist_header.py sweep --branch \"$branch\" $checklist_files"
```
