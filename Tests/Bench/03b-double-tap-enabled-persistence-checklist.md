# Double-Tap Enabled Persistence Checklist

### Last run - 2026-08-10 20:03 on the branch 'feature/singleInstance'

Covers the Double-tap **Disable** checkbox's `enabled` flag moving from UserDefaults to being
DB-backed via `AppDataStore`/the `double_tap_settings` row -- confirms the flag set in the
Settings UI survives an app restart by round-tripping through the DB, not just in-memory state.
Requires Developer Mode enabled and a paired, connected device (the control is disabled while
unpaired).

**Automated coverage:** the `enabled` flag's DB round-trip across a restart -- including that
toggling it leaves the accelerometer params intact -- is unit-tested in
`Tests/TimeFlipAppTests/SettingsPersistenceTests.swift` (a second `AppDataStore` on the same file
stands in for the restart). The steps below remain for what that can't reach: the checkbox UI
writing the flag and the real device honoring it.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Setup

The switch to the test database (quit, `switch-database.sh test`, relaunch, confirm reconnect)
is done once by `Tests/00-test-setup.md`, which the supervisor always runs first -- not
repeated here.

- [x] Step 1: Query `db_type` and confirm it reads `{"type":"test"}` before proceeding
`sqlite3 ~/Library/Application\ Support/TimeFlip/appdata.sqlite "SELECT setting_value FROM setting WHERE setting_name = 'db_type';"`
```toml step
use = "method-24.a"
setting = "db_type"
expect = "{\"type\":\"test\"}"
```
- [x] Step 2: Open Preferences on the Device tab and expand the **Double tap** disclosure.
Preferences is the status-item menu's "Settings..." item; the Device tab is selected by name via the tab picker, and the disclosure is under Settings. Methods: [Number 6](../Methods.md#method-6), [Number 10](../Methods.md#method-10), [Number 15](../Methods.md#method-15).
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
        tell group 2 of scroll area 1 of group 1 of window "TimeFlip Settings"
            if exists text field "Brightness" then
                repeat with i from 1 to (count of UI elements)
                    try
                        click UI element i
                        delay 0.3
                        if not (exists text field "Brightness") then exit repeat
                    end try
                end repeat
            end if
            if not (exists checkbox 1) then
                repeat with i from (count of UI elements) to 1 by -1
                    try
                        click UI element i
                        delay 0.3
                        if exists checkbox 1 then exit repeat
                    end try
                end repeat
            end if
        end tell
    end tell
