# Low-Battery Indicator Checklist

### Last run - 2026-07-22 on the branch 'feature/projects'

Covers the low-battery blink (`MenuBarController.updateLowBatteryBlinkTimer`/
`updatedLowBatteryLatch`): the activity name blinks red/white once battery drops to or below
`low_battery_level`, and only clears once it climbs `lowBatteryRecoveryMarginPercent` (5 points)
above that threshold. Requires Developer Mode enabled, the `debug` setting's `enabled` field
`true` (so `battery`-tagged debug prints land in `debug_log` -- see `Tests/CLAUDE.md`),
and a paired, connected device.

Battery level itself isn't persisted anywhere else in the DB (it's a live BLE reading) -- only the
threshold is a DB setting, which is what lets this test trigger the blink on demand instead of
waiting for the real battery to drain or charge. The threshold is only read once at launch, so it
must be changed while the app is down, not while it's running.

**Automated coverage:** the hysteresis/recovery-margin latch is unit-tested in
`Tests/TimeFlipAppTests/LowBatteryLatchTests.swift`, the red/white blink color selection in
`MenuBarStatusStyleTests.swift`, and the Settings-window blink mirror + forced-Device-tab hint in
`AppStateDeviceTabTests.swift`

This bench file drives the state transitions and asserts them from `debug_log` (the `isLowBattery`
latch flipping true/false with the right hysteresis) plus the accessibility-readable forced-Device-tab
behavior. Confirming the actual *flash rendering* -- the menu-bar text and the Battery line visibly
blinking over time -- is a genuinely time-based visual check and lives in
`Tests/Interactive/07i-battery-low-indicator-checklist.md`, run after this one. The "Settings..."
dropdown menu item no longer flashes (design changed live during a test run -- `NSMenuItem` doesn't
reliably repaint an already-open menu row after a highlight change, so continuously animating it
raced AppKit's own redraw during hover); clicking the left side of the status item while low now
opens Settings on the Device tab directly instead, which -- needing real click-position data a
synthetic click doesn't carry -- is also `07i`'s to confirm, not this file's.

**Why this is the last feature checklist (07, not 03):** Scenario A's first step derives the live
battery level from the *most-frequent* `battery`-tagged `debug_log` readings (flap-robust), then
sets `threshold = level` to force the low state. That query is only as good as the number of
readings accumulated this run -- and the test DB starts empty each run. Running battery **last**
means every earlier checklist's connected time has already logged plenty of `battery` rows, so the
mode is far more reliable than it would be right after setup. Order among the feature checklists
(03-07) doesn't otherwise matter -- each resolves its own preconditions and restores its own setting
-- so battery was moved here purely for that accuracy. Only `01` (history, before the reset wipes
the counter) and `02` (the reset itself) are order-critical.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Scenario A -- trigger the low-battery state

**Preconditions:** device connected, threshold at its real default (5%), not currently in a
low-battery state -- check via the query below; if it shows `isLowBattery=true` or a non-default
threshold left over from an interrupted prior run, restore the threshold to 5% and restart the app
before continuing.

- [ ] Step 1: Capture the live level
, robust to the 1-2% flap. Not the last row's value (nondeterministic across a flap, and a one-off low outlier would set the threshold below the flap so the device never reads low). Take the **higher of the      two most-frequent** levels (`GROUP BY level ORDER BY count DESC LIMIT 2`, then the larger) -- since this scenario sets `threshold = level` to make the device read low (`level <= threshold`), the threshold must sit at/above the top of the flap.
```toml step
[[actions]]
use = "method-24.j"
action = "wait_for_sql"
expect_contains = "level="
timeout_seconds = 30

[[actions]]
use = "method-24.g"
capture = "battery_level_a"
```
- [ ] Step 2: Quit the app.
[Method: Number 3](../Methods.md#method-3)
```toml step
[[actions]]
use = "method-24.b"
capture = "before_quit_id"

[[actions]]
use = "method-3"
```
- [ ] Step 3: Query the current threshold
and note it in the logs/00-remembered.json file.
```toml step
use = "method-24.a"
setting = "low_battery_level"
capture = "threshold_original"
remember = "changed"
restores = "low_battery_level"
```
- [ ] Step 4: Update the threshold to at/above the level noted above
, so the fresh connection registers as low immediately.
```toml step
use = "method-24.i"
setting = "low_battery_level"
value = "{\"percent\":$battery_level_a}"
```
- [ ] Step 5: Start the app
and confirm it reconnects to the device. [Method: Number 2](../Methods.md#method-2)
```toml step
[[actions]]
use = "method-2"

[[actions]]
use = "method-4"
since_id = "$before_quit_id"
expect_contains = "Login accepted"
timeout_seconds = 30
```
- [ ] Step 6: Query `debug_log`
and confirm a `battery` row logged after the restart shows `isLowBattery=true`
```toml step
use = "method-24.e"
action = "wait_for_sql"
tag = "battery"
since_id = "$before_quit_id"
expect_contains = "isLowBattery=true"
timeout_seconds = 30
```

## Scenario B -- confirm recovery clears it

**Preconditions:** currently in the low-battery state the previous section put it in
(`isLowBattery=true`, threshold above the live level) -- confirm via the query below before
restoring; if it already reads `false`, the previous section's trigger didn't hold and needs
re-running first.

- [ ] Step 1: Query `debug_log` for the most recent `battery` row and confirm `isLowBattery=true`
before proceeding (state left by the previous section).
```toml step
use = "method-24.d"
tag = "battery"
expect_contains = "isLowBattery=true"
```
- [ ] Step 2: Quit the app.
[Method: Number 3](../Methods.md#method-3)
```toml step
[[actions]]
use = "method-24.b"
capture = "before_quit_id"

[[actions]]
use = "method-3"
```
- [ ] Step 3: Restore the threshold to its original value
via the same `UPDATE setting ...` command.
```toml step
use = "method-24.i"
setting = "low_battery_level"
value = "$threshold_original"
```
- [ ] Step 4: Start the app
[Method: Number 2](../Methods.md#method-2) and confirm it reconnects to the device.
```toml step
[[actions]]
use = "method-2"

[[actions]]
use = "method-4"
since_id = "$before_quit_id"
expect_contains = "Login accepted"
timeout_seconds = 30
```
- [ ] Step 5: Confirm a `battery` row after the restart shows `isLowBattery=false`
In `debug_log`, with `level` above `recoveryAt` (threshold + 5), not just above the bare threshold.
```toml step
use = "method-24.e"
action = "wait_for_sql"
tag = "battery"
since_id = "$before_quit_id"
expect_contains = "isLowBattery=false"
timeout_seconds = 30
```

## Scenario C -- confirm the recovery margin, not just the bare threshold, controls the latch

**Preconditions:** clean baseline left by the previous section -- threshold restored to its real
default (5%), `isLowBattery=false` Confirmed by that section's own final query above; re-check it
directly if running this section standalone rather than straight after.

The battery's live reading naturally flaps by 1-2% even when not actively charging/draining (it
was observed genuinely slowly draining over the course of this session, 23% down to 21%, then
stabilizing around 22-23%). This section sets the threshold to a value at/near the live reading so
the fresh connection is immediately low, then confirms a small flap upward -- still below
`recoveryAt` (threshold + 5) -- does *not* clear the latch. This is the real hysteresis case the
"Confirm recovery clears it" section above doesn't exercise, since that one already restored the
threshold to a value (5%) far enough below the live level that `recoveryAt` was trivially
satisfied.

- [ ] Step 1: Capture the live level, robust to the 1-2% flap.
Not the last row's value -- that's whichever of the flapping pair landed most recently (e.g. 18 out of a 17/18 flap), and Step 6 needs the level to rise *above* the threshold, so a threshold set to the *higher* flap value never gets exceeded and Step 6 times out. Instead take the **lower of the two most-frequent** levels (`GROUP BY level ORDER BY count DESC LIMIT 2`, then the smaller) -- that ignores one-off outliers and earlier drift, and setting the threshold there means the natural flap up to the higher value clears it while staying below `recoveryAt`
```toml step
[[actions]]
use = "method-24.j"
action = "wait_for_sql"
expect_contains = "level="
timeout_seconds = 30

[[actions]]
action = "sql_query"
query = "SELECT bl FROM (SELECT CAST(substr(message, 7, instr(message, ' threshold') - 7) AS INTEGER) AS bl, COUNT(*) AS n FROM debug_log WHERE tag='battery' AND message NOT LIKE 'level=nil%' GROUP BY bl ORDER BY n DESC LIMIT 2) ORDER BY bl LIMIT 1;"
capture = "battery_level_c"
```
- [ ] Step 2: Quit the app.
[Method: Number 3](../Methods.md#method-3)
```toml step
[[actions]]
use = "method-24.b"
capture = "before_quit_id"

[[actions]]
use = "method-3"
```
- [ ] Step 3: Update the threshold to a value at/near the live reading
via the same `UPDATE setting ...` command.
```toml step
use = "method-24.i"
setting = "low_battery_level"
value = "{\"percent\":$battery_level_c}"
```
- [ ] Step 4: Start the app and confirm it reconnects to the device.
[Method: Number 2](../Methods.md#method-2).
```toml step
[[actions]]
use = "method-2"

[[actions]]
use = "method-4"
since_id = "$before_quit_id"
expect_contains = "Login accepted"
timeout_seconds = 30
```
- [ ] Step 5: Query `debug_log` and confirm a `battery` row logged after the restart shows `isLowBattery=true`
(Note: the threshold is set to the *lower* of the flap pair -- so the latch trips only when the device flaps **down** to that value, not on the first post-restart reading, which is often the higher value and reads `isLowBattery=false` until then. Post-restart battery reports are sparse (a ~2-minute gap between flaps was seen live), so this waits well past the first reading -- a short timeout would give up before the flap-down that latches it.)
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='battery' AND debug_log_id > $before_quit_id AND message LIKE '%isLowBattery=true%' ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "isLowBattery=true"
timeout_seconds = 180
poll_interval = 5
```
- [ ] Step 6: Poll `debug_log` until a `battery` row reads higher than the threshold.
      Confirm `isLowBattery` is still `true` on that row, since it remains below `recoveryAt`
```toml step
action = "wait_for_sql"
query = "SELECT CASE WHEN CAST(substr(message, 7, instr(message, ' threshold') - 7) AS INTEGER) > $battery_level_c AND message LIKE '%isLowBattery=true%' THEN 'flapped_up_still_low' ELSE message END FROM debug_log WHERE tag='battery' ORDER BY debug_log_id DESC LIMIT 1;"
expect = "flapped_up_still_low"
timeout_seconds = 300
poll_interval = 5
```
- [ ] Step 7: Quit the app.
[Method: Number 3](../Methods.md#method-3)
```toml step
[[actions]]
use = "method-24.b"
capture = "before_quit_id"

[[actions]]
use = "method-3"
```
- [ ] Step 8: Restore the threshold to its original value
via the same `UPDATE setting ...` command.
```toml step
use = "method-24.i"
setting = "low_battery_level"
value = "$threshold_original"
```
- [ ] Step 9: Start the app
[Method: Number 2](../Methods.md#method-2) and confirm it reconnects to the device.
```toml step
[[actions]]
use = "method-2"

[[actions]]
use = "method-4"
since_id = "$before_quit_id"
expect_contains = "Login accepted"
timeout_seconds = 30
```
- [ ] Step 10: Query `debug_log` and confirm a `battery` row
logged after the restart shows `isLowBattery=false`
```toml step
use = "method-24.e"
action = "wait_for_sql"
tag = "battery"
since_id = "$before_quit_id"
expect_contains = "isLowBattery=false"
timeout_seconds = 30
```

## Scenario D -- opening Preferences on low battery force-selects the Device tab

**Preconditions:** clean baseline left by the previous section -- threshold restored to its real
default (5%), `isLowBattery=false` Confirmed by that section's own final query above; re-check it
directly if running this section standalone rather than straight after.

Covers the `AppState.pendingSettingsTab` hint: opening Preferences while low-battery is active jumps
straight to the Device tab (where the battery reading lives), regardless of whichever tab was last
selected. This is accessibility-readable (the selected tab), so it stays here; the *flashing* of the
Battery line, and confirming the left side of the status item now opens Settings directly (skipping
the dropdown) while low, are the Interactive counterpart.

- [ ] Step 1: Query `db_type` to confirm which database is active.
```toml step
use = "method-24.a"
setting = "db_type"
expect = "{\"type\":\"test\"}"
```
- [ ] Step 2: Query the current threshold and the live battery level
and note them in the logs/00-remembered.json file. The level is the **higher of the two most-frequent** readings (flap-robust; this scenario sets `threshold = level` to make the device read low, so it must be at/above the top of the flap).
```toml step
[[actions]]
use = "method-24.a"
setting = "low_battery_level"
capture = "threshold_original"
remember = "changed"
restores = "low_battery_level"

[[actions]]
use = "method-24.j"
action = "wait_for_sql"
expect_contains = "level="
timeout_seconds = 30

[[actions]]
use = "method-24.g"
capture = "battery_level_d"
```
- [ ] Step 3: Quit the app.
[Method: Number 3](../Methods.md#method-3)
```toml step
[[actions]]
use = "method-24.b"
capture = "before_quit_id"

[[actions]]
use = "method-3"
```
- [ ] Step 4: Update the threshold to at/above the live level noted above
, so the fresh connection registers as low immediately.
```toml step
use = "method-24.i"
setting = "low_battery_level"
value = "{\"percent\":$battery_level_d}"
```
- [ ] Step 5: Start the app
[Method: Number 2](../Methods.md#method-2) and confirm it reconnects to the device.
```toml step
[[actions]]
use = "method-2"

[[actions]]
use = "method-4"
since_id = "$before_quit_id"
expect_contains = "Login accepted"
timeout_seconds = 30
```
- [ ] Step 6: Query `debug_log` and confirm a `battery` row logged
after the restart shows `isLowBattery=true`
```toml step
use = "method-24.e"
action = "wait_for_sql"
tag = "battery"
since_id = "$before_quit_id"
expect_contains = "isLowBattery=true"
timeout_seconds = 30
```
- [ ] Step 7: With some non-Device tab last selected, open Preferences on the **Device** tab.
Confirm via the accessibility tree ([Method: Number 11](../Methods.md#method-11)) that Device is the selected tab -- the `pendingSettingsTab` hint forced it, not whatever was last open.
```toml step
[[actions]]
use = "method-6"
item = "Settings..."

[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        click radio button 2 of radio group 1 of group 1 of toolbar 1 of window "TimeFlip Settings"
        delay 0.5
        click button 1 of window "TimeFlip Settings"
    end tell
end tell'''

[[actions]]
use = "method-6"
item = "Settings..."

[[actions]]
use = "method-11"
tab = 1
expect = "1"
```
- [ ] Step 8: Confirm the force-to-Device holds from a *different* last tab too
select the **App** tab (radio button 3, vs Faces in Step 7), close Preferences, then reopen it while still low, and confirm via the accessibility tree that the **Device** tab (radio button 1) is the selected one again. [Method: Number 11](../Methods.md#method-11) -- reading `radio button 1`'s `value`, so no human check needed.
```toml step
[[actions]]
use = "method-6"
item = "Settings..."

[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        click radio button 3 of radio group 1 of group 1 of toolbar 1 of window "TimeFlip Settings"
        delay 0.5
        click button 1 of window "TimeFlip Settings"
    end tell
end tell'''

[[actions]]
use = "method-6"
item = "Settings..."

[[actions]]
use = "method-11"
tab = 1
expect = "1"
```
- [ ] Step 9: Quit the app.
[Method: Number 3](../Methods.md#method-3)
```toml step
[[actions]]
use = "method-24.b"
capture = "before_quit_id"

[[actions]]
use = "method-3"
```
- [ ] Step 10: Restore the threshold to its original value.
      (Restored to 5%.)
```toml step
use = "method-24.i"
setting = "low_battery_level"
value = "$threshold_original"
```
- [ ] Step 11: Start the app
[Method: Number 2](../Methods.md#method-2) and confirm it reconnects to the device.
```toml step
[[actions]]
use = "method-2"

[[actions]]
use = "method-4"
since_id = "$before_quit_id"
expect_contains = "Login accepted"
timeout_seconds = 30
```
- [ ] Step 12: Query `debug_log` and confirm a `battery` row logged
after the restart shows `isLowBattery=false`
```toml step
use = "method-24.e"
action = "wait_for_sql"
tag = "battery"
since_id = "$before_quit_id"
expect_contains = "isLowBattery=false"
timeout_seconds = 30
```
- [ ] Step 13: Open Preferences and confirm
that, no longer low, opening it no longer force-selects the Device tab -- whatever tab was open previously stays selected.
```toml step
[[actions]]
use = "method-6"
item = "Settings..."

[[actions]]
use = "method-11"
tab = 2
expect = "1"
```
- [ ] Step 14: Close the Settings window
(reopened in Step 13) so the next checklist starts with no stray window open. [Method: Number 23](../Methods.md#method-23).
```toml step
use = "method-23"
```
