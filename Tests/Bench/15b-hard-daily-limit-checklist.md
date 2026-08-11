# Hard Daily Limit Checklist

### Last run - 2026-08-11 21:16 on the branch 'feature/dailyLimit'

Covers `category.daily_limit` as a **hard** limit: reaching it pauses the cube (`0x06 0x01`), and
the app then refuses to send the unpause while that category is the one on show. See
`DailyLimitEnforcement` for every rule and `docs/operation-spec.md` § 7 for the behaviour as a whole.
The physical half -- a double tap, and flipping between faces -- is `15i`.

Requires a paired physical TimeFlip device and the app running with Developer Mode enabled and the
`debug` setting's `enabled` field `true`, same as every other checklist here.

Four things make the bench half assertable without a hand on the cube, and each is load-bearing:

- **The face the cube happens to be resting on is pointed at a category made for this run**, so the
  limit under test is spent by time this checklist inserted and nothing else. Reusing `Break` or
  `Meeting` would fold in whatever the earlier checklists recorded against them today, and the figure
  the crossing depends on would be different on every run.
- **The seeded total sits 20 seconds short of the limit**, so the crossing happens while the run is
  watching rather than at some point in the next hour. 5 minutes of limit against 4:40 of recorded
  time is the whole trick.
- **The cube is paused across the seeding, and resumed once**, which is what makes those 20 seconds
  a known quantity: a resume starts a fresh interval at zero, where the interval already running
  would have been however old the cube's current rest happened to be.
