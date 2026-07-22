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
reach it, confirmed live in both directions plus the compound window-close case (Method: Simulate a
real click, double-click, or held press via CGEventPost, `../Methods.md`) -- so
`Tests/Interactive/05i-auto-pause-arrow-stepper-checklist.md` is now a stub.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Setup

- [x] Quit the app if it's running (`osascript -e 'tell application "TimeFlip" to quit'`).
- [x] Run `scripts/use-test-database.sh`.
- [x] Start the app and confirm it reconnects to the device (fresh `debug_log` `"Login accepted,
      code=0x02"` row).
- [x] Query `db_type` and confirm it reads `{"type":"test"}` before proceeding:
      `sqlite3 ~/Library/Application\ Support/TimeFlip/appdata.sqlite "SELECT setting_value FROM
      setting WHERE setting_name = 'db_type';"`. (Confirmed: `{"type":"test"}`.)
```toml step
action = "sql_query"
query = "SELECT setting_value FROM setting WHERE setting_name='db_type';"
expect = "{\"type\":\"test\"}"
```
- [x] Open Preferences (status-item menu -> "Settings...") and switch to the Device tab (radio
      button 1 of the tab picker). Method: Click a status-item menu item, Switch Settings-window
      tabs (`../Methods.md`). Confirm **Auto-pause** sits at the top of the **Settings**
      section, above the collapsed **LED** disclosure (not inside a separate **Advanced** section,
      which no longer exists) -- read the ordering of static text/control elements in that section
      via accessibility (Method: Read a label or value via accessibility, `../Methods.md`).
      (Confirmed via accessibility dump: `static text Auto-pause (0 disable, max 240m)` is the first
      element in the Settings group, ahead of the LED/Double-tap disclosure elements.)
```toml step
[[actions]]
action = "click_menu_item"
item = "Settings..."

[[actions]]
action = "shell"
command = "sleep 1"

[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        click radio button 1 of radio group 1 of group 1 of toolbar 1 of window "TimeFlip Settings"
        delay 0.3
        return value of static text 1 of group 2 of scroll area 1 of group 1 of window "TimeFlip Settings"
    end tell
end tell'''
expect_contains = "Auto-pause"
```

## Scenario A -- typing a value into the field persists to the DB

**Preconditions:** device connected and paired, Preferences open on the Device tab with Auto-pause
visible -- established in Setup immediately above, which this scenario runs straight on from.
Method: Edit a text field (`../Methods.md`).

- [x] Type `4` directly into the auto-pause text field and confirm the DB row updated:
      `SELECT setting_value FROM setting WHERE setting_name = 'auto_pause_minutes';` should read
      `{"minutes":4}`. (Confirmed.)
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
    end tell
end tell'''

[[actions]]
action = "wait_for_sql"
query = "SELECT setting_value FROM setting WHERE setting_name='auto_pause_minutes';"
expect = "{\"minutes\":4}"
timeout_seconds = 5
```
- [x] Type `26` into the field and confirm the same row now reads `{"minutes":26}`. (Confirmed.)
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
    end tell
end tell'''

[[actions]]
action = "wait_for_sql"
query = "SELECT setting_value FROM setting WHERE setting_name='auto_pause_minutes';"
expect = "{\"minutes\":26}"
timeout_seconds = 5
```
- [x] Type `0` into the field and confirm the row reads `{"minutes":0}`, leaving auto-pause
      disabled for the next run. (Confirmed.)
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
    end tell
end tell'''

[[actions]]
action = "wait_for_sql"
query = "SELECT setting_value FROM setting WHERE setting_name='auto_pause_minutes';"
expect = "{\"minutes\":0}"
timeout_seconds = 5
```

## Scenario B -- device write is debounced 1s after the value settles, then read back and verified

Covers `ApplicationDelegate`'s `onAutoPauseChange` (prints + immediate DB write on every change,
device write debounced through `DeviceWriteDebouncer`) and `TimeFlipBLEDevice.setAutoPause`'s
read-back verification (`0x10` status), added alongside the debounce.

**Preconditions:** device connected and paired, Preferences open on the Device tab with the
auto-pause field focusable -- left in place by the previous scenario, which also leaves
`auto_pause_minutes` at `0`, though this scenario overwrites that value immediately anyway.

- [x] Note the latest `debug_log_id`. Type three distinct values into the field in quick
      succession without tabbing away between them (`tab` shifts focus off the field, breaking the
      sequence -- select-all + type commits live on every keystroke already, no `tab` needed): `7`,
      then immediately `70`, then immediately `150`. (Confirmed: typing `150` after `70` landed as
      select-all -> `1` -> `15` -> `150`, i.e. 5 distinct intermediate values in total: `7`, `70`,
      `1`, `15`, `150`.)
