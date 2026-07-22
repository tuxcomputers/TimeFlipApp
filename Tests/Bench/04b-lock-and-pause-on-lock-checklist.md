# Lock / pause_on_lock Checklist (Bench)

### Last run - 2026-07-22 on the branch 'feature/projects'

Covers the app's own "Lock"/"Unlock"/"Pause"/"Resume" status-item **menu** actions
(`MenuBarController`/`ApplicationDelegate.handleLockRequest`) and the `pause_on_lock` setting, for
the scenarios that use only menu clicks and DB-verifiable state -- no status-item gesture
(single/double-click on the right half) and no physical device flip, so all three are fully
Claude-drivable via the verified status-item-menu mechanic (Method: Click a status-item menu item,
`../Methods.md`). Scenario A and B were originally Scenario C and D of a single combined checklist;
Scenario C was originally Scenario E, with "is the time increasing?" converted from a `(You)`
menu-bar observation to a DB check (the same still-open event's `duration_seconds` growing) --
proving the same fact without needing eyes on the screen. Scenarios D and E below cover the status-item's own click gesture (single-click pause/resume,
double-click lock), now Claude-drivable via CGEventPost (Method: Simulate a real click,
double-click, or held press via CGEventPost, `../Methods.md`) -- previously believed unscriptable
(a raw screen-position hit-test, not a menu/AX action), until `kCGMouseEventClickState` was found to
be the missing piece. Only the physical facet-flip-while-locked check in
`Tests/Interactive/04i-lock-and-pause-on-lock-checklist.md` still needs a person.

Methods used throughout this file: Click a status-item menu item, Screenshot-based visual
confirmation, Simulate a real click, double-click, or held press via CGEventPost (`../Methods.md`).

Despite the setting's name, `pause_on_lock` has **nothing to do with the Mac's screen locking or
sleeping** -- it only controls whether *this app's own* Lock action (menu item, or the
status-item's double-click gesture) also pauses the device first, and whether **quitting the app**
does the same. There is also no auto-resume: once paused via Lock/Quit, the device stays paused
until manually resumed (Pause menu item, or a physical double-tap) -- Unlock alone does not resume
it. Unlike `low_battery_level`/`fetch_history_interval_seconds`, `pause_on_lock` is read live from
SQLite on every Lock/Quit action (`AppDataStore.loadPauseOnLockEnabled()`) -- no app restart needed.

Requires Developer Mode enabled, the `debug` setting's `enabled` field `true` (so `.timeFlip`-tagged
debug prints land in `debug_log`), and a paired, connected device.

Lock and pause state are both visible directly in the menu bar status item: a red lock badge
appears to the left of the activity indicator while locked, and that indicator itself is a pause
icon (⏸) while paused or a play icon (▶) while running -- read via accessibility/screenshot, no
menu needs to be open for these two. Reading the menu item's own text/enabled state needs the menu
open first.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Setup

- [x] Query the current `pause_on_lock` value and note it as the original value to restore later.
      (Original: `true`.)
```toml step
action = "sql_query"
query = "SELECT setting_value FROM setting WHERE setting_name='pause_on_lock';"
capture = "pause_on_lock_original"
```
- [x] Query the device's current lock/pause state and the status-item menu's item names. If the
      device is currently paused or locked, resolve that first (click Resume / Unlock via the
      menu) so the scenarios below start from a clean unlocked, unpaused state. (Found locked +
      paused leftover from an earlier session; resolved via Unlock then Resume.)
```toml step
action = "ensure_unlocked_unpaused"
```

## Scenario A -- Lock also pauses when pause_on_lock is enabled, and Unlock does not auto-resume

**Preconditions:** device connected, unlocked, unpaused, `pause_on_lock=true` -- checked and
resolved in Setup immediately above, which this scenario runs straight on from.

- [x] Set `pause_on_lock` to `true`. (Already `true` from Setup.)
```toml step
action = "sql_exec"
query = "UPDATE setting SET setting_value = '{\"enabled\":true}' WHERE setting_name = 'pause_on_lock';"
```
- [x] Screenshot the menu bar; confirm the status item shows the play icon (▶) -- device not
      already paused. (Confirmed.)
