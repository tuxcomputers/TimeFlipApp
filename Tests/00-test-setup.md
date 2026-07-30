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

- [ ] Step 1: Check which database is active and decide whether to record production history.
On production, record it. Otherwise ask whether to switch to production and record first, or skip straight to the test DB. On a resume (`resume = y`) skip this decision entirely -- we're continuing on the existing test DB and must not round-trip to production. Sets `record_history` (`y`/`n`) that steps 2--7 read, and `want_switch` (`y` only in the not-on-production + chose-to-switch case).
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
- [ ] Step 2: Switch to the production database so the history fetch below runs against it.
Only when Step 1 chose to switch (`want_switch = y`); relinks the `appdata.sqlite` symlink at `production.sqlite` (the running app keeps the old file open until the restart in Step 4 picks this up).
```toml step
when = '$want_switch == y'
action = "shell"
command = "scripts/use-production-database.sh"
```
- [ ] Step 3: Capture production's current max `debug_log_id` as the baseline for the forced history fetch below.
Skipped (and ticked) when Step 1 chose not to record history.
```toml step
use = "method-24.b"
when = '$record_history == y'
capture = "prod_before_id"
```
- [ ] Step 4: Restart the app so it does a fresh history fetch against production
-- this makes sure all real device history is recorded to production.sqlite before we switch away from it (the end-of-run factory reset later wipes the device's own counter). The quit only fires if the app is actually running, so this also just *starts* it when it was shut down. Skipped when not recording history. Methods: [Number 3](Methods.md#method-3) to quit, [Number 2](Methods.md#method-2) to start.
```toml step
when = '$record_history == y'

[[actions]]
use = "method-3"

[[actions]]
use = "method-2"
```
- [ ] Step 5: Confirm the app reconnected to the device against production
(a fresh `Login accepted` after the restart above). If it doesn't reconnect, the device is likely not paired / off / out of range -- the prompt says how to fix it, then this keeps waiting. Skipped when not recording history.
```toml step
use = "method-4"
since_id = "$prod_before_id"
when = '$record_history == y'
expect_contains = "Login accepted"
prompt = "The device hasn't reconnected. Pair it (Device tab -> Scan for Devices -> click the device), or power it on / bring it in range."
timeout_seconds = 120
```
- [ ] Step 6: Confirm that forced production history fetch actually completed
(`history fetch complete: trigger=startup`), so real history is fully synced before the switch. Skipped when not recording history.
```toml step
when = '$record_history == y'
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='hist-done' AND message = 'history fetch complete: trigger=startup' AND debug_log_id > $prod_before_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "history fetch complete: trigger=startup"
timeout_seconds = 60
```
- [ ] Step 7: On fresh, just-synced data, confirm the device is **not mid-timing a real activity**
before the destructive switch/reset -- the latest event must be a pause (or there are no events yet), never an open timing segment. This gate runs whenever we're recording production history, so it also catches the case where Step 2 just switched onto production. Fails (aborting the run) if the device is timing -- pause it and re-run. Skipped when not recording history.
```toml step
when = '$record_history == y'
action = "sql_query"
query = "SELECT COALESCE((SELECT CASE WHEN paused = 0 THEN 'TIMING' ELSE 'ok' END FROM device_event ORDER BY start_epoch DESC, device_event_id DESC LIMIT 1), 'ok');"
expect = "ok"
```
- [ ] Step 8: Switch to the test database
-- quit the app (if running), run `scripts/use-test-database.sh $db_mode`, relaunch. On a fresh run (`db_mode = fresh`) the script creates a fresh empty `test.sqlite`; on a resume (`db_mode = keep`) it preserves the existing `test.sqlite` so state earlier scenarios built survives. Either way it repoints the `appdata.sqlite` symlink at the test DB, and the relaunch still happens (so a rebuilt binary is picked up on resume). A fresh `test.sqlite` also gets production's `paired`/`paired_device` rows copied into it, before the relaunch, so the app connects to the device it is already paired to rather than pairing again from scratch: those rows are per-database, and the device's PIN is no longer the factory default once a pairing has rotated it. Methods: [Number 3](Methods.md#method-3) to quit, [Number 2](Methods.md#method-2) to start.
```toml step
[[actions]]
use = "method-3"

[[actions]]
action = "shell"
command = "scripts/use-test-database.sh $db_mode"

[[actions]]
use = "method-2"
```
- [ ] Step 9: Read whether the app is paired to a device
 -- the `paired` setting, written only when a pairing succeeds or the user forgets the device, so it survives the relaunch above and says nothing about whether the device is currently reachable (that's `connection.connected`). Capture `paired_state` (`1` = paired, `0` = not). Normally `1`, since Step 8 copied production's pairing across. It is `0` only when production was not paired either, or after a cleanup reset left the device never-paired -- then Step 10 pairs the device; the connectivity confirm (Step 11) only matters once paired. The short wait just lets the relaunched app settle before the read.
```toml step
[[actions]]
action = "shell"
command = "sleep 5"

[[actions]]
action = "sql_query"
query = "SELECT COALESCE((SELECT json_extract(setting_value, '$.paired') FROM setting WHERE setting_name='paired'), 0);"
capture = "paired_state"
```
- [ ] Step 10: Pair the device by script
 -- only when it isn't paired (`paired_state != 1`; e.g. a prior run's cleanup reset left it never-paired). Open the Device tab, click **Scan for Devices**, coordinate-click the discovered row ([Method: Number 9](Methods.md#method-9) / `cgevent_click_element`), and wait for the pairing-complete marker (`"Device password confirmed set to:"`, `> current_log_id`). Skipped (and ticked) when already paired. If the automated click doesn't land, the prompt asks you to click the row yourself. Closes the Settings window afterwards ([Method: Number 23](Methods.md#method-23)) so setup leaves no stray window open.
```toml step
when = '$paired_state != 1'

[[actions]]
use = "method-6"
item = "Settings..."

[[actions]]
use = "method-10"
tab = 1

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
- [ ] Step 11: Confirm the device is connected against the fresh test database
 -- a `Login accepted` (an auto-reconnect if it was already paired, or the pairing login from Step 10). `test.sqlite` starts its own `debug_log_id` sequence, so any login here is post-switch. If it never connects -- paired but off / out of range -- the prompt says how to fix it.
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Login accepted%' ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Login accepted"
prompt = "The device isn't connecting on the test database. It's already paired -- power it on / bring it in range and it will reconnect."
timeout_seconds = 120
```
- [ ] Step 12: Leave the device unlocked and unpaused
 so every checklist starts from a clean state -- unlocking first if needed, then resuming if paused (no-op if already clean). Polls over a settle window rather than reading once: the device's lock/pause state can arrive a couple of seconds after the reconnect, and until it does the menu looks clean, so a single read would miss a locked/paused device and leave Step 14's flips dead (a lock freezes facet switching).
```toml step
action = "ensure_unlocked_unpaused"
```
- [ ] Step 13: Confirm `db_type` now reads **test** before any feature checklist runs.
```toml step
use = "method-24.a"
setting = "db_type"
expect = '{"type":"test"}'
```
- [ ] Step 14: Build up device history to **≥ 10 events**
-- but only when this run includes a history-refresh checklist (`needs_history = y`, set by the supervisor from the requested set). Other runs (LED, battery, ...) don't need the history, so they skip this and tick it. Already-≥10 satisfies instantly; otherwise it prompts you to flip and polls with **no timeout** -- take as long as you need, it won't fail the run. Confirmed on the test DB (Step 13 above) so real flips record to `test.sqlite`.
```toml step
when = '$needs_history == y'
action = "wait_for_sql"
query = "SELECT COALESCE((SELECT CASE WHEN event_number >= 10 THEN 'ok' ELSE 'building=' || event_number END FROM device_event ORDER BY device_event_id DESC LIMIT 1), 'building=0');"
expect = "ok"
prompt = "The history-refresh checklist needs at least 10 device events. Flip the device between faces (e.g. Break and Meeting) until this proceeds, then leave it resting on one face."
timeout_seconds = 0
poll_interval = 3
```
- [ ] Step 15: Confirm you've **stopped flipping**
 and the device is resting on one face before any checklist runs -- the ≥10 monitor above returns the instant the count hits 10, which can be mid-flip, so `01b`'s "event count unchanged" scenario would otherwise race a still-climbing counter. Only when history was being built (`needs_history = y`).
```toml step
when = '$needs_history == y'
action = "ask_user"
prompt = "Stop flipping and leave the device resting on one face. Is it resting and settled now? (y once it's stopped)"
```