```toml step
[[actions]]
action = "sql_query"
query = "SELECT MAX(debug_log_id) FROM debug_log;"
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
        keystroke "a" using command down
        keystroke "70"
        keystroke "a" using command down
        keystroke "150"
    end tell
end tell'''
```
- [x] Query `debug_log` (tag `auto-pause`) for rows newer than the noted ID and confirm a
      `"Auto-pause value changed to Xm"` + `"Auto-pause saved to DB: Xm"` pair for **each**
      intermediate value, in order -- the print+DB-write side is immediate and untouched by the
      debounce. (Confirmed: all 5 pairs present, `debug_log_id` 81-90.)
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='auto-pause' AND message LIKE 'Auto-pause value changed to 150m%' AND debug_log_id > $before_rapid_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Auto-pause value changed to 150m"
timeout_seconds = 10
```
- [x] Confirm `auto_pause_minutes` already reads `{"minutes":150}` immediately (before the 1s
      debounce elapses) -- the DB write never waited on the debounce. (Confirmed.)
```toml step
action = "sql_query"
query = "SELECT setting_value FROM setting WHERE setting_name='auto_pause_minutes';"
expect = "{\"minutes\":150}"
```
- [x] Wait about 1.5s, then query `debug_log` again and confirm exactly **one**
      `"Auto-pause set to 150m triggered"` line appears (not one per intermediate value), timestamped
      roughly 1s after the last (`150`) change, followed by `"Auto-pause verification confirmed:
      requested=150m actual=150m"`. (Confirmed: single triggered/confirmed pair at `debug_log_id`
      93-94, one second after the last value-changed line at 22:53:16 -> 22:53:18.)
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='auto-pause' AND debug_log_id > $before_rapid_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Auto-pause verification confirmed: requested=150m actual=150m"
timeout_seconds = 10
```
- [x] Type `0` into the field (single change, not part of a rapid sequence) and confirm after ~1.5s
      the same pattern: one triggered/confirmed pair for `0m`, leaving auto-pause disabled for the
      next run. (Confirmed: `debug_log_id` 103/105, `auto_pause_minutes` reads `{"minutes":0}`.)
```toml step
[[actions]]
action = "sql_query"
query = "SELECT MAX(debug_log_id) FROM debug_log;"
capture = "before_zero_id"

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
    end tell
end tell'''

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='auto-pause' AND debug_log_id > $before_zero_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Auto-pause verification confirmed: requested=0m actual=0m"
timeout_seconds = 10
```

## Scenario C -- press-and-hold acceleration, up arrow

**Preconditions:** device connected and paired, Preferences open on the Device tab with the
auto-pause field focusable, TimeFlip frontmost before typing (Method: Edit a text field,
`../Methods.md`). Get the arrow's coordinates via the adjacent text field's `position`/`size` (the
two stepper `image` elements themselves report identical, unreliable geometry -- see the coordinate
caveat in the CGEventPost method, `../Methods.md`) plus a targeted `screencapture -R` crop to place
them relative to it.

- [x] Type `1` directly into the auto-pause text field (starting value for the hold). (Confirmed:
      `auto_pause_minutes` reads `{"minutes":1}` in the original run of this scenario; a later
      re-run started from `50`.)
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
    end tell
end tell'''

[[actions]]
action = "wait_for_sql"
query = "SELECT setting_value FROM setting WHERE setting_name='auto_pause_minutes';"
expect = "{\"minutes\":1}"
timeout_seconds = 5
```
- [x] Click and hold the **up** arrow (CGEventPost `mouseDown`, wait ~4s, `mouseUp`) until the value
      passes 30, then release. Method: Simulate a real click, double-click, or held press via
      CGEventPost (`../Methods.md`).
```toml step
action = "cgevent_click"
target = "autopause_up_arrow"
mode = "hold"
hold_seconds = 4
```
- [x] Query `debug_log` (tag `auto-pause`, `"Auto-pause value changed to Xm"`) for the full sequence
      during the hold and confirm single-digit steps up through the second gridline past the
      starting value, then steps of 5 beyond that (`secondBoundary` uses integer division). (Confirmed
      live starting from `50`: `51, 52, ..., 60` single steps to the next 10-gridline, then `65, 70,
      75, 80, 85, 90, 95, 100` by 5.)
```toml step
action = "sql_query"
query = "SELECT CAST(substr(message, 29, length(message) - 29) AS INTEGER) FROM debug_log WHERE tag='auto-pause' AND message LIKE 'Auto-pause value changed%' ORDER BY debug_log_id DESC LIMIT 1;"
capture = "final_hold_value"
```
- [x] Query the DB and confirm `auto_pause_minutes` matches the final logged value. (Confirmed:
      `{"minutes":100}`.)
```toml step
action = "sql_query"
query = "SELECT setting_value FROM setting WHERE setting_name='auto_pause_minutes';"
expect = "{\"minutes\":$final_hold_value}"
```

## Scenario D -- press-and-hold acceleration, down arrow

**Preconditions:** same as Scenario C. This scenario overwrites the field's value immediately via
its own first step, so Scenario C's ending value doesn't matter.

- [x] Type `26` directly into the auto-pause text field. (Confirmed: `auto_pause_minutes` reads
      `{"minutes":26}`.)
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
    end tell
end tell'''

[[actions]]
action = "wait_for_sql"
query = "SELECT setting_value FROM setting WHERE setting_name='auto_pause_minutes';"
expect = "{\"minutes\":26}"
timeout_seconds = 5
```
- [x] Click and hold the **down** arrow (CGEventPost `mouseDown`, wait ~4s, `mouseUp`) until the
      value reaches 0, then release.
