# LED Settings Persistence Checklist

### Last run - 2026-08-10 17:24 on the branch 'bugfix/pairingProbeSettle'

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

The switch to the test database (quit, `switch-database.sh test`, relaunch, confirm reconnect)
is done once by `Tests/00-test-setup.md`, which the supervisor always runs first -- not
repeated here.

- [x] Step 1: Query `db_type` and confirm it reads `{"type":"test"}`
before proceeding: `sqlite3 ~/Library/Application\ Support/TimeFlip/appdata.sqlite "SELECT setting_value FROM setting WHERE setting_name = 'db_type';"`
```toml step
use = "method-24.a"
setting = "db_type"
expect = "{\"type\":\"test\"}"
```
- [x] Step 2: Open Preferences on the Device tab and expand the **LED** disclosure.
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

- [x] Step 1: Set Brightness to `77` and Blink Interval to `42` by typing directly into their fields.
      Each value needs a Return after it to commit -- a `SteppedNumberField` writes nothing until Return or focus loss, so typing alone leaves the DB untouched. [Method: Number 12](../Methods.md#method-12).
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
        keystroke return
        tell group 2 of scroll area 1 of group 1 of window "TimeFlip Settings"
            set e2 to text field "Blink Interval"
            set focused of e2 to true
        end tell
        keystroke "a" using command down
        keystroke "42"
        keystroke return
    end tell
end tell'''
```
- [x] Step 2: Query `led_settings` and confirm it reads `{"brightness":77,"blink_interval":42}`
```toml step
action = "wait_for_sql"
query = "SELECT CASE WHEN setting_value LIKE '%\"brightness\":77%' AND setting_value LIKE '%\"blink_interval\":42%' THEN 'matches' ELSE setting_value END FROM setting WHERE setting_name='led_settings';"
expect = "matches"
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
- [x] Step 4: Reopen Preferences, Device tab, expand **LED**
, and confirm Brightness still shows `77` and Blink Interval still shows `42` -- read both fields' values directly via accessibility, no screenshot needed.
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
- [x] Step 5: Query `led_settings` again and confirm it's unchanged.
      The restart's startup sync re-applies the stored value to the device but doesn't alter the stored row.
```toml step
action = "sql_query"
query = "SELECT CASE WHEN setting_value LIKE '%\"brightness\":77%' AND setting_value LIKE '%\"blink_interval\":42%' THEN 'matches' ELSE setting_value END FROM setting WHERE setting_name='led_settings';"
expect = "matches"
```

## Scenario B -- device write is debounced 1s after the value settles, with no read-back verification

Covers `ApplicationDelegate`'s `onLEDBrightnessChange`/`onBlinkIntervalChange` (prints + immediate
DB write on every change, device write debounced through `DeviceWriteDebouncer`) and
`TimeFlipBLEDevice.setLEDBrightness`/`setBlinkInterval` Unlike auto-pause/double-tap, the BLE
protocol has no read-back command for LED brightness (`0x09`) or blink interval (`0x0A`) at all, so
these log that the write happened with no verification, rather than a fabricated confirm/mismatch.

**Preconditions:** device connected and paired, Preferences open on the Device tab with the LED
disclosure expanded, Brightness/Blink Interval at `77`/`42` -- the clean state the previous
scenario leaves behind (check `led_settings` directly if running this scenario standalone).

- [x] Step 1: Change Brightness field, in quick succession: `10`, then immediately `50`, then immediately `95`
```toml step
[[actions]]
use = "method-24.b"
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
        keystroke return
        keystroke "a" using command down
        keystroke "50"
        keystroke return
        keystroke "a" using command down
        keystroke "95"
        keystroke return
    end tell
end tell'''
```
- [x] Step 2: Confirm **each** intermediate brightness value logged a changed + saved pair, in order.
In `debug_log` (tag `led-bright`), rows newer than the noted ID: a `"Brightness value changed to X%"` + `"Brightness saved to DB: X%"` pair per value. Asserted as the whole ordered run, not just the final value -- checking only `95` would pass on a sequence that committed once instead of three times, which is exactly what happens without the `return` after each value.
```toml step
action = "wait_for_sql"
query = "SELECT group_concat(message, ' | ') FROM (SELECT message FROM debug_log WHERE tag='led-bright' AND (message LIKE 'Brightness value changed%' OR message LIKE 'Brightness saved to DB%') AND debug_log_id > $before_brightness_id ORDER BY debug_log_id);"
expect_contains = "Brightness value changed to 10% | Brightness saved to DB: 10% | Brightness value changed to 50% | Brightness saved to DB: 50% | Brightness value changed to 95% | Brightness saved to DB: 95%"
timeout_seconds = 30
```
- [x] Step 3: Confirm `led_settings` already reads `"brightness":95`
immediately (before the 1s debounce elapses).
```toml step
use = "method-24.a"
setting = "led_settings"
expect_contains = "\"brightness\":95"
```
- [x] Step 4: Confirm one debounced triggered line and the write after it
after about 1.5s. In `debug_log`: exactly **one** `"Brightness set to 95% triggered"` (not one per intermediate value), followed immediately by `"Brightness written to 95% (no device read-back available)"` -- -- no confirmed/MISMATCH line, since the protocol has no brightness read-back.
```toml step
use = "method-24.e"
action = "wait_for_sql"
tag = "led-bright"
since_id = "$before_brightness_id"
expect_contains = "Brightness written to 95% (no device read-back available)"
timeout_seconds = 30
```
- [x] Step 5: Repeat the same rapid-sequence test on the Blink Interval
field (`8`, then `25`, then `55`) and confirm the identical pattern:
every intermediate value printed+DB-saved immediately, one debounced `"Blink interval set to 55s triggered"` + `"Blink interval written to 55s (no device read-back available)"` pair about 1s later.
```toml step
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
        keystroke return
        keystroke "a" using command down
        keystroke "25"
        keystroke return
        keystroke "a" using command down
        keystroke "55"
        keystroke return
    end tell
end tell'''

[[actions]]
action = "wait_for_sql"
query = "SELECT group_concat(message, ' | ') FROM (SELECT message FROM debug_log WHERE tag='led-blink' AND (message LIKE 'Blink interval value changed%' OR message LIKE 'Blink interval saved to DB%') AND debug_log_id > $current_log_id ORDER BY debug_log_id);"
expect_contains = "Blink interval value changed to 8s | Blink interval saved to DB: 8s | Blink interval value changed to 25s | Blink interval saved to DB: 25s | Blink interval value changed to 55s | Blink interval saved to DB: 55s"
timeout_seconds = 30

[[actions]]
use = "method-24.e"
action = "wait_for_sql"
tag = "led-blink"
since_id = "$current_log_id"
expect_contains = "Blink interval written to 55s (no device read-back available)"
timeout_seconds = 30
```
- [x] Step 6: Restore Brightness to `77` and Blink Interval to `42`
Those are the values from the persistence scenario above. Confirm `led_settings` reads `{"brightness":77,"blink_interval":42}` again, so the session doesn't leave a real setting changed.
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
        keystroke return
        tell group 2 of scroll area 1 of group 1 of window "TimeFlip Settings"
            set e2 to text field "Blink Interval"
            set focused of e2 to true
        end tell
        keystroke "a" using command down
        keystroke "42"
        keystroke return
    end tell
end tell'''

[[actions]]
action = "wait_for_sql"
query = "SELECT CASE WHEN setting_value LIKE '%\"brightness\":77%' AND setting_value LIKE '%\"blink_interval\":42%' THEN 'matches' ELSE setting_value END FROM setting WHERE setting_name='led_settings';"
expect = "matches"
timeout_seconds = 30
```
- [x] Step 7: Close the Settings window
(opened in Setup) so the next checklist starts with no stray window open.
      [Method: Number 23](../Methods.md#method-23).
```toml step
use = "method-23"
```
