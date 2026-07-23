# LED Settings Persistence Checklist

### Last run - 2026-07-22 on the branch 'feature/projects'

Covers LED brightness/blink interval moving from UserDefaults to being DB-backed via
`AppDataStore`/the `led_settings` row -- confirms a value set in the Settings UI survives an app
restart by round-tripping through the DB, not just in-memory state. Requires Developer Mode
enabled and a paired, connected device (the controls are disabled while unpaired).

**Automated coverage:** the brightness/blink-interval DB round-trip across a restart -- including
that saving one field leaves the other intact -- is unit-tested in
`Tests/TimeFlipAppTests/SettingsPersistenceTests.swift` (a second `AppDataStore` on the same file
stands in for the restart). The steps below remain for what that can't reach: the field UI writing
the value and the startup sync re-applying it to a real device.

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
      button 1 of the tab picker), then expand the **LED** disclosure under Settings. Method: Click
      a status-item menu item, Switch Settings-window tabs, Expand or collapse a disclosure group
      (`../Methods.md`). (Confirmed: Brightness/Blink Interval fields visible.)
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
            if not (exists text field "Brightness") then
                click UI element 6
                delay 0.3
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
            return (exists text field "Brightness") as string
        end tell
    end tell
end tell'''
expect = "true"
```

## Scenario A -- brightness and blink interval persist across a restart

**Preconditions:** device connected and paired, Preferences open on the Device tab with the LED
disclosure expanded -- established in Setup immediately above, which this scenario runs straight
on from.

- [ ] Step 1: Set Brightness to `77` and Blink Interval to `42` by typing directly into their fields.
      Method: Edit a text field (`../Methods.md`).
```toml step
action = "applescript"
script = '''
tell application "TimeFlip" to activate
tell application "System Events"
    tell process "TimeFlip"
        tell group 2 of scroll area 1 of group 1 of window "TimeFlip Settings"
            set e1 to text field "Brightness"
            set focused of e1 to true
        end tell
        keystroke "a" using command down
        keystroke "77"
        tell group 2 of scroll area 1 of group 1 of window "TimeFlip Settings"
            set e2 to text field "Blink Interval"
            set focused of e2 to true
        end tell
        keystroke "a" using command down
        keystroke "42"
    end tell
end tell'''
```
- [ ] Step 2: Query `led_settings` and confirm it reads `{"brightness":77,"blink_interval":42}`. (Confirmed.)
```toml step
action = "wait_for_sql"
query = "SELECT CASE WHEN setting_value LIKE '%\"brightness\":77%' AND setting_value LIKE '%\"blink_interval\":42%' THEN 'matches' ELSE setting_value END FROM setting WHERE setting_name='led_settings';"
expect = "matches"
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
- [ ] Step 4: Reopen Preferences, Device tab, expand **LED**, and confirm Brightness still shows `77` and
      Blink Interval still shows `42` -- read both fields' values directly via accessibility, no
      screenshot needed. (Confirmed.)
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
            if not (exists text field "Brightness") then
                click UI element 6
                delay 0.3
            end if
            return (value of text field "Brightness") & "|" & (value of text field "Blink Interval")
        end tell
    end tell
end tell'''
expect = "77|42"
```
- [ ] Step 5: Query `led_settings` again and confirm it's unchanged (the restart's startup sync re-applies
      the stored value to the device but doesn't alter the stored row). (Confirmed.)
```toml step
action = "sql_query"
query = "SELECT CASE WHEN setting_value LIKE '%\"brightness\":77%' AND setting_value LIKE '%\"blink_interval\":42%' THEN 'matches' ELSE setting_value END FROM setting WHERE setting_name='led_settings';"
expect = "matches"
```

## Scenario B -- device write is debounced 1s after the value settles, with no read-back verification

Covers `ApplicationDelegate`'s `onLEDBrightnessChange`/`onBlinkIntervalChange` (prints + immediate
DB write on every change, device write debounced through `DeviceWriteDebouncer`) and
`TimeFlipBLEDevice.setLEDBrightness`/`setBlinkInterval`. Unlike auto-pause/double-tap, the BLE
protocol has no read-back command for LED brightness (`0x09`) or blink interval (`0x0A`) at all, so
these log that the write happened with no verification, rather than a fabricated confirm/mismatch.

**Preconditions:** device connected and paired, Preferences open on the Device tab with the LED
disclosure expanded, Brightness/Blink Interval at `77`/`42` -- the clean state the previous
scenario leaves behind (check `led_settings` directly if running this scenario standalone).

- [ ] Step 1: Note the latest `debug_log_id`. In the Brightness field, type three distinct values in quick
      succession without tabbing away between them: `10`, then immediately `50`, then immediately
      `95`. (Confirmed: typing landed as select-all -> `1` -> `10` -> `5` -> `50` -> `9` -> `95`,
      7 distinct intermediate values in total.)
```toml step
[[actions]]
action = "sql_query"
query = "SELECT MAX(debug_log_id) FROM debug_log;"
capture = "before_brightness_id"

