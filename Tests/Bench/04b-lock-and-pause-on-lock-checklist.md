# Lock / pause_on_lock Checklist (Bench)

### Last run - 2026-08-10 10:11 on the branch 'feature/manualMode'

Covers the app's own "Lock"/"Unlock"/"Pause"/"Resume" status-item **menu** actions
(`MenuBarController`/`ApplicationDelegate.handleLockRequest`) and the `pause_on_lock` setting, for
the scenarios that use only menu clicks and DB-verifiable state -- no status-item gesture
(single/double-click on the right half) and no physical device flip, so all three are fully
Claude-drivable via the verified status-item-menu mechanic ([Method: Number 6](../Methods.md#method-6)). Scenario A and B were originally Scenario C and D of a single combined checklist;
Scenario C was originally Scenario E, with "is the time increasing?" converted from a `(You)`
menu-bar observation to a DB check (the same still-open event's `duration_seconds` growing) --
proving the same fact without needing eyes on the screen. Scenarios D and E below cover the status-item's own click gesture (single-click pause/resume,
double-click lock), now Claude-drivable via CGEventPost ([Method: Number 7](../Methods.md#method-7)) -- previously believed unscriptable
(a raw screen-position hit-test, not a menu/AX action), until `kCGMouseEventClickState` was found to
be the missing piece. Only the physical face-flip-while-locked check in
`Tests/Interactive/04i-lock-and-pause-on-lock-checklist.md` still needs a person.

Methods used throughout this file: [Number 6](../Methods.md#method-6),
[Number 17](../Methods.md#method-17), [Number 7](../Methods.md#method-7).

Despite the setting's name, `pause_on_lock` has **nothing to do with the Mac's screen locking or
sleeping** -- it only controls whether *this app's own* Lock action (menu item, or the
status-item's double-click gesture) also pauses the device first, and whether **quitting the app**
does the same. There is also no auto-resume: once paused via Lock/Quit, the device stays paused
until manually resumed (Pause menu item, or a physical double-tap) -- Unlock alone does not resume
it. Unlike `low_battery_level`/`fetch_history_interval_seconds`, `pause_on_lock` is read live from
SQLite on every Lock/Quit action (`AppDataStore.loadPauseOnLockEnabled()`) -- no app restart needed.

Requires Developer Mode enabled, the `debug` setting's `enabled` field `true` (so `timeFlip`-tagged
debug prints land in `debug_log`), and a paired, connected device.

Lock and pause state are both visible directly in the menu bar status item: a red lock badge
appears to the left of the activity indicator while locked, and that indicator itself is a pause
icon (⏸) while paused or a play icon (▶) while running -- read via accessibility/screenshot, no
menu needs to be open for these two. Reading the menu item's own text/enabled state needs the menu
open first.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Setup

- [ ] Step 1: Query the current `pause_on_lock` value
 and capture it, so a later step (or a resume) can put it back.
 ```toml step
action = "sql_query"
query = "SELECT setting_value FROM setting WHERE setting_name='pause_on_lock';"
capture = "pause_on_lock_original"
```
- [ ] Step 2: Query the device's current lock/pause state and the status-item menu's item names.
      If the device is currently paused or locked, resolve that first (click Resume / Unlock via
      the menu) so the scenarios below start from a clean unlocked, unpaused state.
```toml step
action = "ensure_unlocked_unpaused"
```

## Scenario A -- Lock also pauses when pause_on_lock is enabled, and Unlock does not auto-resume

**Preconditions:** device connected, unlocked, unpaused, `pause_on_lock=true` -- checked and
resolved in Setup immediately above, which this scenario runs straight on from.

- [ ] Step 1: Set `pause_on_lock` to `true`
```toml step
use = "method-24.i"
setting = "pause_on_lock"
value = "{\"enabled\":true}"
```
- [ ] Step 2: Confirm the device is not already paused (latest `device_event` has `paused = 0`).
```toml step
use = "method-24.c"
column = "paused"
expect = "0"
```
- [ ] Step 3: Click the "Lock" menu item.
```toml step
use = "method-6"
item = "Lock"
```
- [ ] Step 4: Confirm a new `paused = 1` device_event
row was written and the lock verified. `debug_log` shows `"Lock ON triggered"` followed by `"Lock verification confirmed: requested=ON actual=ON"`
```toml step
[[actions]]
use = "method-24.d"
action = "wait_for_sql"
tag = "TimeFlip"
expect_contains = "Lock verification confirmed: requested=ON actual=ON"
timeout_seconds = 30

[[actions]]
use = "method-24.c"
column = "paused"
expect = "1"
```
- [ ] Step 5: Check the menu bar shows the lock badge and the pause icon (⏸).
      [Method: Number 17](../Methods.md#method-17).
- [ ] Step 6: Open the menu; confirm the item reads "Unlock" and the Pause item is disabled.
```toml step
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        tell menu bar item 1 of menu bar 2
            click
            delay 0.4
            set names to name of every menu item of menu 1
            set pauseEnabled to enabled of menu item 3 of menu 1
        end tell
        key code 53
    end tell
end tell
return names & {"enabled=" & pauseEnabled}'''
expect_contains = "Unlock"
```
- [ ] Step 7: Click "Unlock".
```toml step
[[actions]]
use = "method-6"
item = "Unlock"

[[actions]]
use = "method-24.d"
action = "wait_for_sql"
tag = "TimeFlip"
expect_contains = "Lock verification confirmed: requested=OFF actual=OFF"
timeout_seconds = 30
```
- [ ] Step 8: Confirm the device is still paused after unlocking
      -- no new `paused = 0` row appears.
```toml step
use = "method-24.c"
column = "paused"
expect = "1"
```
- [ ] Step 9: Check the menu bar: the lock badge is gone and the icon shows pause (⏸).
      [Method: Number 17](../Methods.md#method-17).
- [ ] Step 10: Confirm menu reads "Lock" and "Resume".
```toml step
use = "method-25"
expect_contains = "Resume"
```
- [ ] Step 11: Click "Resume"
to bring the device back to a clean unpaused state.
```toml step
use = "method-6"
item = "Resume"
```
- [ ] Step 12: Confirm a new `paused = 0` row appears in `device_event`
for the resume.
```toml step
use = "method-24.c"
action = "wait_for_sql"
column = "paused"
expect = "0"
timeout_seconds = 30
```

## Scenario B -- Quit pauses and locks the device when pause_on_lock is enabled; disabled it does nothing extra

**Preconditions:** `pause_on_lock=true`, device connected, unlocked, unpaused -- the clean state
Scenario A's own last two steps (Unlock, Resume) leave behind. Check via the query in Step 1
below; if it doesn't match (a locked/paused leftover from an interrupted prior run, e.g.), resolve
it the same way Setup does above (Unlock/Resume via the menu, set `pause_on_lock=true`) before
continuing.

- [ ] Step 1: Confirm `pause_on_lock` is still `true` and the device is unpaused (`paused = 0`).
```toml step
[[actions]]
use = "method-24.a"
setting = "pause_on_lock"
expect = "{\"enabled\":true}"

[[actions]]
use = "method-24.c"
column = "paused"
expect = "0"
```
- [ ] Step 2: Quit the app.
[Method: Number 3](../Methods.md#method-3).
```toml step
[[actions]]
use = "method-24.b"
capture = "before_quit_1_id"

[[actions]]
use = "method-3"
```
- [ ] Step 3: Confirm `debug_log` shows the pause-and-lock-before-exit sequence.
`"Quit requested; pause_on_lock enabled, pausing and locking device before exit"` then `"Pause+lock on quit complete, terminating now"`
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE debug_log_id > $before_quit_1_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Pause+lock on quit complete, terminating now"
timeout_seconds = 30
```
- [ ] Step 4: Start the app
 and confirm reconnect and check the status icon is green. [Method: Number 2](../Methods.md#method-2).
```toml step
[[actions]]
use = "method-2"

[[actions]]
use = "method-4"
since_id = "$before_quit_1_id"
expect_contains = "Login accepted"
timeout_seconds = 30
```
- [ ] Step 5: Confirm a new `paused = 1` device_event row now appears
(only after this relaunch's startup fetch, not immediately after quit).
```toml step
use = "method-24.c"
action = "wait_for_sql"
column = "paused"
expect = "1"
timeout_seconds = 30
```
- [ ] Step 6: Check the menu bar shows the lock badge and the pause icon (⏸).
 [Method: Number 17](../Methods.md#method-17).
- [ ] Step 7: Confirm menu reads "Unlock" and the Pause item is disabled.
```toml step
use = "method-25"
expect_contains = "Unlock"
```
- [ ] Step 8: Click "Unlock", then click "Resume" to return to a clean state.
```toml step
[[actions]]
use = "method-6"
item = "Unlock"

[[actions]]
use = "method-24.d"
action = "wait_for_sql"
tag = "TimeFlip"
expect_contains = "Lock verification confirmed: requested=OFF actual=OFF"
timeout_seconds = 30

[[actions]]
use = "method-6"
item = "Resume"

[[actions]]
use = "method-24.c"
action = "wait_for_sql"
column = "paused"
expect = "0"
timeout_seconds = 30
```
- [ ] Step 9: Test the *disabled* case properly
the noted "original" value is `true`, not `false`, so restoring "to original" here wouldn't actually exercise the disabled-quit path. Explicitly set `pause_on_lock` to `false` instead, confirmed via querying the setting back.
```toml step
[[actions]]
use = "method-24.i"
setting = "pause_on_lock"
value = "{\"enabled\":false}"

[[actions]]
use = "method-24.a"
setting = "pause_on_lock"
expect = "{\"enabled\":false}"
```
- [ ] Step 10: Quit the app
(from the clean, unlocked/unpaused state above, with `pause_on_lock` now genuinely `false`). [Method: Number 3](../Methods.md#method-3).
```toml step
[[actions]]
use = "method-24.b"
capture = "before_quit_2_id"

[[actions]]
use = "method-24.c"
column = "device_event_id"
capture = "event_id_before_disabled_quit"

[[actions]]
use = "method-3"
```
- [ ] Step 11: Query `debug_log` and confirm `"Quit requested; pause_on_lock disabled or device not connected, exiting immediately"`
      -- not the pause/lock sequence above.
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE debug_log_id > $before_quit_2_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Quit requested; pause_on_lock disabled or device not connected, exiting immediately"
timeout_seconds = 30
```
- [ ] Step 12: Confirm no new `paused = 1` device_event
row was added around the quit time.
```toml step
use = "method-24.c"
column = "device_event_id"
expect = "$event_id_before_disabled_quit"
```
- [ ] Step 13: Restore `pause_on_lock` to the real original value
(`true`) noted in Setup.
```toml step
use = "method-24.i"
setting = "pause_on_lock"
value = "{\"enabled\":true}"
```
- [ ] Step 14: Start the app
; confirm reconnect and check the status icon is green with no lock badge -- a clean, unlocked, unpaused state, `pause_on_lock` back to its real original value. [Method: Number 2](../Methods.md#method-2).
```toml step
[[actions]]
use = "method-2"

[[actions]]
use = "method-4"
since_id = "$current_log_id"
expect_contains = "Login accepted"
timeout_seconds = 30

[[actions]]
use = "method-25"
expect_contains = "Lock"
```

## Scenario C -- time genuinely passes in this clean, running state

**Preconditions:** device connected, unlocked, unpaused, `pause_on_lock` back to its real original
value -- the clean state Scenario B's own last step leaves behind. Check via the step below;
if it doesn't match, resolve the same way as Scenario B's own precondition above before continuing.

- [ ] Step 1: Confirm the device is unpaused (latest `device_event` has `paused = 0`).
```toml step
use = "method-24.c"
column = "paused"
expect = "0"
```
- [ ] Step 2: Note the current `device_event` row's `device_event_id` and `duration_seconds`
      Wait a few seconds.
```toml step
use = "method-24.c"
column = "duration_seconds"
capture = "duration_before_wait"
```
- [ ] Step 3: Re-query the same `device_event_id` and confirm `duration_seconds` increased
and it's still the same row.
```toml step
action = "wait_for_sql"
query = "SELECT CASE WHEN duration_seconds > $duration_before_wait THEN 'increased' ELSE duration_seconds END FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
expect = "increased"
timeout_seconds = 30
```
- [ ] Step 4: Confirm menu reads "Lock" and the Pause is enabled
      -- a clean state ready for `Tests/Interactive/04i-lock-and-pause-on-lock-checklist.md`
```toml step
use = "method-25"
expect_contains = "Pause"
```

## Scenario D -- manual Lock/Unlock via the status item's double-click gesture, with pause_on_lock disabled

Confirms the double-click gesture (`MenuBarController.handleStatusItemClick`) is a genuine
equivalent to the "Lock"/"Unlock" menu item, not just wired to open the menu -- and that the
single-click pause/resume gesture is a no-op while locked. [Method: Number 7](../Methods.md#method-7), at the status item's right-half
point (`x = position.x + size.width * 0.75`, `y = position.y + size.height / 2`); re-read
`position`/`size` fresh each time, since the status item's width shifts with its content.

**Preconditions:** device connected, unlocked, unpaused -- the clean state Scenario C leaves
behind, though `pause_on_lock` is still `true` from there; this scenario's own first step forces it
to `false` regardless.

- [ ] Step 1: Set `pause_on_lock` to `false`
```toml step
use = "method-24.i"
setting = "pause_on_lock"
value = "{\"enabled\":false}"
```
- [ ] Step 2: Confirm the menu reads "Lock", i.e. the device is unlocked.
      The dropdown, not the menu-bar badge -- `Lock`/`Unlock` are mutually-exclusive labels
      ([Method: Number 25](../Methods.md#method-25)), and the badge itself is only checked visually
      in Step 7 below.
```toml step
use = "method-25"
expect_contains = "Lock"
```
- [ ] Step 3: Double-click the right half of the status icon
(CGEventPost, `click_state=1` then `2`, ~0.15s apart). Query `debug_log` (tag `click`) and confirm `clickCount=1` then `clickCount=2`, both `side=right`, then (tag `TimeFlip`) `"Lock ON triggered"` / `"...confirmed: requested=ON actual=ON"`
```toml step
[[actions]]
action = "cgevent_click"
target = "status_item_right"
mode = "double"

[[actions]]
use = "method-24.d"
action = "wait_for_sql"
tag = "TimeFlip"
expect_contains = "Lock verification confirmed: requested=ON actual=ON"
timeout_seconds = 30
```
- [ ] Step 4: Confirm no new `paused = 1` row was added
      -- `pause_on_lock` disabled, so Lock alone must not pause.
```toml step
use = "method-24.c"
column = "paused"
expect = "0"
```
- [ ] Step 5: Single-click the right half of the status icon
      confirm via `debug_log` (`clickCount=1`, no accompanying second click) the click landed, and
      that nothing else changed -- still locked, no pause/resume toggle, no new `device_event` row
      (a no-op while locked, `togglePause()`'s own guard).
```toml step
[[actions]]
use = "method-24.c"
column = "device_event_id"
capture = "event_id_before_noop_click"

[[actions]]
action = "cgevent_click"
target = "status_item_right"
mode = "single"

[[actions]]
use = "method-24.d"
action = "wait_for_sql"
tag = "click"
expect_contains = "clickCount=1"
timeout_seconds = 30

[[actions]]
use = "method-24.c"
column = "device_event_id"
expect = "$event_id_before_noop_click"
```
- [ ] Step 6: Double-click the right half of the status icon again
      confirm `debug_log` shows `clickCount=1` then `clickCount=2` again, then `"Lock OFF triggered"` / `"...confirmed: requested=OFF actual=OFF"`
```toml step
[[actions]]
action = "cgevent_click"
target = "status_item_right"
mode = "double"

[[actions]]
use = "method-24.d"
action = "wait_for_sql"
tag = "TimeFlip"
expect_contains = "Lock verification confirmed: requested=OFF actual=OFF"
timeout_seconds = 30
```
- [ ] Step 7: Check the menu bar: the lock badge is gone and the icon shows the play icon (▶).
      [Method: Number 17](../Methods.md#method-17). The only visual check of the *cleared* badge in
      this file -- Scenario A's Steps 5 and 9 both look at the locked rendering, and every other
      "unlocked" step here reads the DB or the dropdown instead, neither of which can see the badge.
      Step 6 above already proved the state itself (`requested=OFF actual=OFF`), so what this step
      adds is that the status item actually repainted to match.
- [ ] Step 8: Restore `pause_on_lock` to `true`
and confirm the device is unlocked, unpaused -- clean for the next scenario.
```toml step
[[actions]]
use = "method-24.i"
setting = "pause_on_lock"
value = "{\"enabled\":true}"

[[actions]]
use = "method-24.c"
column = "paused"
expect = "0"
```

## Scenario E -- status-item single-click gesture is a no-op while locked (menu-driven lock)

Confirms the same no-op guard as Scenario D's single-click check, but with Lock triggered via the
menu item instead of the gesture -- the two lock triggers are independent code paths into the same
`isLocked` state, so each is checked against the gesture-driven pause/resume toggle separately (see
"Running a checklist" rule 5 in `/CLAUDE.md`).

**Preconditions:** device connected, unlocked, unpaused, `pause_on_lock=true` -- Scenario D's own
last step leaves this behind; check via the dropdown's item names ([Method: Number
25](../Methods.md#method-25)) and resolve via Unlock/Resume from the menu if it doesn't match.

- [ ] Step 1: Click the "Lock" menu item.
      Confirm `debug_log` shows `"Lock ON triggered"` / `"...confirmed: requested=ON actual=ON"`
```toml step
[[actions]]
use = "method-6"
item = "Lock"

[[actions]]
use = "method-24.d"
action = "wait_for_sql"
tag = "TimeFlip"
expect_contains = "Lock verification confirmed: requested=ON actual=ON"
timeout_seconds = 30
```
- [ ] Step 2: Single-click the right half of the status icon
(CGEventPost, single `click_state=1`). Confirm via `debug_log` (tag `click`, `clickCount=1`) the click landed, and confirm no new `device_event` row appeared -- still locked, no pause/resume toggle.
```toml step
[[actions]]
use = "method-24.c"
column = "device_event_id"
capture = "event_id_before_menu_lock_noop"

[[actions]]
action = "cgevent_click"
target = "status_item_right"
mode = "single"

[[actions]]
use = "method-24.d"
action = "wait_for_sql"
tag = "click"
expect_contains = "clickCount=1"
timeout_seconds = 30

[[actions]]
use = "method-24.c"
column = "device_event_id"
expect = "$event_id_before_menu_lock_noop"
```
- [ ] Step 3: Click "Unlock" from the menu, then "Resume"
to return to a clean, unlocked, unpaused state.
```toml step
action = "ensure_unlocked_unpaused"
```

The physical face-flip-while-locked check still needs a real cube flip -- see
`Tests/Interactive/04i-lock-and-pause-on-lock-checklist.md`
