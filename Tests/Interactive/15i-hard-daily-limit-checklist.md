# Hard Daily Limit Checklist

### Last run - 2026-08-12 16:32 on the branch 'feature/dailyLimit'

The physical half of the hard `daily_limit`: what a flip does to a cube the limit has stopped, and
what a double tap does. `15b` covers the crossing itself and the refused resume, neither of which
needs a hand on the cube.

Three claims live here and nowhere else, because each of them starts with a physical action:

- **Flipping onto a spent category pauses the cube**, arriving at the limit rather than crossing it.
- **Flipping off it resumes the cube automatically.** Pause is a property of the cube where a limit is
  a property of a category, so holding the pause across a flip would spend one category's budget and
  stop the day's tracking with it.
- **A double tap cannot be refused, only answered.** It pauses and unpauses in firmware, telling the
  app afterwards ([Method: Number 22](../Methods.md#method-22), and the Double tap characteristic in
  `docs/TimeFlip2 BLE Protocol v4.3.md`), so the app's only move is to put the pause back.

The fixture is this checklist's own and does not survive it: `15b` tears its own down, and the
Interactive phase runs long after the Bench one. **Both stickered faces are pointed at categories made
here** -- face 8 (**Break**) at one whose budget is already spent, face 2 (**Meeting**) at one with no
limit at all. Reusing whatever those faces normally hold would make the flip-away target's budget a
matter of what the rest of the day recorded, and this scenario needs it to be certainly unspent.

`900202` is this checklist's own event number, clear of `00-test-setup.md`'s `900001`-`900003`, `10b`'s
`900101`-`900102` and `15b`'s `900201`.

## Setup

**Preconditions:** the test database, the device connected, established by `Tests/00-test-setup.md`.

- [x] **(Claude)** Step 1: Confirm `db_type` reads **test** before anything writes to it.
```toml step
use = "method-24.a"
setting = "db_type"
expect = '{"type":"test"}'
```
- [x] **(Claude)** Step 2: Capture the day window and the anchor the synthetic segment sits behind.
The same window `DailyCategoryTotals` computes, and the same reason `10b` places its rows behind the
newest recorded event: ahead of it, the resume position moves and every later history fetch starts
again from event 0. Ten minutes of room, against the two the segment needs.
```toml step
[[actions]]
action = "sql_query"
query = "WITH r AS (SELECT CAST(json_extract(setting_value,'$.hour') AS INT) h, CAST(json_extract(setting_value,'$.minute') AS INT) m FROM setting WHERE setting_name='daily_reset_time'), t AS (SELECT CAST(strftime('%s', date('now','localtime') || ' ' || substr('0'||h,-2) || ':' || substr('0'||m,-2) || ':00', 'utc') AS INT) AS today_reset FROM r) SELECT CASE WHEN CAST(strftime('%s','now') AS INT) >= today_reset THEN today_reset ELSE today_reset - 86400 END FROM t;"
capture = "window_start"

[[actions]]
action = "sql_query"
query = "SELECT start_epoch FROM device_event ORDER BY start_epoch DESC, device_event_id DESC LIMIT 1;"
capture = "anchor_epoch"

[[actions]]
action = "sql_query"
query = "SELECT CASE WHEN $anchor_epoch - 600 >= $window_start THEN 'ok' ELSE 'anchor ' || $anchor_epoch || ' leaves no room after window start ' || $window_start END;"
expect = "ok"
```
- [x] **(Claude)** Step 3: Capture both stickered faces' current categories for the teardown to restore.
The guard comes first for the reason `15b` records under its own Setup: captured off a face that a
halted run left pointed at one of this file's fixture categories, the "original" would be the
fixture's own id, and Step 2 of the teardown would restore the face to a category it had just deleted.
Once the real assignment has been overwritten it is not recoverable from this database, only from the
previous run's row in `logs/testruns.sqlite`, so this reports rather than guesses.
```toml step
[[actions]]
action = "sql_query"
query = "SELECT CASE WHEN (SELECT COUNT(*) FROM face f JOIN category c ON c.category_id = f.category_id WHERE f.face_id IN (2, 8) AND c.category_name IN ('ZZ Hard Limit', 'ZZ No Limit')) = 0 THEN 'ok' ELSE 'a stickered face is still pointed at this checklist fixture -- a previous run halted before its teardown. Point faces 2 and 8 back at their real categories before re-running; the values they should hold are in logs/testruns.sqlite as face2_category_original and face8_category_original.' END;"
expect = "ok"

[[actions]]
action = "sql_query"
query = "SELECT category_id FROM face WHERE face_id = 2;"
capture = "face2_category_original"

[[actions]]
action = "sql_query"
query = "SELECT category_id FROM face WHERE face_id = 8;"
capture = "face8_category_original"
```
- [x] **(Claude)** Step 4: Build the fixture: a spent category on **Break** and an unlimited one on **Meeting**.
Leftovers from an abandoned run are dropped first, so this is idempotent -- `UN1_category` is unique on
name among active rows, and a stale synthetic segment would still sit in today's window. Two minutes of
recorded time against a one-minute limit puts `ZZ Hard Limit` past its budget before the app ever
starts, which is the point: this file tests arriving at a spent limit, where `15b` tests crossing one.
```toml step
[[actions]]
action = "sql_exec"
query = "DELETE FROM time_entry WHERE device_event_id IN (SELECT device_event_id FROM device_event WHERE event_number = 900202);"

[[actions]]
action = "sql_exec"
query = "DELETE FROM device_event WHERE event_number = 900202;"

[[actions]]
action = "sql_exec"
query = "DELETE FROM time_entry WHERE category_id IN (SELECT category_id FROM category WHERE category_name IN ('ZZ Hard Limit', 'ZZ No Limit'));"

[[actions]]
action = "sql_exec"
query = "UPDATE face SET category_id = 0 WHERE category_id IN (SELECT category_id FROM category WHERE category_name IN ('ZZ Hard Limit', 'ZZ No Limit'));"

[[actions]]
action = "sql_exec"
query = "DELETE FROM category WHERE category_name IN ('ZZ Hard Limit', 'ZZ No Limit');"

[[actions]]
action = "sql_exec"
query = "INSERT INTO category (category_name, active, daily_limit) VALUES ('ZZ Hard Limit', 1, 1);"

[[actions]]
action = "sql_exec"
query = "INSERT INTO category (category_name, active, daily_limit) VALUES ('ZZ No Limit', 1, 0);"

[[actions]]
action = "sql_query"
query = "SELECT category_id FROM category WHERE category_name = 'ZZ Hard Limit';"
capture = "limit_category_id"

[[actions]]
action = "sql_query"
query = "SELECT category_id FROM category WHERE category_name = 'ZZ No Limit';"
capture = "free_category_id"

[[actions]]
action = "sql_exec"
query = "UPDATE face SET category_id = $limit_category_id WHERE face_id = 8;"

[[actions]]
action = "sql_exec"
query = "UPDATE face SET category_id = $free_category_id WHERE face_id = 2;"

[[actions]]
action = "sql_exec"
query = "INSERT INTO device_event (event_number, event_type_id, device_face, start_time, timezone_id, start_epoch, duration_seconds, paused, finalised, processed) SELECT 900202, 1, 8, strftime('%Y-%m-%dT%H:%M:%S', $anchor_epoch - 600, 'unixepoch', 'localtime'), (SELECT timezone_id FROM device_event ORDER BY start_epoch DESC, device_event_id DESC LIMIT 1), $anchor_epoch - 600, 120.0, 0, 1, 1;"

[[actions]]
action = "sql_exec"
query = "INSERT INTO time_entry (category_id, device_event_id, started_at, start_timezone_id, ended_at, end_timezone_id, duration_seconds) SELECT $limit_category_id, device_event_id, strftime('%Y-%m-%dT%H:%M:%S', start_epoch, 'unixepoch', 'localtime'), timezone_id, strftime('%Y-%m-%dT%H:%M:%S', start_epoch + duration_seconds, 'unixepoch', 'localtime'), timezone_id, duration_seconds FROM device_event WHERE event_number = 900202;"

[[actions]]
action = "sql_query"
query = "SELECT CAST(SUM(duration_seconds) AS INT) FROM time_entry WHERE category_id = $limit_category_id;"
expect = "120"
```

## Scenario A -- flipping onto a spent category pauses the cube

**Preconditions:** the fixture from Setup, and -- resolved by Step 1 below rather than assumed -- the
app running against a cube that is unlocked and **not** paused, resting on **Meeting**.

- [x] **(Claude)** Step 1: Restart the app so the fixture loads, and leave the cube unlocked and running.
The limits and the face assignments ride along on the activity record, so they arrive on a reload
rather than being watched for. Methods: [Number 3](../Methods.md#method-3),
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
- [x] **(You)** Step 2: Rest the cube on the **Meeting** face (face 2) if it is not there already.
The starting side, so the flip in Step 3 is onto the spent face rather than off it. Nothing to answer:
the step reads the device's own face and continues by itself, and passes immediately if the cube is
already there. **No timeout** -- taking your time cannot fail the run.
```toml step
action = "wait_for_sql"
prompt = "Rest the cube on the Meeting face (face 2), if it is not resting there already."
query = "SELECT device_face FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
expect = "2"
poll_interval = 2
timeout_seconds = 0
```
- [x] **(You)** Step 3: Flip the cube to the **Break** face (face 8) and leave it there.
Break holds the category whose budget is already spent, so this is the arrival the scenario is about.
Detected from the new `device_event` row rather than waiting on an answer
([Method: Number 19](../Methods.md#method-19)). The log baseline is taken here rather than in a step
of its own, so that nothing can ever sit between it and the flip it has to precede.
```toml step
[[actions]]
use = "method-24.b"
capture = "before_limit_flip_id"

[[actions]]
action = "ask_user_or_detect"
prompt = "Flip the cube to the Break face (face 8), then leave it resting there."
detect_query = "SELECT device_face FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
expect = "8"
timeout_seconds = 0
```
- [x] **(Claude)** Step 4: Confirm the app pauses the cube on arrival.
Not a crossing: the budget was spent before the flip, so the pause is a response to the face itself,
and it lands about a second behind the flip -- inside the gap between Step 3 returning and this step
starting. So the baseline is Step 3's named one, not `$current_log_id`: that one is re-read
immediately before every step, which here would be *after* the pause it is meant to be waiting for.
Same reasoning as Scenario B's Step 1, which is where this checklist got it right first.
```toml step
use = "method-24.e"
action = "wait_for_sql"
tag = "daily-limit"
since_id = "$before_limit_flip_id"
expect_contains = "Limit reached, pausing device"
timeout_seconds = 60
```
### Bugs found and fixed - branch 'feature/dailyLimit'
2026-08-12 - Scoped on `$current_log_id`, which the runner re-reads before every step, so the pause
logged ~1s after Step 3's flip was already below the baseline and the step waited 60s for a second
message the app is right not to send; now scoped on a baseline captured before the flip.
- [x] **(Claude)** Step 5: Confirm the cube itself is paused, not just the app's record of it.
`device_event.paused` comes from the device's own history frames.
```toml step
use = "method-24.k"
action = "wait_for_sql"
column = "paused"
expect = "1"
timeout_seconds = 60
```

## Scenario B -- flipping off it resumes the cube, flipping back stops it again

**Preconditions:** Scenario A complete -- the cube paused by the limit, resting on **Break**, the app
running.

- [x] **(Claude)** Step 1: Note where the log is up to, so the resume below is read as this scenario's.
`current_log_id` moves before every step, so a baseline that has to survive a flip needs its own name.
[Method: Number 24.b](../Methods.md#method-24).
```toml step
use = "method-24.b"
capture = "before_flip_away_id"
```
- [x] **(You)** Step 2: Rest the cube on the **Meeting** face (face 2), if it is not there already.
Meeting holds the category with no limit, so the cube has budget again the moment it lands.

Satisfied by the **open record being on face 2**, which is a state and not a transition. A cube already
resting here therefore passes at once and is asked for nothing. Reading the newest row's face instead
would have the same effect *usually* but not always, since the newest row can be a closed one; and
requiring the *arrival* -- a new face-2 event -- would be worse than either, because the only way to
produce one on a cube already here is to flip away and back, and away is the **spent** face, which
pauses the cube exactly as it should. That is a correct pause landing in the middle of a scenario
about not pausing (measured 2026-08-12, see the bug below).

The log position for the step after this is taken here too, once the cube has arrived, so that
anything the journey provoked stays outside the window that step reads.
```toml step
[[actions]]
action = "ask_user_or_detect"
prompt = "Rest the cube on the Meeting face (face 2), if it is not resting there already."
detect_query = "SELECT device_face FROM device_event WHERE finalised = 0 AND event_number < 900000 ORDER BY device_event_id DESC LIMIT 1;"
expect = "2"
timeout_seconds = 0

[[actions]]
use = "method-24.b"
capture = "after_flip_away_id"
```
- [x] **(Claude)** Step 3: Confirm the limit let the cube go, sending nothing after the flip.
This is the scenario's claim, stated as the app's silence: the pause belonged to a category that is
no longer on show, so nothing here may put it back. A `pausing device` line would mean the limit had
followed the cube off its own face.
It does **not** assert that the app sent the resume, which is what it asked for until 2026-08-12 and
could never get: **a flip resumes the cube in firmware**, the app having no part in it (see the bug
below and `docs/timeflip2-firmware-observations.md`), so the first frame after the flip already
reports it running and there is nothing left to send. `DailyLimitEnforcement.resume` still exists for
a pause that *survives* -- the limit raised while the cube sits paused on the spent face, where
nothing physical has lifted it -- and `15b` is where that path is exercised, no hand required.
Scoped from Step 2's own position, and to lines that are actually a **send**: the limit logs its
position on every tick, and a line ending `(already sent ...)` is it declining to write because one is
already outstanding (`MenuBarController.limitWriteSentAtEventNumber`). Counting those as sends reads
the restraint as the very thing it prevents.
```toml step
action = "sql_query"
query = "SELECT COALESCE((SELECT message FROM debug_log WHERE tag='daily-limit' AND debug_log_id > $after_flip_away_id AND message LIKE '%pausing device%' AND message NOT LIKE '%already sent%' ORDER BY debug_log_id DESC LIMIT 1), 'quiet');"
expect = "quiet"
```
### Bugs found and fixed - branch 'feature/dailyLimit'
2026-08-12 - Waited for the app to log a resume it can never send: the cube unpauses itself on a
flip, so the frame the app acts on already reports it running. Step now asserts the app sent nothing.
2026-08-12 - Found by the above: the app went on claiming the firmware-lifted pause as its own
(`isPausedByLimit` was only cleared when it sent the resume itself), so a pause the **user** then
asked for on a face with budget was read as the limit's and undone on the next frame.
2026-08-12 - The replacement step then failed on a correct pause: it read from Step 1's position, so
a cube already resting on Meeting -- which Step 2 asked to be flipped *to*, satisfiable only by going
away over the spent face and back -- put a legitimate pause inside its window. Step 2 now asks for the
resting state rather than the arrival, and this reads from after it. Same step also counted a
`(already sent ...)` line, which is the app declining to write, as a write.
- [x] **(Claude)** Step 4: Read whether the cube is running, and record it rather than assert it.
It should read `0`, and normally does. It is not an assertion because a physical flip can itself
register as a double tap, which the firmware pauses on unconditionally
([Method: Number 22](../Methods.md#method-22), measured in `10i` on 2026-08-06) -- and a pause
arriving *after* the resume, on a category with budget to spare, is one the app leaves alone, exactly
as it leaves any pause it did not ask for. So a `1` here means the cube was double-tapped on the way
over, not that the resume failed; Step 3 is what proves the limit did not put the pause back. The run
log keeps the reading either way.
```toml step
use = "method-24.k"
column = "paused"
capture = "paused_after_flip_away"
```
- [x] **(Claude)** Step 5: Note the log position again, for the flip back.
```toml step
use = "method-24.b"
capture = "before_flip_back_id"
```
- [x] **(You)** Step 6: Flip the cube back to the **Break** face (face 8) and leave it there.
```toml step
action = "ask_user_or_detect"
prompt = "Flip the cube back to the Break face (face 8), then leave it resting there."
detect_query = "SELECT device_face FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
expect = "8"
timeout_seconds = 0
```
- [x] **(Claude)** Step 7: Confirm the spent category stops the cube again on the way back.
The other half of the rule, and the one that shows the release was scoped to the face rather than
spending the hold for the day.
```toml step
[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='daily-limit' AND debug_log_id > $before_flip_back_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Limit reached, pausing device"
timeout_seconds = 60

[[actions]]
use = "method-24.k"
action = "wait_for_sql"
column = "paused"
expect = "1"
timeout_seconds = 60
```

## Scenario C -- a double tap is answered, not refused

**Preconditions:** Scenario B complete -- the cube paused by the limit, resting on **Break**, the app
running.

- [x] **(Claude)** Step 1: Confirm the cube's double-tap sensitivity is real rather than suppressed.
[Method: Number 22](../Methods.md#method-22)'s suppression sets **Window** to `0` for a session that
does not want incidental taps; this scenario is the one that does, so it checks the register has its
real value back before asking for a tap that would otherwise never register. The value is a physical
device register, independent of which database is active.
```toml step
action = "sql_query"
query = "SELECT CASE WHEN CAST(json_extract(setting_value, '$.window') AS INT) > 0 THEN 'ok' ELSE 'double-tap window is 0, taps are suppressed -- restore real sensitivity first (Method 22)' END FROM setting WHERE setting_name='double_tap_settings';"
expect = "ok"
```
- [x] **(Claude)** Step 2: Note the log position, so what the app does next is read as an answer to the tap.
```toml step
use = "method-24.b"
capture = "before_double_tap_id"
```
- [x] **(You)** Step 3: Double-tap the top of the cube once, firmly.
The one path no refusal can reach: the firmware toggles its own pause and only tells the app
afterwards. Answer `y` once you have tapped it -- there is no single side effect to poll for here,
because what the tap does is exactly what this scenario is measuring.
```toml step
action = "ask_user"
prompt = "Double-tap the top face of the cube once, firmly. Done? (y/n)"
```
- [x] **(Claude)** Step 4: Confirm the cube ends up paused whichever way the tap went.
The durable claim, and the one that holds regardless of an open question about the firmware: the spec
says a double tap *sets* pause, `docs/timeflip.md` says it *toggles* it, and the two disagree about
what a tap on an already-paused cube does. Either way the cube must be stopped afterwards -- because
the tap left it paused, or because it started it and the app put the pause back.
```toml step
use = "method-24.k"
action = "wait_for_sql"
column = "paused"
expect = "1"
timeout_seconds = 60
```
- [x] **(Claude)** Step 5: Record which of the two it was.
A capture rather than an assertion, because this is the measurement: a `Limit reached, pausing device`
row since Step 2's baseline means the tap really did unpause the cube and the app answered it, which
settles the toggle-versus-set question above. Nothing means the tap was a no-op on an
already-paused cube. Either result is a pass here; what must not happen is the cube being left
running, which Step 4 covers. **A result here belongs in
`docs/timeflip2-firmware-observations.md`**, cited to this run -- that file is for behaviour measured
on the device where the spec is silent or wrong, which is exactly what this is.
```toml step
action = "sql_query"
query = "SELECT COALESCE((SELECT 'app re-paused: ' || message FROM debug_log WHERE tag='daily-limit' AND debug_log_id > $before_double_tap_id AND message LIKE 'Limit reached%' ORDER BY debug_log_id DESC LIMIT 1), 'no app action: the tap did not unpause a paused cube');"
capture = "double_tap_outcome"
```

## Scenario D -- teardown

**Preconditions:** Scenarios A to C complete. Runs even if any failed -- the reassigned faces and the
synthetic segment would otherwise outlive this checklist, and both stickered faces would go on
pointing at categories that are about to be deleted.

- [x] **(Claude)** Step 1: Quit the app before unpicking the rows underneath it.
[Method: Number 3](../Methods.md#method-3).
```toml step
use = "method-3"
```
- [x] **(Claude)** Step 2: Delete the synthetic segment, restore both faces, and drop both categories.
Ordered entry-then-event-then-category so no foreign key is ever left dangling.
```toml step
[[actions]]
action = "sql_exec"
query = "DELETE FROM time_entry WHERE device_event_id IN (SELECT device_event_id FROM device_event WHERE event_number = 900202);"

[[actions]]
action = "sql_exec"
query = "DELETE FROM device_event WHERE event_number = 900202;"

[[actions]]
action = "sql_exec"
query = "UPDATE face SET category_id = $face2_category_original WHERE face_id = 2;"

[[actions]]
action = "sql_exec"
query = "UPDATE face SET category_id = $face8_category_original WHERE face_id = 8;"

[[actions]]
action = "sql_exec"
query = "DELETE FROM time_entry WHERE category_id IN (SELECT category_id FROM category WHERE category_name IN ('ZZ Hard Limit', 'ZZ No Limit'));"

[[actions]]
action = "sql_exec"
query = "DELETE FROM category WHERE category_name IN ('ZZ Hard Limit', 'ZZ No Limit');"
```
- [x] **(Claude)** Step 3: Confirm nothing synthetic survives and both faces read their own categories again.
```toml step
[[actions]]
action = "sql_query"
query = "SELECT COUNT(*) FROM device_event WHERE event_number = 900202;"
expect = "0"

[[actions]]
action = "sql_query"
query = "SELECT COUNT(*) FROM category WHERE category_name IN ('ZZ Hard Limit', 'ZZ No Limit');"
expect = "0"

[[actions]]
action = "sql_query"
query = "SELECT CASE WHEN (SELECT category_id FROM face WHERE face_id = 2) = $face2_category_original AND (SELECT category_id FROM face WHERE face_id = 8) = $face8_category_original THEN 'ok' ELSE 'a stickered face is not back on its own category' END;"
expect = "ok"
```
- [x] **(Claude)** Step 4: Restart the app and leave the device unlocked and unpaused.
The cube has spent this checklist paused by a limit that no longer exists, so this is what hands it
back running. Methods: [Number 3](../Methods.md#method-3), [Number 2](../Methods.md#method-2),
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