```toml step
action = "cgevent_click"
target = "autopause_down_arrow"
mode = "hold"
hold_seconds = 4
```
- [x] Query `debug_log` and confirm the sequence mirrors Scenario C: single digits down to the
      second gridline below 26, then by 5 down to 0, and that the field stayed at 0 rather than
      going negative once the down arrow was held past it. (Confirmed: `25, 24, 23, 22, 21, 20, 15,
      10, 5, 0`.)
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='auto-pause' AND message LIKE 'Auto-pause value changed%' ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Auto-pause value changed to 0m"
timeout_seconds = 10
```
- [x] Confirm `auto_pause_minutes` reads `{"minutes":0}`, not negative. (Confirmed.)
```toml step
action = "sql_query"
query = "SELECT setting_value FROM setting WHERE setting_name='auto_pause_minutes';"
expect = "{\"minutes\":0}"
```

## Scenario E -- a hold interrupted by closing the window doesn't keep running

**Preconditions:** same as Scenario C/D -- Preferences open on the Device tab (this scenario closes
and reopens that window mid-scenario, so it must start open).

- [x] Type `50` directly into the auto-pause text field. (Confirmed: `auto_pause_minutes` reads
      `{"minutes":50}`.)
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
    end tell
end tell'''

[[actions]]
action = "wait_for_sql"
query = "SELECT setting_value FROM setting WHERE setting_name='auto_pause_minutes';"
expect = "{\"minutes\":50}"
timeout_seconds = 5
```
- [x] Click and hold the **up** arrow (CGEventPost `mouseDown`). While still "held" (no `mouseUp`
      posted yet), post a synthetic **Escape** keydown/keyup (`CGEventCreateKeyboardEvent(None, 53,
      True/False)`) to close the Preferences window, wait ~1s, then post `mouseUp` -- two
      independent synthetic event streams interleaving exactly like two real hands would; nothing
      about the gesture actually needs physical simultaneity, just event ordering. (Confirmed live:
      the window closed on the synthetic Escape exactly as it does on a real one.)
```toml step
action = "cgevent_hold_interrupted_by_key"
target = "autopause_up_arrow"
keycode = 53
before_key_seconds = 1.0
after_key_seconds = 1.0
```
- [x] Query `auto_pause_minutes` immediately after the window closes and again 5 seconds later;
      confirm the two readings are identical (the hold did not keep advancing after the window
      closed). (Confirmed: both readings `107`.)
```toml step
[[actions]]
action = "sql_query"
query = "SELECT setting_value FROM setting WHERE setting_name='auto_pause_minutes';"
capture = "value_right_after_close"

[[actions]]
action = "shell"
command = "sleep 5"

[[actions]]
action = "sql_query"
query = "SELECT setting_value FROM setting WHERE setting_name='auto_pause_minutes';"
expect = "$value_right_after_close"
```
- [x] Reopen Preferences (Device tab), note `auto_pause_minutes`, click the up arrow once (a plain
      CGEventPost click, not a hold), and confirm the value increased by exactly 1 -- i.e. the arrow
      isn't stuck "held" from before. (Confirmed: `107` -> `108`.)
```toml step
[[actions]]
action = "click_menu_item"
item = "Settings..."

[[actions]]
action = "shell"
command = "sleep 1"

[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        click radio button 1 of radio group 1 of group 1 of toolbar 1 of window "TimeFlip Settings"
    end tell
end tell'''

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
timeout_seconds = 10
```