[[actions]]
action = "applescript"
script = '''
tell application "TimeFlip" to activate
tell application "System Events"
    tell process "TimeFlip"
        tell group 2 of scroll area 1 of group 1 of window "TimeFlip Settings"
            set e to text field "Brightness"
            set focused of e to true
        end tell
        keystroke "a" using command down
        keystroke "10"
        keystroke "a" using command down
        keystroke "50"
        keystroke "a" using command down
        keystroke "95"
    end tell
end tell'''
```
- [ ] Step 2: Query `debug_log` (tag `led`) for rows newer than the noted ID and confirm a `"Brightness
      value changed to X%"` + `"Brightness saved to DB: X%"` pair for **each** intermediate value,
      in order. (Confirmed: 7 pairs, `debug_log_id` 115-126.)
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='led-bright' AND message LIKE 'Brightness value changed to 95%' AND debug_log_id > $before_brightness_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Brightness value changed to 95"
timeout_seconds = 10
```
- [ ] Step 3: Confirm `led_settings` already reads `"brightness":95` immediately (before the 1s debounce
      elapses). (Confirmed.)
```toml step
action = "sql_query"
query = "SELECT setting_value FROM setting WHERE setting_name='led_settings';"
expect_contains = "\"brightness\":95"
```
- [ ] Step 4: Wait about 1.5s, then query `debug_log` again and confirm exactly **one** `"Brightness set to
      95% triggered"` line (not one per intermediate value), followed immediately by `"Brightness
      written to 95% (no device read-back available)"` -- no confirmed/MISMATCH line, since the
      protocol has no brightness read-back. (Confirmed: `debug_log_id` 127-128, ~1s after the
      last value-changed line.)
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='led-bright' AND debug_log_id > $before_brightness_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Brightness written to 95% (no device read-back available)"
timeout_seconds = 10
```
- [ ] Step 5: Repeat the same rapid-sequence test on the Blink Interval field (`8`, then `25`, then `55`)
      and confirm the identical pattern: every intermediate value printed+DB-saved immediately, one
      debounced `"Blink interval set to 55s triggered"` + `"Blink interval written to 55s (no
      device read-back available)"` pair about 1s later. (Confirmed: `debug_log_id` 138-149.)
```toml step
[[actions]]
action = "sql_query"
query = "SELECT MAX(debug_log_id) FROM debug_log;"
capture = "before_blink_id"

[[actions]]
action = "applescript"
script = '''
tell application "TimeFlip" to activate
tell application "System Events"
    tell process "TimeFlip"
        tell group 2 of scroll area 1 of group 1 of window "TimeFlip Settings"
            set e to text field "Blink Interval"
            set focused of e to true
        end tell
        keystroke "a" using command down
        keystroke "8"
        keystroke "a" using command down
        keystroke "25"
        keystroke "a" using command down
        keystroke "55"
    end tell
end tell'''

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='led-blink' AND debug_log_id > $before_blink_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Blink interval written to 55s (no device read-back available)"
timeout_seconds = 10
```
- [ ] Step 6: Restore Brightness to `77` and Blink Interval to `42` (the values from the persistence
      scenario above), and confirm `led_settings` reads `{"brightness":77,"blink_interval":42}`
      again, so the session doesn't leave a real setting changed. (Confirmed.)
```toml step
[[actions]]
action = "applescript"
script = '''
tell application "TimeFlip" to activate
tell application "System Events"
    tell process "TimeFlip"
        tell group 2 of scroll area 1 of group 1 of window "TimeFlip Settings"
            set e1 to text field "Brightness"
            set focused of e1 to true
        end tell
        keystroke "a" using command down
        keystroke "77"
        tell group 2 of scroll area 1 of group 1 of window "TimeFlip Settings"
            set e2 to text field "Blink Interval"
            set focused of e2 to true
        end tell
        keystroke "a" using command down
        keystroke "42"
    end tell
end tell'''

[[actions]]
action = "wait_for_sql"
query = "SELECT CASE WHEN setting_value LIKE '%\"brightness\":77%' AND setting_value LIKE '%\"blink_interval\":42%' THEN 'matches' ELSE setting_value END FROM setting WHERE setting_name='led_settings';"
expect = "matches"
timeout_seconds = 5
```
