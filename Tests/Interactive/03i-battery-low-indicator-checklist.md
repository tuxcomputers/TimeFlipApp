# Low-Battery Indicator Checklist (Interactive)

### Last run - 2026-07-22 on the branch 'feature/projects'

The visual half of the low-battery test: confirming the menu-bar activity name and the Battery line
on the Device tab actually *flash* in lockstep, and that clicking the left side of the status item
while low jumps straight to Settings (Device tab) instead of opening the dropdown menu. None of this
is machine-readable (the menu-bar item is a custom-drawn status item; the flash is a color animation,
not text/state; the left-side click depends on real click-position data a synthetic click doesn't
carry -- same limitation as the status-item gestures in `../Methods.md`), so a person has to watch
and click. The `isLowBattery` latch logic, hysteresis, and forced-Device-tab selection are all
covered by `Tests/Bench/03b-battery-low-indicator-checklist.md` and its unit tests; this file only
adds eyes on the rendering and the left-click behavior.

**Design changed live during this checklist's run** (see Bugs found and fixed below): the
"Settings..." dropdown menu item no longer flashes red/white -- it was originally meant to, but
`NSMenuItem` doesn't reliably repaint an already-open menu's row after a highlight change (confirmed
live: hovering it on/off eventually froze it on a stale color, permanently, until the menu was closed
and reopened). Rather than keep fighting that AppKit limitation, the design changed to: a static red
"Settings..." label was tried first, then abandoned in favor of skipping the menu entirely --
clicking the left side of the status item while low battery is active now opens Settings (Device tab)
directly, so the dropdown (and its "Settings..." item) is never seen in that state at all.

Run **after** the bench file, which restores the threshold at the end -- so this file re-triggers
the low state itself, then restores it again. Requires the test DB active (`db_type` = `test`) and a
paired, connected device.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Scenario A -- re-trigger the low-battery state

**Preconditions:** device connected, threshold at its real default (5%), not currently in a
low-battery state -- the clean state the Bench run's own restore leaves behind. Check via the
query below; if it shows a non-default threshold or `isLowBattery=true` left over from an
interrupted prior run, restore the threshold to 5% and restart the app before continuing.

- [ ] **(Claude)** Step 1: Query the current threshold and the most recent `battery` `level`, and note both
      in the logs/00-remembered.json file.
```toml step
[[actions]]
action = "sql_query"
query = "SELECT setting_value FROM setting WHERE setting_name='low_battery_level';"
capture = "threshold_original"
remember = "changed"
restores = "low_battery_level"

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='battery' AND message NOT LIKE 'level=nil%' ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "level="
timeout_seconds = 15

[[actions]]
action = "sql_query"
query = "SELECT CAST(substr(message, 7, instr(message, ' threshold') - 7) AS INTEGER) FROM debug_log WHERE tag='battery' AND message NOT LIKE 'level=nil%' ORDER BY debug_log_id DESC LIMIT 1;"
capture = "battery_level_a"
```
- [ ] **(Claude)** Step 2: Quit the app. Method: Quit the app (`../Methods.md`).
```toml step
[[actions]]
action = "sql_query"
query = "SELECT MAX(debug_log_id) FROM debug_log;"
capture = "before_quit_id"

[[actions]]
action = "shell"
command = "osascript -e 'tell application \"TimeFlip\" to quit'"
```
- [ ] **(Claude)** Step 3: Update `low_battery_level` to at/above the live level noted above, so the fresh
      connection registers as low immediately: `sqlite3 ~/Library/Application\ Support/TimeFlip/appdata.sqlite
      "UPDATE setting SET setting_value = '{\"percent\":<level>}' WHERE setting_name =
      'low_battery_level';"`. (Set to 25%.)
```toml step
action = "sql_exec"
query = "UPDATE setting SET setting_value = '{\"percent\":$battery_level_a}' WHERE setting_name = 'low_battery_level';"
```
- [ ] **(Claude)** Step 4: Start the app and confirm it reconnects to the device (fresh `debug_log`
      `"Login accepted, code=0x02"` row).
