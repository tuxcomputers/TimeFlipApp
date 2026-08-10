# Low-Battery Indicator Checklist (Interactive)

### Last run - 2026-08-10 17:38 on the branch 'bugfix/pairingProbeSettle'

The visual half of the low-battery test: confirming the menu-bar activity name and the Battery line
on the Device tab actually *flash* in lockstep. The flash is a color animation, not text/state, on a
custom-drawn status item, so a person has to watch those (Steps 1 and 4). The left-click-jumps-to-
Settings behavior, once believed to need a real click (the belief noted here before), is now driven
directly via CGEventPost ([Method: Number 7](../Methods.md#method-7), target `status_item_left`) and
verified from `debug_log` + accessibility -- so Step 2/3 are Claude-driven. The `isLowBattery` latch
logic, hysteresis, and forced-Device-tab selection are all covered by
`Tests/Bench/07b-battery-low-indicator-checklist.md` and its unit tests; this file only adds eyes on
the flash rendering.

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

- [x] **(Claude)** Step 1: Query the current threshold and the live `battery` `level`
, and note both.  Take the **higher of the two most-frequent** readings -- flap-robust, since this sets `threshold = level` to make the device read low. Both are captured, so they can be restored at the end.
```toml step
[[actions]]
use = "method-24.a"
setting = "low_battery_level"
capture = "threshold_original"

[[actions]]
use = "method-24.j"
action = "wait_for_sql"
expect_contains = "level="
timeout_seconds = 30

[[actions]]
use = "method-24.g"
capture = "battery_level_a"
```
- [x] **(Claude)** Step 2: Quit the app.
      [Method: Number 3](../Methods.md#method-3).
```toml step
[[actions]]
use = "method-24.b"
capture = "before_quit_id"

[[actions]]
use = "method-3"
```
- [x] **(Claude)** Step 3: Update `low_battery_level` to at/above the live level noted above
, so the fresh connection registers as low immediately:
`sqlite3 ~/Library/Application\ Support/TimeFlip/appdata.sqlite "UPDATE setting SET setting_value = '{\"percent\":<level>}' WHERE setting_name = 'low_battery_level';"`
```toml step
use = "method-24.i"
setting = "low_battery_level"
value = "{\"percent\":$battery_level_a}"
```
- [x] **(Claude)** Step 4: Start the app
[Method: Number 2](../Methods.md#method-2) and confirm it reconnects to the device (fresh `debug_log` `"Login accepted, code=0x02"` row).
```toml step
[[actions]]
use = "method-2"

[[actions]]
use = "method-4"
since_id = "$before_quit_id"
expect_contains = "Login accepted"
timeout_seconds = 30
```
- [x] **(Claude)** Step 5: Confirm a `battery` row logged
after the restart shows `isLowBattery=true` in `debug_log` -- so the visual checks below are made while the app really is in the low state.
```toml step
use = "method-24.e"
action = "wait_for_sql"
tag = "battery"
since_id = "$before_quit_id"
expect_contains = "isLowBattery=true"
timeout_seconds = 30
```

## Scenario B -- confirm the flashing and the left-click-skips-the-menu behavior

**Preconditions:** currently in the low-battery state the previous section triggered
(`isLowBattery=true`) -- confirmed by that section's own final query above; re-check it directly
if running this section standalone rather than straight after.

- [x] **(You)** Step 1: Confirm the activity name is blinking red/white.
- [x] **(Claude)** Step 2: Click the **left side** of the status item
and confirm the low-battery shortcut fired. That is the icon + activity name, not the duration/timer side, clicked via CGEventPost: `debug_log` (`click` tag) logs `Status item clicked: side=left clickCount=1 -> openSettings`, the app having opened Settings directly instead of the dropdown menu while the warning is active. Step 3 then confirms the Device tab is the one selected. Method: [Number 7](../Methods.md#method-7) (target `status_item_left`).
      This used to wait for `Left-click while low battery: opening Settings...`, a marker `1447da4`
      deleted when it lifted the routing rule out of AppKit into `MenuBarClickRouter` and replaced
      the per-branch messages with one line naming the decision. The click was landing and the app
      was doing the right thing; only the sentence it used to say had gone.
      Asserting the decision is enough here because *why* it was taken is unit-tested
      (`MenuBarClickRouterTests.testConnectedLeftSideOpensSettingsWhileTheBatteryWarningBlinks`): a
      left-click resolves to `openSettings` only while the warning blinks. What those tests cannot
      see, and what this step is for, is whether a real click at a real screen position reaches that
      rule at all.
```toml step
[[actions]]
use = "method-24.b"
capture = "before_left_click_id"

[[actions]]
action = "cgevent_click"
target = "status_item_left"
mode = "single"

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='click' AND message LIKE 'Status item clicked:%' AND debug_log_id > $before_left_click_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "side=left clickCount=1 -> openSettings"
timeout_seconds = 30
```
Settings...`, which `1447da4` deleted when it moved the routing rule out of AppKit into
`MenuBarClickRouter` and replaced the per-branch messages with one line naming the resolved action.
Nothing was wrong with the app: the click landed and Settings opened, and the log said so as
`Status item clicked: side=left clickCount=1 -> openSettings`. The step reads the decision now, and
`Methods.md` Method 7 records that the arrow is the durable thing to assert on.
2026-08-10 - Scenario C Step 6 was the same fault, on the sibling marker `Left-click: opening the
dropdown menu`, and it halted the very next run because the first fix chased the one failing string
instead of the family. `1447da4` deleted exactly three click messages; this file asserted two of
them. Both read the arrow now, which is also what makes the pair meaningful: the same click on the
same half resolving to `openSettings` in Scenario B and `showMenu` here is the whole difference the
low-battery shortcut makes.

- [x] **(Claude)** Step 3: Confirm that Settings opened on the Device tab
(the Device tab reads `value = 1`) -- the window only exists if the left-click opened Settings, so this doubles as proof it wasn't the dropdown menu.
```toml step
[[actions]]
use = "method-11"
tab = "Device"
expect = "1"
```
- [x] **(You)** Step 4: Confirm the "Battery" line on the Device tab is flashing red/default.
      Both the **label** and the percentage value flash, in sync with the menu bar blink.

## Scenario C -- restore and confirm it all stops

**Preconditions:** still in the low-battery state, both elements still flashing (the previous
section's own state, unchanged) -- so there's something real to restore and confirm stops.

- [x] **(Claude)** Step 1: Quit the app.
[Method: Number 3](../Methods.md#method-3)
```toml step
[[actions]]
use = "method-24.b"
capture = "before_quit_id"

[[actions]]
use = "method-3"
```
- [x] **(Claude)** Step 2: Restore `low_battery_level` to its original value noted above.
      (Restored to 5%.)
```toml step
use = "method-24.i"
setting = "low_battery_level"
value = "$threshold_original"
```
- [x] **(Claude)** Step 3: Start the app
[Method: Number 2](../Methods.md#method-2) and confirm it reconnects to the device (fresh `debug_log` `"Login accepted, code=0x02"` row).
```toml step
[[actions]]
use = "method-2"

[[actions]]
use = "method-4"
since_id = "$before_quit_id"
expect_contains = "Login accepted"
timeout_seconds = 30
```
- [x] **(Claude)** Step 4: Query `debug_log` and confirm a `battery` row now
shows `isLowBattery=false`
```toml step
use = "method-24.e"
action = "wait_for_sql"
tag = "battery"
since_id = "$before_quit_id"
expect_contains = "isLowBattery=false"
timeout_seconds = 30
```
- [x] **(You)** Step 5: Confirm the activity name is no longer flashing
, and that the Battery line on the Device tab is no longer flashing.
- [x] **(Claude)** Step 6: Click the **left side** of the status item again
 via CGEventPost and confirm it now opens the normal dropdown **menu**, not Settings -- the low-battery left-click skip only applies while the warning is active. `debug_log` (`click` tag) logs `Status item clicked: side=left clickCount=1 -> showMenu`, the non-low branch; an Escape then dismisses the menu it opened so it doesn't block later steps. Method: [Number 7](../Methods.md#method-7) (target `status_item_left`).
      The sibling of Step 2's fix, and the one that proves this scenario's point: the *same* click,
      on the same half, resolving to `showMenu` here and `openSettings` there is the whole
      difference the low-battery shortcut makes, and the arrow is where that difference now shows.
```toml step
[[actions]]
use = "method-24.b"
capture = "before_menu_click_id"

[[actions]]
action = "cgevent_click"
target = "status_item_left"
mode = "single"

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='click' AND message LIKE 'Status item clicked:%' AND debug_log_id > $before_menu_click_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "side=left clickCount=1 -> showMenu"
timeout_seconds = 30

[[actions]]
action = "shell"
command = "sleep 1"

[[actions]]
action = "cgevent_key"
keycode = 53
```
