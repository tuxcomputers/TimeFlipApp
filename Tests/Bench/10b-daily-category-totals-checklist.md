# Daily Category Totals Checklist

### Last run - 2026-08-05 on the branch 'chore/newDesignRefactor'

Covers the menu bar's day figure being a **category** total rather than a face total: the number
drawn beside the activity name, and the `daily_limit` tested against it, both key off
`currentActivity.categoryID` (see `MenuBarController.currentDuration` and `DailyCategoryTotals`).
Two faces assigned the same category therefore add together, which is the whole point -- a
`daily_limit` belongs to a category, so 20 minutes on one face and 40 on another spend an hour of
it, not 40 minutes of it.

Requires a paired physical TimeFlip device and the app running with Developer Mode enabled and the
`debug` setting's `enabled` field `true`, same as every other checklist here.

Three things make this assertable without a hand on the cube, and each is load-bearing:

- **The status item's text is accessibility-readable** ([Method: Number 27](../Methods.md#method-27)),
  so the rendered activity name and duration are read directly rather than screenshotted. Only the
  over-limit *colouring* still needs an eye on it (Scenario B).
- **The device is paused for the duration assertions.** `currentDuration` returns the category total
  alone while paused and adds the running segment's elapsed seconds otherwise, so pausing is what
  turns a drifting figure into an exact one.
- **A category created for this run holds the totals**, so the expected figure is exactly what the
  steps insert. Reusing `Break`/`Meeting` would fold in whatever the earlier checklists recorded
  against them today. `time_entry.category_id` is captured when the entry is created, so real
  segments recorded earlier against those faces keep pointing at the old category and cannot leak in.

The synthetic segments are placed **behind** the newest recorded `device_event`, deliberately: the
resume position is the newest recorded segment (`AppDataStore.latestRecordedEvent()`, see `01b`
Scenario B), so a row inserted ahead of it would move that position and send every later history
fetch back to event 0. Behind it, nothing about history ingest changes.

Scenario C is a real teardown, not a courtesy: it runs before the whole Interactive phase, and
`01i`'s history checks would otherwise inherit two invented events and two reassigned faces.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Setup

**Preconditions:** the test database, the device connected. Both are established by
`Tests/00-test-setup.md`, which the supervisor always runs first. Setup deliberately holds only reads
and captures -- the device/app state each scenario needs is resolved inside that scenario, so a
restart-from-scenario resume, which skips this section, still gets it.

- [x] Step 1: Confirm `db_type` reads **test** before anything writes to it.
```toml step
use = "method-24.a"
setting = "db_type"
expect = '{"type":"test"}'
```
- [x] Step 2: Capture the current day window's start epoch, derived from `daily_reset_time`.
Mirrors `DailyCategoryTotals.computeWindowStart`: today's boundary at that local time, or yesterday's
if now is still before it. (Note: the yesterday branch subtracts a flat 86400, which is exact only
where the local offset doesn't shift; Brisbane has no DST, and the steps below only ever use the
today branch.)
```toml step
action = "sql_query"
query = "WITH r AS (SELECT CAST(json_extract(setting_value,'$.hour') AS INT) h, CAST(json_extract(setting_value,'$.minute') AS INT) m FROM setting WHERE setting_name='daily_reset_time'), t AS (SELECT CAST(strftime('%s', date('now','localtime') || ' ' || substr('0'||h,-2) || ':' || substr('0'||m,-2) || ':00', 'utc') AS INT) AS today_reset FROM r) SELECT CASE WHEN CAST(strftime('%s','now') AS INT) >= today_reset THEN today_reset ELSE today_reset - 86400 END FROM t;"
capture = "window_start"
```
- [x] Step 3: Capture the newest recorded `device_event`'s `start_epoch` as the anchor
the synthetic segments sit behind, and confirm at least 90 minutes of today's window sits before it
-- otherwise there is nowhere inside the window to put them and this checklist can't run yet (a run
started within 90 minutes of the daily reset, or one whose newest event predates today).
```toml step
[[actions]]
action = "sql_query"
query = "SELECT start_epoch FROM device_event ORDER BY start_epoch DESC, device_event_id DESC LIMIT 1;"
capture = "anchor_epoch"

[[actions]]
action = "sql_query"
query = "SELECT CASE WHEN $anchor_epoch - 5400 >= $window_start THEN 'ok' ELSE 'anchor ' || $anchor_epoch || ' leaves no room after window start ' || $window_start END;"
expect = "ok"
```