- **The refusal is exercised through the status item's right half, not the menu item.** The item is
  disabled, so clicking it proves nothing; the click gesture goes straight to
  `MenuBarController.togglePause` and so tests the refusal itself rather than the greyed label in
  front of it ([Method: Number 8](../Methods.md#method-8)).

The synthetic segment is placed **behind** the newest recorded `device_event`, for the reason `10b`
gives: the resume position is the newest recorded segment, so a row inserted ahead of it would send
every later history fetch back to event 0.

`900201` is this checklist's own event number, clear of `00-test-setup.md`'s `900001`-`900003` and
`10b`'s `900101`-`900102`, since each of those files deletes by event number and would otherwise take
this fixture with it.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Setup

**Preconditions:** the test database, the device connected. Both are established by
`Tests/00-test-setup.md`, which the supervisor always runs first. Setup holds only reads and
captures, so a restart-from-scenario resume, which skips this section, loses nothing it established.

- [x] Step 1: Confirm `db_type` reads **test** before anything writes to it.
```toml step
use = "method-24.a"
setting = "db_type"
expect = '{"type":"test"}'
```
- [x] Step 2: Confirm the menu bar is showing seconds.
Every duration this checklist asserts is `H:MM:SS`, and with the preference off the same reading
renders `H:MM` and the assertions fail on a formatting difference rather than a real one. It is the
seeded default ([Method: Number 18](../Methods.md#method-18) asks for it to stay on during testing),
so this checks rather than sets it.
```toml step
use = "method-24.f"
setting = "display_seconds"
field = "enabled"
expect = "1"
```
- [x] Step 3: Confirm `pause_on_lock` is enabled.
Checked, not set, and a real dependency rather than a formality: with it on, every quit in this file
locks the cube on its way out, so each of the three scenarios that restarts the app knows it comes back
to a **locked** cube and unlocks it by name. Were it off, those `Unlock` clicks would error `-1728`
against an item that is not there. On is the seeded default.
```toml step
use = "method-24.f"
setting = "pause_on_lock"
field = "enabled"
expect = "1"
```
- [x] Step 4: Capture the current day window's start epoch, derived from `daily_reset_time`.
Mirrors `DailyCategoryTotals.computeWindowStart`: today's boundary at that local time, or yesterday's
if now is still before it. (Note: the yesterday branch subtracts a flat 86400, which is exact only
where the local offset doesn't shift; Brisbane has no DST, and the steps below only ever use the
today branch.)
```toml step
action = "sql_query"
query = "WITH r AS (SELECT CAST(json_extract(setting_value,'$.hour') AS INT) h, CAST(json_extract(setting_value,'$.minute') AS INT) m FROM setting WHERE setting_name='daily_reset_time'), t AS (SELECT CAST(strftime('%s', date('now','localtime') || ' ' || substr('0'||h,-2) || ':' || substr('0'||m,-2) || ':00', 'utc') AS INT) AS today_reset FROM r) SELECT CASE WHEN CAST(strftime('%s','now') AS INT) >= today_reset THEN today_reset ELSE today_reset - 86400 END FROM t;"
capture = "window_start"
```
- [x] Step 5: Capture the anchor the synthetic segment sits behind, and confirm there is room for it
inside today's window. Ten minutes, against the 4:40 segment placed there -- a run started within ten
minutes of the daily reset has nowhere to put it and cannot measure a limit today.
```toml step
[[actions]]
action = "sql_query"
query = "SELECT start_epoch FROM device_event ORDER BY start_epoch DESC, device_event_id DESC LIMIT 1;"
capture = "anchor_epoch"

[[actions]]
action = "sql_query"
query = "SELECT CASE WHEN $anchor_epoch - 600 >= $window_start THEN 'ok' ELSE 'anchor ' || $anchor_epoch || ' leaves no room after window start ' || $window_start END;"
expect = "ok"
```
- [x] Step 6: Capture the face the cube is resting on and the category it currently holds, for the
teardown to put back. Any face will do here, no sticker needed -- nothing physical happens in this
file -- but it has to be one the app will resolve an activity for, which is the stored range 1-12
(`TimeFlipConstants.isValidStoredFaceID`); an out-of-range face would leave the status item on `Idle`
with no category to spend a limit.
```toml step
[[actions]]
action = "sql_query"
query = "SELECT device_face FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
capture = "resting_face"

[[actions]]
action = "sql_query"
query = "SELECT CASE WHEN $resting_face BETWEEN 1 AND 12 THEN 'ok' ELSE 'resting face ' || $resting_face || ' is outside the stored range' END;"
expect = "ok"

[[actions]]
action = "sql_query"
query = "SELECT CASE WHEN (SELECT COUNT(*) FROM face f JOIN category c ON c.category_id = f.category_id WHERE f.face_id = $resting_face AND c.category_name = 'ZZ Hard Limit') = 0 THEN 'ok' ELSE 'face ' || $resting_face || ' is still pointed at this checklist fixture -- a previous run halted before its teardown. Point it back at its real category before re-running; the value it should hold is in logs/testruns.sqlite as resting_face_category_original.' END;"
expect = "ok"

[[actions]]
action = "sql_query"
query = "SELECT category_id FROM face WHERE face_id = $resting_face;"
capture = "resting_face_category_original"
```
The guard in front of that capture is not decoration. Captured off a face a halted run left pointed at
`ZZ Hard Limit`, the "original" would be the fixture's own id, and Scenario E would faithfully restore
the face to a category it had just deleted -- leaving a dangling assignment that no later checklist
would explain. Reporting it is the only honest option: once the real assignment has been overwritten
it cannot be recovered from this database, only from the previous run's record.

If the guard does fire, this is the repair, with `<face>`/`<original>` read from the previous run
(`sqlite3 logs/testruns.sqlite "SELECT capture_name, value FROM captured_value WHERE checklist LIKE
'15b%' ORDER BY captured_value_id DESC LIMIT 6;"`). Quit the app first: it holds the categories in
memory and will write them back over this.
```sql
UPDATE time_entry SET category_id = <original>
 WHERE category_id IN (SELECT category_id FROM category WHERE category_name = 'ZZ Hard Limit')
   AND device_event_id NOT IN (SELECT device_event_id FROM device_event WHERE event_number = 900201);
DELETE FROM time_entry WHERE device_event_id IN (SELECT device_event_id FROM device_event WHERE event_number = 900201);
DELETE FROM device_event WHERE event_number = 900201;
UPDATE face SET category_id = <original> WHERE face_id = <face>;
DELETE FROM category WHERE category_name = 'ZZ Hard Limit';
```
The first statement is the one worth understanding: a real segment that closed while the face pointed at
the fixture was recorded against the fixture, and deleting the category would take that time with it.
Moving it to the face's own category is where it belonged all along.

## Scenario A -- reaching the limit pauses the cube

**Preconditions:** the test database with the device paired, `window_start`/`anchor_epoch`/
`resting_face` captured by Setup, and -- resolved by Step 1 below rather than assumed -- the device
unlocked and running.

- [x] Step 1: Resolve this scenario's own device state: unlocked and unpaused.
Deliberately not inherited from an earlier checklist. A locked cube would refuse nothing here but
would leave the pause item dead for its own reason, and the cube has to be **running** for Step 2 to
have a segment to close.
```toml step
action = "ensure_unlocked_unpaused"
```
- [x] Step 2: Pause the cube, and wait for the segment it closes to be recorded.
Pausing does two jobs, and the order of them against Step 3 is the whole reason this step exists
separately. It makes the twenty seconds after Step 6's resume the only live time there is: the
interval the cube is running now is however old its current rest happens to be, and a resume replaces
it with one starting at zero. And it flushes that interval into a `time_entry` **while the face still
holds its own category**, which is what keeps it out of the figure the crossing depends on.
The wait is on the recording, not the pause: a `time_entry` takes the category the face is mapped to
at the moment it is written, so a segment still unconverted when Step 3 re-points the face lands on
the fixture category instead.
Two kinds of segment are excluded because they are never converted **at all**, and waiting on one
would wait for ever: a paused segment (`AppDataStore.convertEligibleEvents` is `paused = 0`), and one
shorter than the `blip_time` setting, which is the cube passing over a face rather than resting on it.
The threshold is read from the setting rather than written in, so lowering it cannot leave this
waiting on a row the app has decided to skip.
Methods: [Number 6](../Methods.md#method-6), [Number 25](../Methods.md#method-25).
```toml step
[[actions]]
use = "method-6"
item = "Pause"

[[actions]]
use = "method-25"
expect_contains = "Resume"
timeout_seconds = 30

[[actions]]
action = "wait_for_sql"
query = "SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM device_event de WHERE de.finalised = 1 AND de.paused = 0 AND de.device_face = $resting_face AND de.start_epoch >= $window_start - 86400 AND de.duration_seconds >= (SELECT COALESCE(CAST(json_extract(setting_value, '$.seconds') AS INT), 0) FROM setting WHERE setting_name = 'blip_time') AND NOT EXISTS (SELECT 1 FROM time_entry te WHERE te.device_event_id = de.device_event_id)) THEN 'ok' ELSE 'a finalised running segment on face ' || $resting_face || ' is longer than blip_time and still has no time_entry' END;"
expect = "ok"
timeout_seconds = 90
```
- [x] Step 3: Create the category the limit under test belongs to, and point the resting face at it.
Every leftover of an abandoned run is dropped first, so re-running this scenario is idempotent:
`UN1_category` is unique on name among **active** rows, so a second insert would otherwise fail, and
a stale synthetic segment would still sit inside today's window and quietly add 4:40 to the figure
the crossing depends on. The limit starts at `0` (no limit) so nothing fires until Step 5 sets it.
```toml step
[[actions]]
action = "sql_exec"
query = "DELETE FROM time_entry WHERE device_event_id IN (SELECT device_event_id FROM device_event WHERE event_number = 900201);"

[[actions]]
action = "sql_exec"
query = "DELETE FROM device_event WHERE event_number = 900201;"

[[actions]]
action = "sql_exec"
query = "DELETE FROM time_entry WHERE category_id IN (SELECT category_id FROM category WHERE category_name = 'ZZ Hard Limit');"

[[actions]]
action = "sql_exec"
query = "UPDATE face SET category_id = 0 WHERE category_id IN (SELECT category_id FROM category WHERE category_name = 'ZZ Hard Limit');"

[[actions]]
action = "sql_exec"
query = "DELETE FROM category WHERE category_name = 'ZZ Hard Limit';"

[[actions]]
action = "sql_exec"
query = "INSERT INTO category (category_name, active, daily_limit) VALUES ('ZZ Hard Limit', 1, 0);"

[[actions]]
action = "sql_query"
query = "SELECT category_id FROM category WHERE category_name = 'ZZ Hard Limit';"
capture = "limit_category_id"

[[actions]]
action = "sql_exec"
query = "UPDATE face SET category_id = $limit_category_id WHERE face_id = $resting_face;"
```
- [x] Step 4: Seed 4:40 of recorded time against it -- twenty seconds short of the limit Step 5 sets.
Inside today's window and behind the anchor. `finalised`/`processed` are set so the time-entry sweep
treats the row as already converted rather than writing a second entry over the top.
The closing assertion is exact (`280`, not "at least 280") on purpose: it is the check that the
category really does hold nothing but this seed, which is what makes the crossing land twenty seconds
after the resume rather than at some unknown point. See the bug recorded under Step 5.
```toml step
[[actions]]
action = "sql_exec"
query = "INSERT INTO device_event (event_number, event_type_id, device_face, start_time, timezone_id, start_epoch, duration_seconds, paused, finalised, processed) SELECT 900201, 1, $resting_face, strftime('%Y-%m-%dT%H:%M:%S', $anchor_epoch - 600, 'unixepoch', 'localtime'), (SELECT timezone_id FROM device_event ORDER BY start_epoch DESC, device_event_id DESC LIMIT 1), $anchor_epoch - 600, 280.0, 0, 1, 1;"

[[actions]]
action = "sql_exec"
query = "INSERT INTO time_entry (category_id, device_event_id, started_at, start_timezone_id, ended_at, end_timezone_id, duration_seconds) SELECT $limit_category_id, device_event_id, strftime('%Y-%m-%dT%H:%M:%S', start_epoch, 'unixepoch', 'localtime'), timezone_id, strftime('%Y-%m-%dT%H:%M:%S', start_epoch + duration_seconds, 'unixepoch', 'localtime'), timezone_id, duration_seconds FROM device_event WHERE event_number = 900201;"

[[actions]]
action = "sql_exec"
query = "UPDATE time_entry SET category_id = $resting_face_category_original WHERE category_id = $limit_category_id AND device_event_id NOT IN (SELECT device_event_id FROM device_event WHERE event_number = 900201);"

[[actions]]
action = "sql_query"
query = "SELECT CAST(SUM(duration_seconds) AS INT) FROM time_entry WHERE category_id = $limit_category_id;"
expect = "280"
```
The `UPDATE` in the middle is the belt to Step 2's braces, and it is what makes the figure certain
rather than merely likely. Step 2 waits for the closing segment to be recorded before the face moves,
but a segment converted in the window between that wait and this step would still land on the fixture
category, and the crossing would then come early or have already happened. Moving any such entry onto
the face's own category is not a fudge: that is the category the face held while the time was tracked,
which is what the entry should have said. An entry is **moved** rather than deleted deliberately --
`sweepTimeEntries` deliberately ignores the `processed` flag and would recreate a deleted one, since to
it a finalised event with no entry is a defect to repair.
- [x] Step 5: Set the limit to 5 minutes, restart the app, and confirm it came up on 4:40.
The limit rides along on the activity record, so it is picked up when that is reloaded rather than
watched for -- which is why this is a restart and not just a write. The reading proves both halves of
the setup arrived: the face's new category (the name) and the seeded segment (the figure). Exact
because the cube is paused, per [Method: Number 27](../Methods.md#method-27). Methods:
[Number 3](../Methods.md#method-3), [Number 2](../Methods.md#method-2),
[Number 4](../Methods.md#method-4).
```toml step
[[actions]]
action = "sql_exec"
query = "UPDATE category SET daily_limit = 5 WHERE category_id = $limit_category_id;"

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
expect_contains = "ZZ Hard Limit"
timeout_seconds = 30

[[actions]]
use = "method-27"
expect_contains = "0:04:40"
timeout_seconds = 30
```
### Bugs found and fixed - branch 'feature/dailyLimit'
2026-08-11 - Read 0:05:31 instead of 0:04:40: the fixture pointed the resting face at the new category
while the cube was still running on it, so the segment that closed on the pause was converted against
that category and added 51 real seconds to the seeded 280. Past the 5-minute limit before the run
began, so the crossing this scenario measures could never happen. A direct SQL re-point of a face
skips the sweep `AppDataStore.updateFaceCategory` does for exactly this reason. Fixed by pausing and
waiting for the conversion first (Step 2), so the closing segment keeps the face's own category.
2026-08-11 - Step 6's Resume click did nothing and Step 6 passed anyway, leaving Step 7 to wait two
minutes for a crossing that could not happen. Two independent faults, and the second is what hid the
first. The click landed on a **disabled** item: `pause_on_lock` means the quit in Step 5 locks the cube,
and a locked cube's Pause/Resume is dead, so AppleScript clicked it and nothing fired -- no action, and
no `menu`-tagged row either. Then `method-24.c` reported `paused = 0` from the checklist's **own**
`900201` seed rather than the cube: `device_event_id` is a local autoincrement, so the row inserted in
Step 4 outranks every real one. Fixed by unlocking first and by reading `method-24.k`, which skips the
synthetic rows; the method itself now carries the warning.
2026-08-11 - Scenario C Step 2's `Unlock` click then errored `-1728` on the item not existing, having
run about two seconds after `Login accepted`. A relaunch takes roughly four more seconds to finish
connecting, and until it does the dropdown is a menu built before either the connection or the first
history frame: device items dead, pause item reading `Pause`, no `Unlock` in it. Confirmed by reading
the same menu again a minute later, where it had settled to `Resume=false; Unlock=true` as the scenario
expects, so the app is not at fault -- the step was reading a starting-up app. Fixed by waiting for
`Unlock` to appear before clicking it, in Scenario C and in Scenario D, which restarts the same way.
Scenario A Step 6 was never exposed to it: `ensure_unlocked_unpaused` polls the menu, so it already
waits the window out.
- [x] Step 6: Unlock and resume the cube, and confirm this resume was allowed.
The limit is not spent yet -- 4:40 against 5:00 -- so the app has no reason to refuse, and the same
gesture being refused twenty seconds later is what Scenario B rests on. `paused = 0` on the newest
**real** event is the device's own word for it, rather than the menu's.
Unlocking is not optional and not incidental: `pause_on_lock` is on, so the quit in Step 5 **locked**
the cube on its way out, and a locked cube's Pause/Resume item is dead for the lock's own sake
(`MenuBarDropdownRules.allowsPause`). The resolver is used rather than two clicks because it reads the
menu and clicks only what is actually offered -- `click menu item "Unlock"` errors `-1728` on a cube
that is already unlocked, which a re-run or a hand-repaired state can easily be. Its settle window is
6 seconds against the 20 this scenario then waits, so it is finished well before the crossing it must
not collide with. Methods: [Number 24.k](../Methods.md#method-24).
```toml step
[[actions]]
action = "ensure_unlocked_unpaused"

[[actions]]
use = "method-24.k"
action = "wait_for_sql"
column = "paused"
expect = "0"
timeout_seconds = 60
```
- [x] Step 7: Confirm the app pauses the cube on reaching the limit.
The assertion the checklist exists for. The pause is timed by a one-shot timer on the crossing second
(`MenuBarController.updateDailyLimitTimer`), so roughly twenty seconds after the resume above; the
timeout is far longer than that so a slow BLE round trip cannot fail a working limit.
```toml step
use = "method-24.e"
action = "wait_for_sql"
tag = "daily-limit"
since_id = "$current_log_id"
expect_contains = "Limit reached, pausing device"
timeout_seconds = 120
```
- [x] Step 8: Confirm the cube itself is paused, not just the app's record of it.
`device_event.paused` comes from the history frames the device sends back, so this is the device
reporting its own state rather than the app repeating its intent.
```toml step
use = "method-24.k"
action = "wait_for_sql"
column = "paused"
expect = "1"
timeout_seconds = 60
```
- [x] Step 9: Confirm the recorded total has reached the budget, and note what the menu bar shows.
The accounting behind the pause: the segment the pause closed has become a `time_entry`, so the spent
budget is in the recorded data rather than only in the app's memory -- which is what the hold is
re-armed from on the next launch (Scenario C).
Asserted as **at least** 300 seconds rather than exactly `0:05:00`, deliberately. The crossing timer
fires on the 20th second, but the duration that lands in the row is the device's own figure for the
interval, and the pause takes a BLE round trip to arrive -- so 301 is as correct as 300 and an exact
match would fail on a second of honest latency. The rendered title is captured beside it, for the run
log rather than for a comparison.
```toml step
[[actions]]
action = "wait_for_sql"
query = "SELECT CASE WHEN CAST(COALESCE(SUM(duration_seconds), 0) AS INT) >= 300 THEN 'ok' ELSE 'recorded total is only ' || CAST(COALESCE(SUM(duration_seconds), 0) AS INT) || 's of the 300s budget' END FROM time_entry WHERE category_id = $limit_category_id;"
expect = "ok"
timeout_seconds = 60

[[actions]]
use = "method-27"
capture = "title_at_limit"
```

## Scenario B -- the app refuses to send the unpause

**Preconditions:** Scenario A complete and left in place -- the cube paused by the limit on a
category whose budget is spent, the app running.

- [x] Step 1: Confirm the dropdown's Resume item is dead, **and dead because of the limit**.
The visible half of the refusal, so a click that will do nothing looks like it. This reads the enabled
state rather than the names ([Method: Number 30](../Methods.md#method-30)); the item is still *called*
Resume, since it still names the cube's real state.
The second half of the assertion is what makes the first mean anything. A **locked** cube also has a
dead Pause/Resume, for its own unrelated reason, so `Resume=false` on its own would be satisfied by a
lock and would pass with the limit doing nothing at all. The menu names the lock state in the same
read -- the item reads `Unlock` only while the cube is locked -- so requiring that word to be absent
pins the refusal on the limit. Measured the hard way: an earlier run of this file clicked a Resume that
was dead from the quit-time lock and read nothing into it.
```toml step
[[actions]]
use = "method-30"
capture = "menu_when_spent"
timeout_seconds = 30

[[actions]]
action = "sql_query"
query = "SELECT CASE WHEN '$menu_when_spent' LIKE '%Resume=false%' AND '$menu_when_spent' NOT LIKE '%Unlock%' THEN 'ok' ELSE 'menu read [$menu_when_spent] -- wanted a dead Resume on an unlocked cube' END;"
expect = "ok"
```
- [x] Step 2: Single-click the status item's right half and confirm the click landed.
The gesture, not the menu item: this reaches `togglePause` directly, so it tests the refusal itself
rather than the disabled label in front of it. Methods: [Number 7](../Methods.md#method-7),
[Number 8](../Methods.md#method-8).
```toml step
[[actions]]
action = "cgevent_click"
target = "status_item_right"
mode = "single"

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='click' AND debug_log_id > $current_log_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "-> togglePause"
timeout_seconds = 30
```
- [x] Step 3: Confirm the app refused it rather than sending the unpause.
```toml step
use = "method-24.d"
action = "wait_for_sql"
tag = "daily-limit"
expect_contains = "Resume refused"
timeout_seconds = 30
```
- [x] Step 4: Confirm the cube is still paused.
The refusal's actual consequence, read from the device's own frames. A `0` here would mean the
unpause went out regardless of everything above.
```toml step
use = "method-24.k"
column = "paused"
expect = "1"
```

## Scenario C -- the hold survives a relaunch

**Preconditions:** Scenario B complete -- the cube paused by the spent limit, the app running.

- [x] Step 1: Restart the app.
Nothing about the hold is persisted: the flag saying "this app paused the cube" is in memory and does
not survive this. What does survive is the cube's own pause and the recorded total, which is what the
app has to re-arm from. Methods: [Number 3](../Methods.md#method-3),
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
```
- [x] Step 2: Unlock the cube, then confirm the fresh launch still refuses to resume.
Unlock **without** resuming, which is why this is a single named click rather than the resolver Step 6
of Scenario A uses: the resolver would go on to click Resume, and a Resume this scenario expects to be
refused is not something to hand to a poller that retries until it succeeds. Unlocking does not touch
the pause state (`handleLockRequest` only pauses on the way *into* a lock, and only when the cube is
still running), so the cube stays stopped across it -- which the last action here confirms.
The **wait** in front of the click is not padding. A relaunch reports `Login accepted` about four
seconds before the connection is finished and the first history frame has said what the cube is doing,
and until then the dropdown is a stale menu built with neither: its device items are dead and its pause
item reads `Pause`, so there is no `Unlock` to click and the click errors `-1728`. Waiting for the word
to appear turns that race into a wait, and reads the settled state rather than a snapshot of the app
still starting up. Methods: [Number 25](../Methods.md#method-25), [Number 6](../Methods.md#method-6),
[Number 30](../Methods.md#method-30), [Number 24.k](../Methods.md#method-24).
```toml step
[[actions]]
use = "method-25"
expect_contains = "Unlock"
timeout_seconds = 60

[[actions]]
use = "method-6"
item = "Unlock"

[[actions]]
use = "method-30"
capture = "menu_after_relaunch"
timeout_seconds = 30

[[actions]]
action = "sql_query"
query = "SELECT CASE WHEN '$menu_after_relaunch' LIKE '%Resume=false%' AND '$menu_after_relaunch' NOT LIKE '%Unlock%' THEN 'ok' ELSE 'menu read [$menu_after_relaunch] -- wanted a dead Resume on an unlocked cube' END;"
expect = "ok"

[[actions]]
use = "method-24.k"
column = "paused"
expect = "1"
```

## Scenario D -- raising the limit releases the hold

**Preconditions:** Scenario C complete -- the cube paused, the app refusing to resume.

- [x] Step 1: Raise the limit to 15 minutes and restart the app.
The one deliberate act that clears a spent category the same day. Written to the database and picked
up on the reload, for the reason Scenario A Step 5 gives.
```toml step
[[actions]]
action = "sql_exec"
query = "UPDATE category SET daily_limit = 15 WHERE category_id = $limit_category_id;"

[[actions]]
use = "method-3"

[[actions]]
use = "method-2"

[[actions]]
use = "method-4"
since_id = "$current_log_id"
timeout_seconds = 60
```
- [x] Step 2: Unlock the cube, and confirm Resume is offered again.
The unlock is Step 1's quit being undone, exactly as in Scenario C: with the cube still locked the item
would read `Resume=false` for the lock's sake and this scenario would look like a failure of the
release. The same wait precedes it, and for the same reason -- see Scenario C Step 2. Methods:
[Number 25](../Methods.md#method-25), [Number 6](../Methods.md#method-6),
[Number 30](../Methods.md#method-30).
```toml step
[[actions]]
use = "method-25"
expect_contains = "Unlock"
timeout_seconds = 60

[[actions]]
use = "method-6"
item = "Unlock"

[[actions]]
use = "method-30"
expect_contains = "Resume=true"
timeout_seconds = 30
```
- [x] Step 3: Resume, and confirm the cube actually starts again.
What proves the refusal in Scenario B was the limit's doing and not something else that had stopped
the cube for good. Methods: [Number 6](../Methods.md#method-6),
[Number 24.k](../Methods.md#method-24).
```toml step
[[actions]]
use = "method-6"
item = "Resume"

[[actions]]
use = "method-24.k"
action = "wait_for_sql"
column = "paused"
expect = "0"
timeout_seconds = 60
```

## Scenario E -- teardown, leaving nothing for the Interactive phase to inherit

**Preconditions:** Scenarios A to D complete. Runs even if any failed -- the row and the reassigned
face it removes are what would otherwise follow the run into `15i` and `01i`.

- [x] Step 1: Quit the app before unpicking the rows underneath it.
[Method: Number 3](../Methods.md#method-3).
```toml step
use = "method-3"
```
- [x] Step 2: Delete the synthetic segment, restore the face, and drop the test category.
Ordered entry-then-event-then-category so no foreign key is ever left dangling.
```toml step
[[actions]]
action = "sql_exec"
query = "DELETE FROM time_entry WHERE device_event_id IN (SELECT device_event_id FROM device_event WHERE event_number = 900201);"

[[actions]]
action = "sql_exec"
query = "DELETE FROM device_event WHERE event_number = 900201;"

[[actions]]
action = "sql_exec"
query = "UPDATE face SET category_id = $resting_face_category_original WHERE face_id = $resting_face;"

[[actions]]
action = "sql_exec"
query = "DELETE FROM time_entry WHERE category_id IN (SELECT category_id FROM category WHERE category_name = 'ZZ Hard Limit');"

[[actions]]
action = "sql_exec"
query = "DELETE FROM category WHERE category_name = 'ZZ Hard Limit';"
```
- [x] Step 3: Confirm nothing synthetic survives and the resume position is a real event again.
`01i` resumes history from the newest recorded segment, so this is the check that the Interactive
phase starts from the device's own record rather than an invented one.
```toml step
[[actions]]
action = "sql_query"
query = "SELECT COUNT(*) FROM device_event WHERE event_number = 900201;"
expect = "0"

[[actions]]
action = "sql_query"
query = "SELECT COUNT(*) FROM category WHERE category_name = 'ZZ Hard Limit';"
expect = "0"

[[actions]]
action = "sql_query"
query = "SELECT CASE WHEN (SELECT start_epoch FROM device_event ORDER BY start_epoch DESC, device_event_id DESC LIMIT 1) >= $anchor_epoch THEN 'ok' ELSE 'resume position moved behind the anchor' END;"
expect = "ok"
```
- [x] Step 4: Restart the app and leave the device unlocked and unpaused.
The state every other checklist assumes it starts from. Methods:
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

[[actions]]
action = "ensure_unlocked_unpaused"
```