```toml step
action = "sql_query"
query = "SELECT is_paused FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
expect = "0"
```
- [x] Click the "Lock" menu item.
```toml step
action = "click_menu_item"
item = "Lock"
```
- [x] Confirm a new `is_paused = 1` device_event row was written, and that `debug_log` shows
      `"Lock ON triggered"` followed by `"Lock verification confirmed: requested=ON actual=ON"`.
      (Confirmed -- this is also where real post-reset events started appearing again after
      `02b-reset-device-checklist.md`'s reset: event_number 1, then 2 here, proving the counter
      wipe more directly than the `device_last_event=nil` evidence noted there.)
```toml step
[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Lock verification confirmed: requested=ON actual=ON"
timeout_seconds = 10

[[actions]]
action = "sql_query"
query = "SELECT is_paused FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
expect = "1"
```
- [x] Screenshot the menu bar; confirm the lock badge is now shown and the icon switched to pause
      (⏸). (Confirmed visually.)
- [x] Open the menu; confirm the item reads "Unlock" and the Pause item is disabled. (Confirmed:
      `Resume` item `enabled = false`.)
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
- [x] Click "Unlock".
```toml step
[[actions]]
action = "click_menu_item"
item = "Unlock"

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Lock verification confirmed: requested=OFF actual=OFF"
timeout_seconds = 10
```
- [x] Confirm the device is still paused after unlocking -- no new `is_paused = 0` row appears.
      (Confirmed.)
```toml step
action = "sql_query"
query = "SELECT is_paused FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
expect = "1"
```
- [x] Screenshot the menu bar; confirm the lock badge is gone but the icon still shows pause (⏸).
      (Confirmed visually, duration frozen.)
- [x] Open the menu; confirm the item reads "Lock" again, and the Pause item is now enabled and
      reads "Resume". (Confirmed: `Resume` item `enabled = true`.)
```toml step
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        tell menu bar item 1 of menu bar 2
            click
            delay 0.4
            set names to name of every menu item of menu 1
        end tell
        key code 53
    end tell
end tell
return names'''
expect_contains = "Resume"
```
- [x] Click "Resume" to bring the device back to a clean unpaused state.
```toml step
action = "click_menu_item"
item = "Resume"
```
- [x] Confirm a new `is_paused = 0` row appears in `device_event` for the resume. (Confirmed.)
```toml step
action = "wait_for_sql"
query = "SELECT is_paused FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
expect = "0"
timeout_seconds = 8
poll_interval = 1
```

## Scenario B -- Quit pauses and locks the device when pause_on_lock is enabled; disabled it does nothing extra

**Preconditions:** `pause_on_lock=true`, device connected, unlocked, unpaused -- the clean state
Scenario A's own last two steps (Unlock, Resume) leave behind. Check via the query/screenshot
below; if it doesn't match (a locked/paused leftover from an interrupted prior run, e.g.), resolve
it the same way Setup does above (Unlock/Resume via the menu, set `pause_on_lock=true`) before
continuing.

- [x] Confirm `pause_on_lock` is still `true`. Screenshot: no lock badge, play icon. (Confirmed.)
```toml step
[[actions]]
action = "sql_query"
query = "SELECT setting_value FROM setting WHERE setting_name='pause_on_lock';"
expect = "{\"enabled\":true}"

[[actions]]
action = "sql_query"
query = "SELECT is_paused FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
expect = "0"
```
- [x] Quit the app.
```toml step
[[actions]]
action = "sql_query"
query = "SELECT MAX(debug_log_id) FROM debug_log;"
capture = "before_quit_1_id"

[[actions]]
action = "shell"
command = "osascript -e 'tell application \"TimeFlip\" to quit'"
```
- [x] Query `debug_log` and confirm the sequence `"Quit requested; pause_on_lock enabled, pausing
      and locking device before exit"` then `"Pause+lock on quit complete, terminating now"`.
      (Confirmed.)
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE debug_log_id > $before_quit_1_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Pause+lock on quit complete, terminating now"
timeout_seconds = 10
```
- [x] Start the app; confirm reconnect and via screenshot that the status icon is green. (Confirmed
      fresh `"Login accepted, code=0x02"`.)
```toml step
[[actions]]
action = "shell"
command = "nohup ./.build/bundler/apps/TimeFlip/TimeFlip.app/Contents/MacOS/TimeFlip > /dev/null 2>&1 &"

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Login accepted%' AND debug_log_id > $before_quit_1_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Login accepted"
timeout_seconds = 30
```
- [x] Confirm a new `is_paused = 1` device_event row now appears (only after this relaunch's
      startup fetch, not immediately after quit). (Confirmed.)
```toml step
action = "wait_for_sql"
query = "SELECT is_paused FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
expect = "1"
timeout_seconds = 20
poll_interval = 2
```
- [x] Screenshot the menu bar; confirm the lock badge is shown and the icon shows pause (⏸).
      (Confirmed visually.)
- [x] Open the menu; confirm the item reads "Unlock" and the Pause item is disabled. (Confirmed:
      `Resume` item `enabled = false`.)
```toml step
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        tell menu bar item 1 of menu bar 2
            click
            delay 0.4
            set names to name of every menu item of menu 1
        end tell
        key code 53
    end tell