## Scenario A -- two faces sharing one category add together

**Preconditions:** the test database with the device paired, `window_start`/`anchor_epoch` captured
by Setup, and -- resolved by Step 1 below rather than assumed -- the device **paused** and the app
**not running**.

- [x] Step 1: Resolve this scenario's own device and app state: unlocked, then paused, then the app quit.
Deliberately not inherited from Setup. A restart-from-scenario resume re-enters here with Setup ticked
and skipped, so anything Setup had established would be missing: the device would still be running,
making Step 8's figure drift instead of exact, and the app would still be up, so Step 6's launch
would start a **second** instance whose login never lands because the first still holds the radio
([Method: Number 2](../Methods.md#method-2) warns about exactly this). Both were measured on
2026-08-05. The menu offering **Resume** is the confirmation the pause took. Methods:
[Number 6](../Methods.md#method-6), [Number 25](../Methods.md#method-25),
[Number 3](../Methods.md#method-3).
```toml step
[[actions]]
action = "ensure_unlocked_unpaused"

[[actions]]
use = "method-6"
item = "Pause"

[[actions]]
use = "method-25"
expect_contains = "Resume"

[[actions]]
use = "method-3"
```
- [x] Step 2: Capture the two stickered faces' current category assignments for Scenario C to restore.
Faces 2 (**Meeting**) and 8 (**Break**) are the only two with stickers on the cube used for these
tests, which is why they are the pair reassigned here.
```toml step
[[actions]]
action = "sql_query"
query = "SELECT category_id FROM face WHERE face_id = 2;"
capture = "face2_category_original"

[[actions]]
action = "sql_query"
query = "SELECT category_id FROM face WHERE face_id = 8;"
capture = "face8_category_original"
```
- [x] Step 3: Create the category these totals accumulate against, and capture its id.
Every leftover of an abandoned run is dropped first, so re-running this scenario is idempotent:
`UN1_category` is unique on name among **active** rows, so a second insert would otherwise fail --
and the synthetic events have to go with it. They are placed relative to the anchor, which moves
between runs, so a stale pair would not collide on `UN1_device_event`; it would simply still sit
inside today's window and silently double the total Step 8 asserts. (Confirmed on 2026-08-05, when a
resumed run would otherwise have measured 2:00:00.)
```toml step
[[actions]]
action = "sql_exec"
query = "DELETE FROM time_entry WHERE device_event_id IN (SELECT device_event_id FROM device_event WHERE event_number IN (900001, 900002));"

[[actions]]
action = "sql_exec"
query = "DELETE FROM device_event WHERE event_number IN (900001, 900002);"

[[actions]]
action = "sql_exec"
query = "DELETE FROM time_entry WHERE category_id IN (SELECT category_id FROM category WHERE category_name = 'ZZ Totals');"

[[actions]]
action = "sql_exec"
query = "UPDATE face SET category_id = 0 WHERE category_id IN (SELECT category_id FROM category WHERE category_name = 'ZZ Totals');"

[[actions]]
action = "sql_exec"
query = "DELETE FROM category WHERE category_name = 'ZZ Totals';"

[[actions]]
action = "sql_exec"
query = "INSERT INTO category (category_name, active, daily_limit) VALUES ('ZZ Totals', 1, 0);"

[[actions]]
action = "sql_query"
query = "SELECT category_id FROM category WHERE category_name = 'ZZ Totals';"
capture = "test_category_id"
```
- [x] Step 4: Point both faces at that one category.
This is the condition under test: one category, two faces.
```toml step
[[actions]]
action = "sql_exec"
query = "UPDATE face SET category_id = $test_category_id WHERE face_id IN (2, 8);"

[[actions]]
action = "sql_query"
query = "SELECT COUNT(*) FROM face WHERE category_id = $test_category_id;"
expect = "2"
```
- [x] Step 5: Insert one closed segment per face, 20 minutes on face 2 and 40 on face 8, with a `time_entry` each.
Both sit inside today's window and behind the anchor. `finalised`/`processed` are set so the
time-entry sweep treats them as already converted and doesn't write a second entry over the top.
```toml step
[[actions]]
action = "sql_exec"
query = "INSERT INTO device_event (event_number, event_type_id, device_face, start_time, timezone_id, start_epoch, duration_seconds, paused, finalised, processed) SELECT 900001, 1, 2, strftime('%Y-%m-%dT%H:%M:%S', $anchor_epoch - 5400, 'unixepoch', 'localtime'), (SELECT timezone_id FROM device_event ORDER BY start_epoch DESC, device_event_id DESC LIMIT 1), $anchor_epoch - 5400, 1200.0, 0, 1, 1;"

[[actions]]
action = "sql_exec"
query = "INSERT INTO device_event (event_number, event_type_id, device_face, start_time, timezone_id, start_epoch, duration_seconds, paused, finalised, processed) SELECT 900002, 1, 8, strftime('%Y-%m-%dT%H:%M:%S', $anchor_epoch - 3600, 'unixepoch', 'localtime'), (SELECT timezone_id FROM device_event ORDER BY start_epoch DESC, device_event_id DESC LIMIT 1), $anchor_epoch - 3600, 2400.0, 0, 1, 1;"

[[actions]]
action = "sql_exec"
query = "INSERT INTO time_entry (category_id, device_event_id, started_at, start_timezone_id, ended_at, end_timezone_id, duration_seconds) SELECT $test_category_id, device_event_id, strftime('%Y-%m-%dT%H:%M:%S', start_epoch, 'unixepoch', 'localtime'), timezone_id, strftime('%Y-%m-%dT%H:%M:%S', start_epoch + duration_seconds, 'unixepoch', 'localtime'), timezone_id, duration_seconds FROM device_event WHERE event_number IN (900001, 900002);"

[[actions]]
action = "sql_query"
query = "SELECT CAST(SUM(duration_seconds) AS INT) FROM time_entry WHERE category_id = $test_category_id;"
expect = "3600"
```
- [x] Step 6: Start the app and confirm it reconnected.
The startup seed (`ApplicationDelegate.seedDailyTotals`) re-derives the totals from `time_entry`. The
quit in front is what [Method: Number 2](../Methods.md#method-2) asks for: it no-ops when nothing is
running, and prevents a second instance when something is. Methods:
[Number 3](../Methods.md#method-3), [Number 2](../Methods.md#method-2),
[Number 4](../Methods.md#method-4).
```toml step
[[actions]]
use = "method-3"

[[actions]]
use = "method-2"

[[actions]]
use = "method-4"
since_id = "$current_log_id"
timeout_seconds = 60
```
- [x] Step 7: Confirm the status item now names the shared category.
The name is resolved from the face's category, so this proves the reassignment reached the app before
the duration is read. [Method: Number 27](../Methods.md#method-27).
```toml step
use = "method-27"
expect_contains = "ZZ Totals"
timeout_seconds = 30
```
- [x] Step 8: Confirm the rendered duration is the **sum of both faces**, `1:00:00`.
This is the assertion the whole checklist exists for. Keyed by face it would read `0:20:00` -- face
2's own 20 minutes, the face the cube is resting on -- and the 40 minutes spent on face 8 would be
invisible to a limit set on the category they share. [Method: Number 27](../Methods.md#method-27).
```toml step
use = "method-27"
expect_contains = "1:00:00"
timeout_seconds = 30
```

## Scenario B -- the daily limit is spent by the category's whole day, not one face's

**Preconditions:** Scenario A complete and left in place -- the shared category holding an hour
across two faces, the device still paused, the app running.

- [x] Step 1: Set the shared category's daily limit to 45 minutes.
Chosen to sit **above** either face's own contribution (20 and 40) and **below** their sum (60), so
the two keyings disagree: per category the limit is spent, per face it is not.
```toml step
[[actions]]
action = "sql_exec"
query = "UPDATE category SET daily_limit = 45 WHERE category_id = $test_category_id;"

[[actions]]
action = "sql_query"
query = "SELECT daily_limit FROM category WHERE category_id = $test_category_id;"
expect = "45"
```
- [x] Step 2: Quit and relaunch so the new limit is loaded, and confirm the reading is unchanged.
The limit rides along on the activity record, so it is picked up when that is reloaded rather than
watched for. The duration must still read `1:00:00` -- the device is paused, so nothing has accrued.
Methods: [Number 3](../Methods.md#method-3), [Number 2](../Methods.md#method-2),
[Number 4](../Methods.md#method-4), [Number 27](../Methods.md#method-27).
```toml step
[[actions]]
use = "method-3"

[[actions]]
use = "method-2"

[[actions]]
use = "method-4"
since_id = "$current_log_id"
timeout_seconds = 60

[[actions]]
use = "method-27"
expect_contains = "1:00:00"
timeout_seconds = 30
```
- [x] Step 3: Confirm the menu bar is drawing the over-limit state.
The only part of this checklist with no readable equivalent: `overLimit` reaches the screen as
colour, not text. Screenshot the menu bar and confirm the activity name and duration are drawn in
the over-limit colour rather than the normal one.
[Method: Number 17](../Methods.md#method-17).

## Scenario C -- teardown, leaving nothing for the Interactive phase to inherit

**Preconditions:** Scenarios A and B complete. Runs even if either failed -- the rows and
reassignments it removes are what would otherwise corrupt `01i`.

- [x] Step 1: Quit the app before unpicking the rows underneath it.
[Method: Number 3](../Methods.md#method-3).
```toml step
use = "method-3"
```
- [x] Step 2: Delete the synthetic entries and events, restore both faces, and drop the test category.
Ordered entry-then-event-then-category so no foreign key is ever left dangling.
```toml step
[[actions]]
action = "sql_exec"
query = "DELETE FROM time_entry WHERE device_event_id IN (SELECT device_event_id FROM device_event WHERE event_number IN (900001, 900002));"

[[actions]]
action = "sql_exec"
query = "DELETE FROM device_event WHERE event_number IN (900001, 900002);"

[[actions]]
action = "sql_exec"
query = "UPDATE face SET category_id = $face2_category_original WHERE face_id = 2;"

[[actions]]
action = "sql_exec"
query = "UPDATE face SET category_id = $face8_category_original WHERE face_id = 8;"

[[actions]]
action = "sql_exec"
query = "DELETE FROM category WHERE category_name = 'ZZ Totals';"
```
- [x] Step 3: Confirm nothing synthetic survives and the resume position is a real event again.
`01i` resumes history from the newest recorded segment, so this is the check that the Interactive
phase starts from the device's own record rather than an invented one.
```toml step
[[actions]]
action = "sql_query"
query = "SELECT COUNT(*) FROM device_event WHERE event_number IN (900001, 900002);"
expect = "0"

[[actions]]
action = "sql_query"
query = "SELECT COUNT(*) FROM category WHERE category_name = 'ZZ Totals';"
expect = "0"

[[actions]]
action = "sql_query"
query = "SELECT CASE WHEN (SELECT start_epoch FROM device_event ORDER BY start_epoch DESC, device_event_id DESC LIMIT 1) >= $anchor_epoch THEN 'ok' ELSE 'resume position moved behind the anchor' END;"
expect = "ok"
```
- [x] Step 4: Restart the app and leave the device unlocked and unpaused.
Undoes Scenario A Step 1's pause, so the Interactive phase starts from the same clean state every
other checklist assumes. Methods: [Number 3](../Methods.md#method-3),
[Number 2](../Methods.md#method-2), [Number 4](../Methods.md#method-4).
```toml step
[[actions]]
use = "method-3"

[[actions]]
use = "method-2"

[[actions]]
use = "method-4"
since_id = "$current_log_id"
timeout_seconds = 60

[[actions]]
action = "ensure_unlocked_unpaused"
```
