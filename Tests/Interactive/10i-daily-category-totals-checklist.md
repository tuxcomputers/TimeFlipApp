# Daily Category Totals Checklist

### Last run - 2026-08-05 on the branch 'chore/newDesignRefactor'

The half of the day-totals feature that needs a hand on the cube. `Bench/10b` proves the sum from
inserted rows with the device held still; this proves it from real flips, which is the case a user
actually meets: time spent on one face, then more on another face sharing its category, has to keep
counting up rather than restart.

The distinction matters because the two keyings differ **only** when the second face is a *different*
face with the *same* category. A single face's time accumulates correctly either way, so no amount of
resting on one face can tell the two apart -- the flip is the test.

What a per-face regression would look like here: the duration **drops** on the flip, back to whatever
the arriving face had of its own, instead of carrying the pair's combined figure forward.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Setup

**Preconditions:** the test database, the device connected, unlocked and unpaused -- established by
`Tests/00-test-setup.md`. Unlike `Bench/10b` this scenario needs the device **running**, since the
point is time accruing across a flip.

- [x] **(Claude)** Step 1: Confirm `db_type` reads **test**.
```toml step
use = "method-24.a"
setting = "db_type"
expect = '{"type":"test"}'
```
- [x] **(Claude)** Step 2: Confirm the device is unlocked and unpaused.
A lock silently refuses flips (no error, just no event), which would leave the flip steps below
waiting forever.
```toml step
action = "ensure_unlocked_unpaused"
```
- [x] **(Claude)** Step 3: Capture both stickered faces' category assignments so Scenario B can restore them.
```toml step
[[actions]]
action = "sql_query"
query = "SELECT category_id FROM face WHERE face_id = 2;"
capture = "face2_original"

[[actions]]
action = "sql_query"
query = "SELECT category_id FROM face WHERE face_id = 8;"
capture = "face8_original"
```

## Scenario A -- time carries across a flip between two faces sharing a category

**Preconditions:** Setup complete: test database, device connected, unlocked and unpaused, both
faces' original assignments captured.