end tell
return names'''
expect_contains = "Unlock"
```
- [x] Click "Unlock", then click "Resume" to return to a clean state. (Confirmed via new
      `is_paused = 0` row.)
```toml step
[[actions]]
action = "click_menu_item"
item = "Unlock"

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Lock verification confirmed: requested=OFF actual=OFF"
timeout_seconds = 10

[[actions]]
action = "click_menu_item"
item = "Resume"

[[actions]]
action = "wait_for_sql"
query = "SELECT is_paused FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
expect = "0"
timeout_seconds = 8
poll_interval = 1
```
- [x] Test the *disabled* case properly: the noted "original" value is `true`, not `false`, so
      restoring "to original" here wouldn't actually exercise the disabled-quit path. Explicitly
      set `pause_on_lock` to `false` instead, confirmed via querying the setting back.
```toml step
[[actions]]
action = "sql_exec"
query = "UPDATE setting SET setting_value = '{\"enabled\":false}' WHERE setting_name = 'pause_on_lock';"

[[actions]]
action = "sql_query"
query = "SELECT setting_value FROM setting WHERE setting_name='pause_on_lock';"
expect = "{\"enabled\":false}"
```
- [x] Quit the app (from the clean, unlocked/unpaused state above, with `pause_on_lock` now
      genuinely `false`).
```toml step
[[actions]]
action = "sql_query"
query = "SELECT MAX(debug_log_id) FROM debug_log;"
capture = "before_quit_2_id"

[[actions]]
action = "sql_query"
query = "SELECT device_event_id FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
capture = "event_id_before_disabled_quit"

[[actions]]
action = "shell"
command = "osascript -e 'tell application \"TimeFlip\" to quit'"
```
- [x] Query `debug_log` and confirm `"Quit requested; pause_on_lock disabled or no paired device,
      exiting immediately"` -- not the pause/lock sequence above. (Confirmed.)
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE debug_log_id > $before_quit_2_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Quit requested; pause_on_lock disabled or no paired device, exiting immediately"
timeout_seconds = 10
```
- [x] Confirm no new `is_paused = 1` device_event row was added around the quit time. (Confirmed.)
```toml step
action = "sql_query"
query = "SELECT device_event_id FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
expect = "$event_id_before_disabled_quit"
```
- [x] Restore `pause_on_lock` to the real original value (`true`) noted in Setup.
```toml step
action = "sql_exec"
query = "UPDATE setting SET setting_value = '{\"enabled\":true}' WHERE setting_name = 'pause_on_lock';"
```
- [x] Start the app; confirm reconnect and via screenshot that the status icon is green with no
      lock badge -- a clean, unlocked, unpaused state, `pause_on_lock` back to its real original
      value. (Confirmed.)
```toml step
[[actions]]
action = "sql_query"
query = "SELECT MAX(debug_log_id) FROM debug_log;"
capture = "before_launch_3_id"

[[actions]]
action = "shell"
command = "nohup ./.build/bundler/apps/TimeFlip/TimeFlip.app/Contents/MacOS/TimeFlip > /dev/null 2>&1 &"

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Login accepted%' AND debug_log_id > $before_launch_3_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Login accepted"
timeout_seconds = 30

[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        tell menu bar item 1 of menu bar 2
            click
            delay 0.4
            set names to name of every menu item of menu 1
        end tell
        key code 53
    end tell
end tell
return names'''
expect_contains = "Lock"
```

## Scenario C -- time genuinely passes in this clean, running state

**Preconditions:** device connected, unlocked, unpaused, `pause_on_lock` back to its real original
value -- the clean state Scenario B's own last step leaves behind. Check via the screenshot below;
if it doesn't match, resolve the same way as Scenario B's own precondition above before continuing.

- [x] Screenshot the menu bar; confirm no lock badge is shown and the icon shows play (▶).
      (Confirmed.)
```toml step
action = "sql_query"
query = "SELECT is_paused FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
expect = "0"
```
- [x] Note the current (still-open, non-finalised) `device_event` row's `device_event_id` and
      `duration_seconds`. Wait a few seconds.
```toml step
action = "sql_query"
query = "SELECT duration_seconds FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
capture = "duration_before_wait"
```
- [x] Re-query the same `device_event_id` and confirm `duration_seconds` increased and it's still
      the same row. (Confirmed: 88.0s -> 97.0s, same row `device_event_id=11`, `is_paused = 0`.)
```toml step
action = "wait_for_sql"
query = "SELECT CASE WHEN duration_seconds > $duration_before_wait THEN 'increased' ELSE duration_seconds END FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
expect = "increased"
timeout_seconds = 15
poll_interval = 3
```
- [x] Open the menu; confirm the Lock item reads "Lock" and the Pause item reads "Pause" and is
      enabled -- a clean state ready for `Tests/Interactive/04i-lock-and-pause-on-lock-checklist.md`.
      (Confirmed.)
```toml step
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        tell menu bar item 1 of menu bar 2
            click
            delay 0.4
            set names to name of every menu item of menu 1
        end tell
        key code 53
    end tell