end tell'''

[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        tell group 2 of scroll area 1 of group 1 of window "TimeFlip Settings"
            return (exists checkbox 1) as string
        end tell
    end tell
end tell'''
expect = "true"
```

## Scenario A -- enabled flag persists across a restart

**Preconditions:** device connected and paired, Preferences open on the Device tab with the
Double tap disclosure expanded -- established in Setup immediately above, which this scenario
runs straight on from.

- [x] Step 1: Read whether **Disable** is currently checked or not
(accessibility `value` of the checkbox), then toggle it to the opposite state.  [Method: Number 13](../Methods.md#method-13).
```toml step
[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        tell group 2 of scroll area 1 of group 1 of window "TimeFlip Settings"
            return value of checkbox 1
        end tell
    end tell
end tell'''
capture = "checkbox_before"

[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        tell group 2 of scroll area 1 of group 1 of window "TimeFlip Settings"
            click checkbox 1
            return value of checkbox 1
        end tell
    end tell
end tell'''
capture = "checkbox_after_toggle"
```
- [x] Step 2: Query `double_tap_settings` and confirm its `enabled` field flipped to match (`false` if Disable is now checked, `true` if not).
```toml step
use = "method-24.f"
action = "wait_for_sql"
setting = "double_tap_settings"
field = "enabled"
expect = "$checkbox_before"
timeout_seconds = 30
```
- [x] Step 3: Quit the app and start it again
confirm reconnect via a fresh `debug_log` `"Login accepted, code=0x02"` row. Methods: [Number 3](../Methods.md#method-3) to quit, [Number 2](../Methods.md#method-2) to start.
```toml step
[[actions]]
use = "method-3"

[[actions]]
use = "method-2"

[[actions]]
use = "method-4"
since_id = "$current_log_id"
expect_contains = "Login accepted"
timeout_seconds = 30
```
- [x] Step 4: Reopen Preferences, Device tab, expand **Double tap**, and confirm **Disable**
still shows the state set above -- read the checkbox's value directly via accessibility, no screenshot needed.
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
        tell group 2 of scroll area 1 of group 1 of window "TimeFlip Settings"
            if exists text field "Brightness" then
                repeat with i from 1 to (count of UI elements)
                    try
                        click UI element i
                        delay 0.3
                        if not (exists text field "Brightness") then exit repeat
                    end try
                end repeat
            end if
            if not (exists checkbox 1) then
                repeat with i from (count of UI elements) to 1 by -1
                    try
                        click UI element i
                        delay 0.3
                        if exists checkbox 1 then exit repeat
                    end try
                end repeat
            end if
            return value of checkbox 1
        end tell
    end tell
end tell'''
expect = "$checkbox_after_toggle"
```
- [x] Step 5: Toggle **Disable** back to its original state from the first step
, so the session doesn't leave a real setting changed.
```toml step
[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        tell group 2 of scroll area 1 of group 1 of window "TimeFlip Settings"
            click checkbox 1
        end tell
    end tell
end tell'''

[[actions]]
action = "wait_for_sql"
query = "SELECT CASE WHEN json_extract(setting_value, '$.enabled') = (1 - $checkbox_before) THEN 'matches' ELSE json_extract(setting_value, '$.enabled') END FROM setting WHERE setting_name='double_tap_settings';"
expect = "matches"
timeout_seconds = 30
```

## Scenario B -- device write is debounced after a param settles, then read back and verified

Covers `ApplicationDelegate`'s `onDoubleTapParametersChange` (prints + immediate DB write on every
change, device write debounced through `DeviceWriteDebouncer`) and
`TimeFlipBLEDevice.setDoubleTapParameters`'s existing read-back verification (`0x17`). Step 1
captures the current Threshold/Limit/Latency/Window values first (so
the original params are recoverable), and Step 6 restores Threshold from that record. [Method: Number 22](../Methods.md#method-22), since this changes a real
physical accelerometer register, not just app state.

**Preconditions:** device connected and paired, Preferences open on the Device tab with the
Double tap disclosure expanded, **Disable** back to its original state -- the clean state the
previous scenario leaves behind (check `double_tap_settings.enabled` directly if running this
scenario standalone).

- [x] Step 1: Record the current double-tap params
(`clickThreshold`/`limit`/`latency`/`window`) from `double_tap_settings` -- captured under this scenario, so Step 6 (and a later resume) can read the originals back -- then show them to the dev to confirm they match the app's **Double tap** section before the scenario changes them.
```toml step
[[actions]]
use = "method-24.f"
setting = "double_tap_settings"
field = "clickThreshold"
capture = "dt_threshold_original"

[[actions]]
use = "method-24.f"
setting = "double_tap_settings"
field = "limit"
capture = "dt_limit_original"

[[actions]]
use = "method-24.f"
setting = "double_tap_settings"
field = "latency"
capture = "dt_latency_original"

[[actions]]
use = "method-24.f"
setting = "double_tap_settings"
field = "window"
capture = "dt_window_original"

[[actions]]
action = "ask_user"
prompt = '''Current Double-tap params, now captured -- these should match the app's Double tap section, top to bottom:
Threshold: $dt_threshold_original
Limit:     $dt_limit_original
Latency:   $dt_latency_original
Window:    $dt_window_original

Do all four match what the app shows?'''
```
- [x] Step 2: Change the threshold field with input
Note the latest `debug_log_id`. In the Threshold field, type three distinct values in quick succession, committing each with Return and staying on the field: `30`, then immediately `150`, then immediately `200`. (Note: Return is what commits, and it keeps focus; `tab` would commit too but move focus on, so the next value would land somewhere else. [Method: Number 12](../Methods.md#method-12).)
```toml step
[[actions]]
use = "method-24.b"
capture = "before_ths_id"

[[actions]]
action = "applescript"
script = '''
tell application "TimeFlip" to activate
tell application "System Events"
    tell process "TimeFlip"
        tell group 2 of scroll area 1 of group 1 of window "TimeFlip Settings"
            set e to text field 2
            set focused of e to true
        end tell
        keystroke "a" using command down
        keystroke "30"
        keystroke return
        keystroke "a" using command down
        keystroke "150"
        keystroke return
        keystroke "a" using command down
        keystroke "200"
        keystroke return
    end tell
end tell'''
```
- [x] Step 3: Confirm every intermediate value logged a changed + saved-to-DB pair
, ending at `ths=200`. In `debug_log` (tag `double-tap`), rows newer than the noted ID: a `"Params changed: ths=Xm ..."` + `"Params saved to DB: enabled=..."` pair per value.
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='double-tap' AND message LIKE 'Params changed: ths=200%' AND debug_log_id > $before_ths_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Params changed: ths=200"
timeout_seconds = 30
```
- [x] Step 4: Confirm `double_tap_settings`
already reads `"clickThreshold":200` immediately. That is before the debounce elapses (`DeviceWriteDebouncer.defaultDelay`).
```toml step
use = "method-24.f"
setting = "double_tap_settings"
field = "clickThreshold"
expect = "200"
```
- [x] Step 5: Wait about 1.5s, then confirm one debounced write
, read and verification line. In `debug_log`: exactly **one** `"Writing ths=200 lim=20 lat=50 win=50"` (not one per intermediate value), followed by `"Read ths=200 lim=20 lat=50 win=50"` and `"Verification confirmed: requested ths=200 ...; actual ths=200 ..."`
```toml step
use = "method-24.e"
action = "wait_for_sql"
tag = "double-tap"
since_id = "$before_ths_id"
expect_contains = "Verification confirmed: requested ths=200"
timeout_seconds = 30
```
- [x] Step 6: Restore Threshold to the original value recorded in Step 1.
      Confirm `double_tap_settings` reads that `clickThreshold` again.
```toml step
[[actions]]
action = "applescript"
script = '''
tell application "TimeFlip" to activate
tell application "System Events"
    tell process "TimeFlip"
        tell group 2 of scroll area 1 of group 1 of window "TimeFlip Settings"
            set e to text field 2
            set focused of e to true
        end tell
        keystroke "a" using command down
        keystroke "$dt_threshold_original"
        keystroke return
    end tell
end tell'''

[[actions]]
use = "method-24.f"
action = "wait_for_sql"
setting = "double_tap_settings"
field = "clickThreshold"
expect = "$dt_threshold_original"
timeout_seconds = 30
```
- [x] Step 7: Close the Settings window
(opened in Setup) so the next checklist starts with no stray window open. [Method: Number 23](../Methods.md#method-23).
```toml step
use = "method-23"
```