```toml step
[[actions]]
action = "shell"
command = "nohup ./.build/bundler/apps/TimeFlip/TimeFlip.app/Contents/MacOS/TimeFlip > /dev/null 2>&1 &"

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Login accepted%' AND debug_log_id > $before_quit_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Login accepted"
timeout_seconds = 30
```
- [ ] **(Claude)** Step 5: Query `debug_log` and confirm a `battery` row logged after the restart shows
      `isLowBattery=true`, so the visual checks below are being made while the app really is in the
      low state.
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='battery' AND debug_log_id > $before_quit_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "isLowBattery=true"
timeout_seconds = 15
```

## Scenario B -- confirm the flashing and the left-click-skips-the-menu behavior

**Preconditions:** currently in the low-battery state the previous section triggered
(`isLowBattery=true`) -- confirmed by that section's own final query above; re-check it directly
if running this section standalone rather than straight after.

- [ ] **(You)** Step 1: Confirm the activity name (left side of the menu bar item) is blinking red/white.
- [ ] **(You)** Step 2: Click the **left side** of the status item (the icon + activity name, not the
      duration/timer side) and confirm it opens Settings **directly on the Device tab** -- not the
      dropdown menu.
- [ ] **(Claude)** Step 3: Confirm via accessibility that the Device tab is selected (radio button 1 of the
      tab picker reads `value = 1`).
```toml step
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        return value of radio button 1 of radio group 1 of group 1 of toolbar 1 of window "TimeFlip Settings"
    end tell
end tell'''
expect = "1"
```
- [ ] **(You)** Step 4: Confirm the "Battery" line on the Device tab -- both the **label** and the
      percentage value -- is flashing red/default in sync with the menu bar blink.

### Bugs found and fixed - branch 'feature/projects'
2026-07-22 - The "Settings..." dropdown menu item's blink would freeze permanently after hovering
on/off it a few times (`NSMenuItem` doesn't reliably repaint an open menu's row after a highlight
change); a custom-view redraw workaround reduced but didn't eliminate the race. Fixed by dropping
the blink there entirely -- clicking the left side of the status item while low battery now opens
Settings directly on the Device tab instead of showing the menu at all.

## Scenario C -- restore and confirm it all stops

**Preconditions:** still in the low-battery state, both elements still flashing (the previous
section's own state, unchanged) -- so there's something real to restore and confirm stops.

- [ ] **(Claude)** Step 1: Quit the app.
```toml step
[[actions]]
action = "sql_query"
query = "SELECT MAX(debug_log_id) FROM debug_log;"
capture = "before_quit_id"

[[actions]]
action = "shell"
command = "osascript -e 'tell application \"TimeFlip\" to quit'"
```
- [ ] **(Claude)** Step 2: Restore `low_battery_level` to its original value noted above. (Restored to 5%.)
```toml step
action = "sql_exec"
query = "UPDATE setting SET setting_value = '$threshold_original' WHERE setting_name = 'low_battery_level';"
```
- [ ] **(Claude)** Step 3: Start the app and confirm it reconnects to the device (fresh `debug_log`
      `"Login accepted, code=0x02"` row).
```toml step
[[actions]]
action = "shell"
command = "nohup ./.build/bundler/apps/TimeFlip/TimeFlip.app/Contents/MacOS/TimeFlip > /dev/null 2>&1 &"

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Login accepted%' AND debug_log_id > $before_quit_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Login accepted"
timeout_seconds = 30
```
- [ ] **(Claude)** Step 4: Query `debug_log` and confirm a `battery` row now shows `isLowBattery=false`.
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='battery' AND debug_log_id > $before_quit_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "isLowBattery=false"
timeout_seconds = 15
```
- [ ] **(You)** Step 5: Confirm the activity name is no longer flashing, and that the Battery line on the
      Device tab is no longer flashing.
- [ ] **(You)** Step 6: Click the **left side** of the status item again and confirm it now opens the
      normal dropdown menu (not Settings directly) -- the low-battery left-click skip only applies
      while the warning is active.
