# Double-Tap Enabled Persistence Checklist

### Last run - 2026-07-22 on the branch 'feature/projects'

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

The switch to the test database (quit, `use-test-database.sh`, relaunch, confirm reconnect)
is done once by `Tests/00-test-setup.md`, which the supervisor always runs first -- not
repeated here.

- [ ] Step 1: Query `db_type` and confirm it reads `{"type":"test"}` before proceeding:
      `sqlite3 ~/Library/Application\ Support/TimeFlip/appdata.sqlite "SELECT setting_value FROM
      setting WHERE setting_name = 'db_type';"`. (Confirmed: `{"type":"test"}`.)
```toml step
action = "sql_query"
query = "SELECT setting_value FROM setting WHERE setting_name='db_type';"
expect = "{\"type\":\"test\"}"
```
- [ ] Step 2: Open Preferences (status-item menu -> "Settings...") and switch to the Device tab (radio
      button 1 of the tab picker), then expand the **Double tap** disclosure under Settings. Method:
      Click a status-item menu item, Switch Settings-window tabs, Expand or collapse a disclosure
      group (`../Methods.md`). (Confirmed: Disable checkbox + Threshold/Limit/Latency/Window fields
      visible.)
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

- [ ] Step 1: Read whether **Disable** is currently checked or not (accessibility `value` of the checkbox),
      then toggle it to the opposite state. Method: Click a button, checkbox, or slider
      (`../Methods.md`). (Confirmed: was unchecked (`value=0`), toggled to checked.)
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
- [ ] Step 2: Query `double_tap_settings` and confirm its `enabled` field flipped to match (`false` if
      Disable is now checked, `true` if not). (Confirmed: `enabled=false`.)
```toml step
action = "wait_for_sql"
query = "SELECT json_extract(setting_value, '$.enabled') FROM setting WHERE setting_name='double_tap_settings';"
expect = "$checkbox_before"
timeout_seconds = 5
```
- [ ] Step 3: Quit the app and start it again; confirm reconnect via a fresh `debug_log` `"Login accepted,
      code=0x02"` row. (Confirmed.)
```toml step
[[actions]]
action = "sql_query"
query = "SELECT MAX(debug_log_id) FROM debug_log;"
capture = "before_quit_id"

[[actions]]
action = "shell"
command = "osascript -e 'tell application \"TimeFlip\" to quit'"

[[actions]]
action = "shell"
command = "nohup ./.build/bundler/apps/TimeFlip/TimeFlip.app/Contents/MacOS/TimeFlip > /dev/null 2>&1 &"

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Login accepted%' AND debug_log_id > $before_quit_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Login accepted"
timeout_seconds = 30
```
- [ ] Step 4: Reopen Preferences, Device tab, expand **Double tap**, and confirm **Disable** still shows the
      state set above -- read the checkbox's value directly via accessibility, no screenshot
      needed. (Confirmed: `value=1`, still checked.)
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
- [ ] Step 5: Toggle **Disable** back to its original state from the first step, so the session doesn't
      leave a real setting changed. (Confirmed: `double_tap_settings.enabled` back to `true`.)
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
timeout_seconds = 5
```

## Scenario B -- device write is debounced 1s after a param settles, then read back and verified

Covers `ApplicationDelegate`'s `onDoubleTapParametersChange` (prints + immediate DB write on every
change, device write debounced through `DeviceWriteDebouncer`) and
`TimeFlipBLEDevice.setDoubleTapParameters`'s existing read-back verification (`0x17`). Snapshot the
current Threshold/Limit/Latency/Window values in `device_register_snapshot.json` first. Method:
Suppress incidental double-taps during a session (`../Methods.md`), since this changes a real
physical accelerometer register, not just app state.

**Preconditions:** device connected and paired, Preferences open on the Device tab with the
Double tap disclosure expanded, **Disable** back to its original state -- the clean state the
previous scenario leaves behind (check `double_tap_settings.enabled` directly if running this
scenario standalone).

- [ ] Step 1: Snapshot the current values (`clickThreshold`/`limit`/`latency`/`window`) into
      `Tests/Bench/device_register_snapshot.json` under a timestamp-keyed
      `double_tap_params_as_at` object. (Snapshotted `ths=90 lim=20 lat=50 win=50`.)
- [ ] Step 2: Note the latest `debug_log_id`. In the Threshold field, type three distinct values in quick
      succession without tabbing away between them: `30`, then immediately `150`, then immediately
      `200`.
```toml step
[[actions]]
action = "sql_query"
query = "SELECT MAX(debug_log_id) FROM debug_log;"
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
        keystroke "a" using command down
        keystroke "150"
        keystroke "a" using command down
        keystroke "200"
    end tell
end tell'''
```
- [ ] Step 3: Query `debug_log` (tag `double-tap`) for rows newer than the noted ID and confirm a `"Params
      changed: ths=Xm ..."` + `"Params saved to DB: enabled=..."` pair for every intermediate
      value, ending at `ths=200`. (Confirmed: many intermediate pairs -- `numericField`'s
      get/set binding chain fires more than once per keystroke, an existing quirk unrelated to the
      debounce -- but the DB and final value are correct throughout.)
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='double-tap' AND message LIKE 'Params changed: ths=200%' AND debug_log_id > $before_ths_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Params changed: ths=200"
timeout_seconds = 10
```
- [ ] Step 4: Confirm `double_tap_settings` already reads `"clickThreshold":200` immediately (before the 1s
      debounce elapses). (Confirmed.)
```toml step
action = "sql_query"
query = "SELECT json_extract(setting_value, '$.clickThreshold') FROM setting WHERE setting_name='double_tap_settings';"
expect = "200"
```
- [ ] Step 5: Wait about 1.5s, then query `debug_log` again and confirm exactly **one** `"Writing ths=200
      lim=20 lat=50 win=50"` line (not one per intermediate value), followed by `"Read ths=200
      lim=20 lat=50 win=50"` and `"Verification confirmed: requested ths=200 ...; actual ths=200
      ..."`. (Confirmed: `debug_log_id` 184-186.)
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='double-tap' AND debug_log_id > $before_ths_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Verification confirmed: requested ths=200"
timeout_seconds = 10
```
- [ ] Step 6: Restore Threshold to the original value noted in the snapshot (`90`) and confirm
      `double_tap_settings` reads `"clickThreshold":90` again. (Confirmed.)
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
        keystroke "90"
    end tell
end tell'''

[[actions]]
action = "wait_for_sql"
query = "SELECT json_extract(setting_value, '$.clickThreshold') FROM setting WHERE setting_name='double_tap_settings';"
expect = "90"
timeout_seconds = 5
```