end tell
return names'''
expect_contains = "Pause"
```

## Scenario D -- manual Lock/Unlock via the status item's double-click gesture, with pause_on_lock disabled

Confirms the double-click gesture (`MenuBarController.handleStatusItemClick`) is a genuine
equivalent to the "Lock"/"Unlock" menu item, not just wired to open the menu -- and that the
single-click pause/resume gesture is a no-op while locked. Method: Simulate a real click,
double-click, or held press via CGEventPost (`../Methods.md`), at the status item's right-half
point (`x = position.x + size.width * 0.75`, `y = position.y + size.height / 2`); re-read
`position`/`size` fresh each time, since the status item's width shifts with its content.

**Preconditions:** device connected, unlocked, unpaused -- the clean state Scenario C leaves
behind, though `pause_on_lock` is still `true` from there; this scenario's own first step forces it
to `false` regardless.

- [x] Set `pause_on_lock` to `false`. (Confirmed: `{"enabled":false}`.)
```toml step
action = "sql_exec"
query = "UPDATE setting SET setting_value = '{\"enabled\":false}' WHERE setting_name = 'pause_on_lock';"
```
- [x] Confirm the menu bar shows no lock badge and a play icon (unlocked, unpaused).
```toml step
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        tell menu bar item 1 of menu bar 2
            click
            delay 0.4
            set names to name of every menu item of menu 1
        end tell
        key code 53
    end tell
end tell
return names'''
expect_contains = "Lock"
```
- [x] Double-click the right half of the status icon (CGEventPost, `click_state=1` then `2`,
      ~0.15s apart). Query `debug_log` (tag `click`) and confirm `clickCount=1` then `clickCount=2`,
      both `side=right`, then (tag `TimeFlip`) `"Lock ON triggered"` / `"...confirmed: requested=ON
      actual=ON"`. (Confirmed live.)
```toml step
[[actions]]
action = "cgevent_click"
target = "status_item_right"
mode = "double"

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Lock verification confirmed: requested=ON actual=ON"
timeout_seconds = 10
```
- [x] Confirm no new `is_paused = 1` row was added -- `pause_on_lock` disabled, so Lock alone must
      not pause.