- [x] **(Claude)** Step 1: Point both **Meeting** (face 2) and **Break** (face 8) at one category, and restart so the app picks it up.
Face 2's own category is reused as the shared one, so the name on the menu bar stays meaningful. The
device is also re-confirmed unlocked and unpaused here rather than trusted from Setup: a
restart-from-scenario resume skips Setup, and this scenario needs the cube **running** for time to
accrue across the flip. Methods: [Number 3](../Methods.md#method-3),
[Number 2](../Methods.md#method-2), [Number 4](../Methods.md#method-4).
```toml step
[[actions]]
use = "method-3"

[[actions]]
action = "sql_exec"
query = "UPDATE face SET category_id = $face2_original WHERE face_id = 8;"

[[actions]]
use = "method-2"

[[actions]]
use = "method-4"
since_id = "$current_log_id"
timeout_seconds = 60

[[actions]]
action = "ensure_unlocked_unpaused"
```
- [x] **(Claude)** Step 2: Capture which face the cube is resting on, and name the one to flip to.
Only **Break** (face 8) and **Meeting** (face 2) carry stickers, so the flip is always between those
two. [Method: Number 24.h](../Methods.md#method-24).
```toml step
[[actions]]
use = "method-24.c"
column = "device_face"
capture = "face_before_flip"

[[actions]]
use = "method-24.h"
capture = "flip_target_face"
```
- [x] **(You)** Step 3: Flip the cube to the face named in the prompt, then leave it resting there.
Detected from the new `device_event` row rather than waiting on an answer
([Method: Number 19](../Methods.md#method-19)), so there is nothing to confirm by hand.
```toml step
action = "ask_user_or_detect"
prompt = "Flip the cube to the $flip_target_face face, then leave it resting there."
detect_query = "SELECT device_face FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
expect = "$flip_target_face"
timeout_seconds = 0
```
- [x] **(Claude)** Step 4: Let a minute of real time accrue on this face.
Enough that the arriving face's own contribution is unmistakably non-zero, so Step 7's comparison
distinguishes "carried the pair's total forward" from "restarted on this face".
```toml step
action = "shell"
command = "sleep 60"
```
- [x] **(Claude)** Step 5: Pause the device and read the exact combined figure.
Pausing is what makes the reading exact rather than drifting (see `Bench/10b`). Methods:
[Number 6](../Methods.md#method-6), [Number 25](../Methods.md#method-25),
[Number 27](../Methods.md#method-27).
```toml step
[[actions]]
use = "method-6"
item = "Pause"

[[actions]]
use = "method-25"
expect_contains = "Resume"

[[actions]]
use = "method-27"
capture = "title_after_flip"
```
- [x] **(Claude)** Step 6: Compute what the shared category has recorded today from `time_entry`.
The same window and the same table `DailyCategoryTotals.seedFromHistory` reads, so this is the figure
the menu bar must be showing -- derived independently of it rather than read back off the screen.
```toml step
action = "sql_query"
query = "WITH r AS (SELECT CAST(json_extract(setting_value,'$.hour') AS INT) h, CAST(json_extract(setting_value,'$.minute') AS INT) m FROM setting WHERE setting_name='daily_reset_time'), t AS (SELECT CAST(strftime('%s', date('now','localtime') || ' ' || substr('0'||h,-2) || ':' || substr('0'||m,-2) || ':00', 'utc') AS INT) AS today_reset FROM r), w AS (SELECT CASE WHEN CAST(strftime('%s','now') AS INT) >= today_reset THEN today_reset ELSE today_reset - 86400 END AS ws FROM t), s AS (SELECT CAST(COALESCE(SUM(MAX(0, MIN(de.start_epoch + te.duration_seconds, CAST(strftime('%s','now') AS INT)) - MAX(de.start_epoch, (SELECT ws FROM w)))), 0) AS INT) AS secs FROM time_entry te JOIN device_event de ON de.device_event_id = te.device_event_id WHERE te.category_id = $face2_original AND (de.start_epoch + te.duration_seconds) > (SELECT ws FROM w)) SELECT CAST(secs/3600 AS INT) || ':' || substr('0' || CAST((secs%3600)/60 AS INT), -2) || ':' || substr('0' || CAST(secs%60 AS INT), -2) FROM s;"
capture = "expected_total"
```
- [x] **(Claude)** Step 7: Confirm the menu bar's figure is that whole-category total.
Both faces' time is inside it. A per-face figure would be short by whatever was spent on the face
flipped away from, which Step 4 made sure is at least a minute.
```toml step
action = "sql_query"
query = "SELECT CASE WHEN '$title_after_flip' LIKE '%$expected_total%' THEN 'matches' ELSE 'menu bar shows [$title_after_flip], category total is $expected_total' END;"
expect = "matches"
```
- [x] **(You)** Step 8: Confirm the duration never dropped when the cube was flipped.
The one thing no single reading can show: a per-face regression restarts the count on the arriving
face, so the figure falls at the instant of the flip and climbs again from there. You watched it
happen in Step 3. (Note: the flip is a brief moment and is easy to miss -- it was missed on
2026-08-05. When that happens, two readings of [Method: Number 27](../Methods.md#method-27)
**bracketing** the flip settle it without a second run: the figure only ever climbs in real time, so
an after-reading higher than the before-reading rules out a reset, which would have had to re-climb
the whole gap from the arriving face's own smaller tally. That run read `0:21:02` on face 2 and
`0:21:21` on face 8. Worth converting this step to capture both automatically, per Method 17's point
that a time-based check is not automatically a `(You)` one.)
```toml step
action = "ask_user"
prompt = "When you flipped the cube, did the menu bar's duration keep climbing rather than dropping back? (y/n)"
```

## Scenario B -- teardown

**Preconditions:** Scenario A complete. Runs even if it failed -- the reassignment it undoes would
otherwise outlive this checklist.

- [x] **(Claude)** Step 1: Restore both faces' original categories and resume the device.
```toml step
[[actions]]
use = "method-3"

[[actions]]
action = "sql_exec"
query = "UPDATE face SET category_id = $face2_original WHERE face_id = 2;"

[[actions]]
action = "sql_exec"
query = "UPDATE face SET category_id = $face8_original WHERE face_id = 8;"

[[actions]]
use = "method-2"

[[actions]]
use = "method-4"
since_id = "$current_log_id"
timeout_seconds = 60

[[actions]]
action = "ensure_unlocked_unpaused"
```
- [x] **(Claude)** Step 2: Confirm both faces read their original categories again.
```toml step
action = "sql_query"
query = "SELECT CASE WHEN (SELECT category_id FROM face WHERE face_id = 2) = $face2_original AND (SELECT category_id FROM face WHERE face_id = 8) = $face8_original THEN 'restored' ELSE 'face assignments not restored' END;"
expect = "restored"
```
