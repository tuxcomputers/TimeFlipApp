# Auto-Pause Arrow Stepper Checklist

### Last run - 2026-07-22 on the branch 'feature/projects'

Covers the auto-pause field's press-and-hold arrow behavior (`AutoPauseStepper`): ticks by 1 until
passing the *second* multiple-of-5 gridline from the value the hold started at, then by 5, at a
slower tick rate. This replaced a stock SwiftUI `Stepper` (whose held-repeat rate can't be varied).
Also covers a fix for a hold whose release event never arrives (window closed while the mouse button
was still down), which would otherwise keep the repeat loop -- and its device/DB writes -- running
in the background. Requires Developer Mode enabled and a paired, connected device (the field is
disabled while unpaired).

**Automated coverage:** the full tick sequence and slower-past-the-second-boundary timing are
unit-tested in `Tests/TimeFlipAppTests/AutoPauseStepperTests.swift`, the `auto_pause_minutes` DB
round-trip in `SettingsPersistenceTests.swift`, and the hold-cancel-on-window-close in
`AppStateDeviceTabTests.swift`.

This bench file also now covers the press-and-hold acceleration gesture and the
window-closed-mid-hold case (Scenarios C-E below) -- previously believed to need a person actually
holding the mouse button down, since AppleScript's `click`/`click at {x, y}` never reaches this
custom `Image`+`onLongPressGesture` control. A raw `CGEventPost` `mouseDown`/wait/`mouseUp` does
reach it, confirmed live in both directions plus the compound window-close case ([Method: Number 7](../Methods.md#method-7)) -- so
`Tests/Interactive/05i-auto-pause-arrow-stepper-checklist.md` is now a stub.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Setup

The switch to the test database (quit, `use-test-database.sh`, relaunch, confirm reconnect)
is done once by `Tests/00-test-setup.md`, which the supervisor always runs first -- not
repeated here.

- [ ] Step 1: Query `db_type` and confirm it reads `{"type":"test"}`
before proceeding:  `sqlite3 ~/Library/Application\ Support/TimeFlip/appdata.sqlite "SELECT setting_value FROM setting WHERE setting_name = 'db_type';"`.
```toml step
use = "method-24.a"
setting = "db_type"
expect = "{\"type\":\"test\"}"
```
- [ ] Step 2: Open Preferences and switch to the Device tab (selected by name).
Methods: [Number 6](../Methods.md#method-6), [Number 10](../Methods.md#method-10). Confirm **Auto-pause** sits at the top of the **Settings** section, above the collapsed **LED** disclosure (not inside a separate **Advanced** section, which no longer exists) -- read the ordering of static text/control elements in that section via accessibility ([Method: Number 11](../Methods.md#method-11)).
```toml step
[[actions]]
use = "method-6"
item = "Settings..."

[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        click (first radio button of radio group 1 of group 1 of toolbar 1 of window "TimeFlip Settings" whose description is "Device")
        delay 0.3
        return value of static text 1 of group 2 of scroll area 1 of group 1 of window "TimeFlip Settings"
    end tell
end tell'''
expect_contains = "Auto-pause"
```

## Scenario A -- typing a value into the field persists to the DB

**Preconditions:** device connected and paired, Preferences open on the Device tab with Auto-pause
visible -- established in Setup immediately above, which this scenario runs straight on from.
[Method: Number 12](../Methods.md#method-12).

- [ ] Step 1: Type `4` directly into the auto-pause text field
and confirm the DB row updated: `SELECT setting_value FROM setting WHERE setting_name = 'auto_pause_minutes';` should read `{"minutes":4}`.
```toml step
[[actions]]
action = "applescript"
script = '''
tell application "TimeFlip" to activate
tell application "System Events"
    tell process "TimeFlip"
        set e to text field 1 of group 2 of scroll area 1 of group 1 of window "TimeFlip Settings"
        set focused of e to true
        keystroke "a" using command down
        keystroke "4"
        keystroke return
    end tell
end tell'''

[[actions]]
use = "method-24.a"
action = "wait_for_sql"
setting = "auto_pause_minutes"
expect = "{\"minutes\":4}"
timeout_seconds = 30
```
- [ ] Step 2: Type `26` into the field
and confirm the same row now reads `{"minutes":26}`.
```toml step
[[actions]]
action = "applescript"
script = '''
tell application "TimeFlip" to activate
tell application "System Events"
    tell process "TimeFlip"
        set e to text field 1 of group 2 of scroll area 1 of group 1 of window "TimeFlip Settings"
        set focused of e to true
        keystroke "a" using command down
        keystroke "26"
        keystroke return
    end tell
end tell'''

[[actions]]
use = "method-24.a"
action = "wait_for_sql"
setting = "auto_pause_minutes"
expect = "{\"minutes\":26}"
timeout_seconds = 30
```
- [ ] Step 3: Type `0` into the field
and confirm the row reads `{"minutes":0}`, leaving auto-pause disabled for the next run.
```toml step
[[actions]]
action = "applescript"
script = '''
tell application "TimeFlip" to activate
tell application "System Events"
    tell process "TimeFlip"
        set e to text field 1 of group 2 of scroll area 1 of group 1 of window "TimeFlip Settings"
        set focused of e to true
        keystroke "a" using command down
        keystroke "0"
        keystroke return
    end tell
end tell'''

[[actions]]
use = "method-24.a"
action = "wait_for_sql"
setting = "auto_pause_minutes"
expect = "{\"minutes\":0}"
timeout_seconds = 30
```

## Scenario B -- device write is debounced 1s after the value settles, then read back and verified

Covers `ApplicationDelegate`'s `onAutoPauseChange` (prints + immediate DB write on every change,
device write debounced through `DeviceWriteDebouncer`) and `TimeFlipBLEDevice.setAutoPause`'s
read-back verification (`0x10` status), added alongside the debounce.

**Preconditions:** device connected and paired, Preferences open on the Device tab with the
auto-pause field focusable -- left in place by the previous scenario, which also leaves
`auto_pause_minutes` at `0`, though this scenario overwrites that value immediately anyway.

- [ ] Step 1: Type three distinct values into the field in quick succession
committing each with Return and staying on the field: `7`, then immediately `70`, then immediately `150`. (Note: Return is what commits, and it keeps focus; `tab` would commit too but move focus on, so the next value would land somewhere else. [Method: Number 12](../Methods.md#method-12).)
```toml step
[[actions]]
use = "method-24.b"
capture = "before_rapid_id"

[[actions]]
action = "applescript"
script = '''
tell application "TimeFlip" to activate
tell application "System Events"
    tell process "TimeFlip"
        set e to text field 1 of group 2 of scroll area 1 of group 1 of window "TimeFlip Settings"
        set focused of e to true
        keystroke "a" using command down
        keystroke "7"
        keystroke return
        keystroke "a" using command down
        keystroke "70"
        keystroke return
        keystroke "a" using command down
        keystroke "150"
        keystroke return
    end tell
end tell'''
```
- [ ] Step 2: Confirm **each** intermediate value logged a changed + saved-to-DB pair, in order.
In `debug_log` (tag `auto-pause`), rows newer than the noted ID: a `"Auto-pause value changed to Xm"` + `"Auto-pause saved to DB: Xm"` pair per value -- -- the print+DB-write side is immediate and untouched by the debounce.
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='auto-pause' AND message LIKE 'Auto-pause value changed to 150m%' AND debug_log_id > $before_rapid_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Auto-pause value changed to 150m"
timeout_seconds = 30
```
- [ ] Step 3: Confirm `auto_pause_minutes` already reads `{"minutes":150}`
immediately (before the 1s debounce elapses) -- the DB write never waited on the debounce.
```toml step
use = "method-24.a"
setting = "auto_pause_minutes"
expect = "{\"minutes\":150}"
```
- [ ] Step 4: Cconfirm one debounced triggered line and its confirmation.
In `debug_log`: exactly **one** `"Auto-pause set to 150m triggered"` (not one per intermediate value), timestamped roughly 1s after the last (`150`) change, followed by  `"Auto-pause verification confirmed: requested=150m actual=150m"`.
```toml step
use = "method-24.e"
action = "wait_for_sql"
tag = "auto-pause"
since_id = "$before_rapid_id"
expect_contains = "Auto-pause verification confirmed: requested=150m actual=150m"
timeout_seconds = 30
```
- [ ] Step 5: Type `0` into the field
(single change, not part of a rapid sequence) and confirm after ~1.5s the same pattern: one triggered/confirmed pair for `0m`, leaving auto-pause disabled for the next run.
```toml step
[[actions]]
action = "applescript"
script = '''
tell application "TimeFlip" to activate
tell application "System Events"
    tell process "TimeFlip"
        set e to text field 1 of group 2 of scroll area 1 of group 1 of window "TimeFlip Settings"
        set focused of e to true
        keystroke "a" using command down
        keystroke "0"
        keystroke return
    end tell
end tell'''

[[actions]]
use = "method-24.e"
action = "wait_for_sql"
tag = "auto-pause"
since_id = "$current_log_id"
expect_contains = "Auto-pause verification confirmed: requested=0m actual=0m"
timeout_seconds = 30
```

## Scenario C -- press-and-hold acceleration, up arrow

**Preconditions:** device connected and paired, Preferences open on the Device tab with the
auto-pause field focusable, TimeFlip frontmost before typing ([Method: Number 12](../Methods.md#method-12)). Get the arrow's coordinates from `image 1`'s own `position`/`size`, deriving the down
arrow from it by the stack's pitch -- both stepper `image` elements report that same upper-chevron
rect, so `image 2` is no use (see the coordinate caveat in the CGEventPost method, `../Methods.md`).

- [ ] Step 1: Type `1` directly into the auto-pause text field
(starting value for the hold).
```toml step
[[actions]]
action = "applescript"
script = '''
tell application "TimeFlip" to activate
tell application "System Events"
    tell process "TimeFlip"
        set e to text field 1 of group 2 of scroll area 1 of group 1 of window "TimeFlip Settings"
        set focused of e to true
        keystroke "a" using command down
        keystroke "1"
        keystroke return
    end tell
end tell'''

[[actions]]
use = "method-24.a"
action = "wait_for_sql"
setting = "auto_pause_minutes"
expect = "{\"minutes\":1}"
timeout_seconds = 30

[[actions]]
use = "method-24.b"
capture = "before_hold_id"
```
- [ ] Step 2: Click and hold the **up** arrow
(CGEventPost `mouseDown`, wait ~4s, `mouseUp`) until the value passes 30, then release. [Method: Number 7](../Methods.md#method-7).
```toml step
action = "cgevent_click"
target = "autopause_up_arrow"
mode = "hold"
hold_seconds = 4
```
- [ ] Step 3: Confirm the hold stepped by single digits, then by 5 past the second gridline.
The full sequence during the hold is in `debug_log` (tag `auto-pause`, `"Auto-pause value changed to Xm"`): single digits up through the second gridline past the starting value, then steps of 5 beyond that (`secondBoundary` uses integer division). Asserted as the literal run of values the hold produced, scoped to rows newer than the pre-hold ID -- an assertion that only read the *last* value would tick just as happily if the click missed the arrow entirely and nothing moved.
```toml step
[[actions]]
action = "sql_query"
query = "SELECT group_concat(v) FROM (SELECT CAST(substr(message, 29, length(message) - 29) AS INTEGER) AS v FROM debug_log WHERE tag='auto-pause' AND message LIKE 'Auto-pause value changed to %' AND debug_log_id > $before_hold_id ORDER BY debug_log_id);"
expect_contains = "2,3,4,5,6,7,8,9,10,15,20"

[[actions]]
action = "sql_query"
query = "SELECT CAST(substr(message, 29, length(message) - 29) AS INTEGER) FROM debug_log WHERE tag='auto-pause' AND message LIKE 'Auto-pause value changed to %' AND debug_log_id > $before_hold_id ORDER BY debug_log_id DESC LIMIT 1;"
capture = "final_hold_value"
```
- [ ] Step 4: Query the DB and confirm `auto_pause_minutes` matches the final logged value.
```toml step
use = "method-24.a"
setting = "auto_pause_minutes"
expect = "{\"minutes\":$final_hold_value}"
```

## Scenario D -- press-and-hold acceleration, down arrow

**Preconditions:** same as Scenario C. This scenario overwrites the field's value immediately via
its own first step, so Scenario C's ending value doesn't matter.

- [ ] Step 1: Type `26` directly into the auto-pause text field.
```toml step
[[actions]]
action = "applescript"
script = '''
tell application "TimeFlip" to activate
tell application "System Events"
    tell process "TimeFlip"
        set e to text field 1 of group 2 of scroll area 1 of group 1 of window "TimeFlip Settings"
        set focused of e to true
        keystroke "a" using command down
        keystroke "26"
        keystroke return
    end tell
end tell'''

[[actions]]
use = "method-24.a"
action = "wait_for_sql"
setting = "auto_pause_minutes"
expect = "{\"minutes\":26}"
timeout_seconds = 30

[[actions]]
use = "method-24.b"
capture = "before_down_hold_id"
```
- [ ] Step 2: Click and hold the **down** arrow
(CGEventPost `mouseDown`, wait ~4s, `mouseUp`) until the value reaches 0, then release.
```toml step
action = "cgevent_click"
target = "autopause_down_arrow"
mode = "hold"
hold_seconds = 4
```
- [ ] Step 3: Query `debug_log` and confirm the sequence mirrors Scenario C
single digits down to the second gridline below 26, then by 5 down to 0, and that the field stayed at 0 rather than going negative once the down arrow was held past it -- the whole run asserted as one literal sequence, same reason as Scenario C's Step 3.
```toml step
action = "wait_for_sql"
query = "SELECT group_concat(v) FROM (SELECT CAST(substr(message, 29, length(message) - 29) AS INTEGER) AS v FROM debug_log WHERE tag='auto-pause' AND message LIKE 'Auto-pause value changed to %' AND debug_log_id > $before_down_hold_id ORDER BY debug_log_id);"
expect_contains = "25,24,23,22,21,20,15,10,5,0"
timeout_seconds = 30
```
- [ ] Step 4: Confirm `auto_pause_minutes` reads `{"minutes":0}`, not negative.
```toml step
use = "method-24.a"
setting = "auto_pause_minutes"
expect = "{\"minutes\":0}"
```

## Scenario E -- a hold interrupted by closing the window doesn't keep running

**Preconditions:** same as Scenario C/D -- Preferences open on the Device tab (this scenario closes
and reopens that window mid-scenario, so it must start open).

- [ ] Step 1: Type `50` directly into the auto-pause text field.
```toml step
[[actions]]
action = "applescript"
script = '''
tell application "TimeFlip" to activate
tell application "System Events"
    tell process "TimeFlip"
        set e to text field 1 of group 2 of scroll area 1 of group 1 of window "TimeFlip Settings"
        set focused of e to true
        keystroke "a" using command down
        keystroke "50"
        keystroke return
    end tell
end tell'''

[[actions]]
use = "method-24.a"
action = "wait_for_sql"
setting = "auto_pause_minutes"
expect = "{\"minutes\":50}"
timeout_seconds = 30
```
- [ ] Step 2: Click and hold the **up** arrow
(CGEventPost `mouseDown`). While still "held" (no `mouseUp` posted yet), post a synthetic **Escape** keydown/keyup (`CGEventCreateKeyboardEvent(None, 53, True/False)`) to close the Preferences window, wait ~1s, then post `mouseUp` -- two independent synthetic event streams interleaving exactly like two real hands would; nothing about the gesture actually needs physical simultaneity, just event ordering.
```toml step
action = "cgevent_hold_interrupted_by_key"
target = "autopause_up_arrow"
keycode = 53
before_key_seconds = 1.0
after_key_seconds = 1.0
```
- [ ] Step 3: Query `auto_pause_minutes` immediately after the window closes and again 5 seconds later
confirm the two readings are identical (the hold did not keep advancing after the window closed).
```toml step
[[actions]]
use = "method-24.a"
setting = "auto_pause_minutes"
capture = "value_right_after_close"

[[actions]]
action = "shell"
command = "sleep 5"

[[actions]]
use = "method-24.a"
setting = "auto_pause_minutes"
expect = "$value_right_after_close"
```
- [ ] Step 4: Reopen Preferences (Device tab) and click the up arrow once, not held.
      Note `auto_pause_minutes` first, then confirm a plain CGEventPost click increased it by exactly 1 -- -- i.e. the arrow isn't stuck "held" from before.
```toml step
[[actions]]
use = "method-6"
item = "Settings..."

[[actions]]
use = "method-10"
tab = "Device"

[[actions]]
action = "sql_query"
query = "SELECT CAST(json_extract(setting_value, '$.minutes') AS INTEGER) FROM setting WHERE setting_name='auto_pause_minutes';"
capture = "value_before_final_click"

[[actions]]
action = "cgevent_click"
target = "autopause_up_arrow"
mode = "single"

[[actions]]
action = "wait_for_sql"
query = "SELECT CASE WHEN CAST(json_extract(setting_value, '$.minutes') AS INTEGER) = $value_before_final_click + 1 THEN 'incremented_by_one' ELSE setting_value END FROM setting WHERE setting_name='auto_pause_minutes';"
expect = "incremented_by_one"
timeout_seconds = 30
```
- [ ] Step 5: Close the Settings window
(reopened in Step 4) so the next checklist starts with no stray window open.
      [Method: Number 23](../Methods.md#method-23).
```toml step
use = "method-23"
```