```toml step
action = "sql_query"
query = "SELECT is_paused FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
expect = "0"
```
- [x] Single-click (not double) the right half of the status icon; confirm via `debug_log`
      (`clickCount=1`, no accompanying second click) the click landed, and that nothing else
      changed -- still locked, no pause/resume toggle, no new `device_event` row (a no-op while
      locked, `togglePause()`'s own guard). (Confirmed live: click logged, `device_event` row
      unchanged.)
```toml step
[[actions]]
action = "sql_query"
query = "SELECT device_event_id FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
capture = "event_id_before_noop_click"

[[actions]]
action = "cgevent_click"
target = "status_item_right"
mode = "single"

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='click' ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "clickCount=1"
timeout_seconds = 5

[[actions]]
action = "sql_query"
query = "SELECT device_event_id FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
expect = "$event_id_before_noop_click"
```
- [x] Double-click the right half of the status icon again; confirm `debug_log` shows
      `clickCount=1` then `clickCount=2` again, then `"Lock OFF triggered"` / `"...confirmed:
      requested=OFF actual=OFF"`. (Confirmed live.)
```toml step
[[actions]]
action = "cgevent_click"
target = "status_item_right"
mode = "double"

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Lock verification confirmed: requested=OFF actual=OFF"
timeout_seconds = 10
```
- [x] Confirm the menu bar shows no lock badge again (unlocked).
```toml step
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        tell menu bar item 1 of menu bar 2
            click
            delay 0.4
            set names to name of every menu item of menu 1
        end tell
        key code 53
    end tell
end tell
return names'''
expect_contains = "Lock"
```
- [x] Restore `pause_on_lock` to `true` and confirm the device is unlocked, unpaused -- clean for
      the next scenario. (Confirmed.)
```toml step
[[actions]]
action = "sql_exec"
query = "UPDATE setting SET setting_value = '{\"enabled\":true}' WHERE setting_name = 'pause_on_lock';"

[[actions]]
action = "sql_query"
query = "SELECT is_paused FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
expect = "0"
```

## Scenario E -- status-item single-click gesture is a no-op while locked (menu-driven lock)

Confirms the same no-op guard as Scenario D's single-click check, but with Lock triggered via the
menu item instead of the gesture -- the two lock triggers are independent code paths into the same
`isLocked` state, so each is checked against the gesture-driven pause/resume toggle separately (see
"Running a checklist" rule 5 in `../CLAUDE.md`).

**Preconditions:** device connected, unlocked, unpaused, `pause_on_lock=true` -- Scenario D's own
last step leaves this behind; check via the menu bar and resolve via Unlock/Resume from the menu if
it doesn't match.

- [x] Click the "Lock" menu item. Confirm `debug_log` shows `"Lock ON triggered"` / `"...confirmed:
      requested=ON actual=ON"`. (Confirmed.)
```toml step
[[actions]]
action = "click_menu_item"
item = "Lock"

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Lock verification confirmed: requested=ON actual=ON"
timeout_seconds = 10
```
- [x] Single-click the right half of the status icon (CGEventPost, single `click_state=1`). Confirm
      via `debug_log` (tag `click`, `clickCount=1`) the click landed, and confirm no new
      `device_event` row appeared -- still locked, no pause/resume toggle. (Confirmed live: click
      logged, no new row.)
```toml step
[[actions]]
action = "sql_query"
query = "SELECT device_event_id FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
capture = "event_id_before_menu_lock_noop"

[[actions]]
action = "cgevent_click"
target = "status_item_right"
mode = "single"

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='click' ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "clickCount=1"
timeout_seconds = 5

[[actions]]
action = "sql_query"
query = "SELECT device_event_id FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
expect = "$event_id_before_menu_lock_noop"
```
- [x] Click "Unlock" from the menu, then "Resume" to return to a clean, unlocked, unpaused state.
      (Confirmed.)
```toml step
action = "ensure_unlocked_unpaused"
```

The physical facet-flip-while-locked check still needs a real cube flip -- see
`Tests/Interactive/04i-lock-and-pause-on-lock-checklist.md`.
