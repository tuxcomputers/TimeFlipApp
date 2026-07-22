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

- [x] **(Claude)** Query the current threshold and the most recent `battery` `level`, and note both
      as the original values to restore later. (Original threshold: 5%. Live level: 22%.)
- [x] **(Claude)** Quit the app. Method: Quit the app (`../Methods.md`).
- [x] **(Claude)** Update `low_battery_level` to at/above the live level noted above, so the fresh
      connection registers as low immediately: `sqlite3 ~/Library/Application\ Support/TimeFlip/appdata.sqlite
      "UPDATE setting SET setting_value = '{\"percent\":<level>}' WHERE setting_name =
      'low_battery_level';"`. (Set to 25%.)
- [x] **(Claude)** Start the app and confirm it reconnects to the device (fresh `debug_log`
      `"Login accepted, code=0x02"` row). (Confirmed.)
- [x] **(Claude)** Query `debug_log` and confirm a `battery` row logged after the restart shows
      `isLowBattery=true`, so the visual checks below are being made while the app really is in the
      low state. (Confirmed: `level=22 threshold=25 recoveryAt=30 isLowBattery=true`.)

## Scenario B -- confirm the flashing and the left-click-skips-the-menu behavior

**Preconditions:** currently in the low-battery state the previous section triggered
(`isLowBattery=true`) -- confirmed by that section's own final query above; re-check it directly
if running this section standalone rather than straight after.

- [x] **(You)** Confirm the activity name (left side of the menu bar item) is blinking red/white.
      (Confirmed via two spaced screenshots showing the activity text alternate red/default.)
- [x] **(You)** Click the **left side** of the status item (the icon + activity name, not the
      duration/timer side) and confirm it opens Settings **directly on the Device tab** -- not the
      dropdown menu. (Confirmed: "The settings opened".)
- [x] **(Claude)** Confirm via accessibility that the Device tab is selected (radio button 1 of the
      tab picker reads `value = 1`). (Confirmed: `value = 1`.)
- [x] **(You)** Confirm the "Battery" line on the Device tab -- both the **label** and the
      percentage value -- is flashing red/default in sync with the menu bar blink. (Confirmed.)

### Bugs found and fixed - branch 'feature/projects'
2026-07-22 - The "Settings..." dropdown menu item's blink would freeze permanently after hovering
on/off it a few times (`NSMenuItem` doesn't reliably repaint an open menu's row after a highlight
change); a custom-view redraw workaround reduced but didn't eliminate the race. Fixed by dropping
the blink there entirely -- clicking the left side of the status item while low battery now opens
Settings directly on the Device tab instead of showing the menu at all.

## Scenario C -- restore and confirm it all stops

**Preconditions:** still in the low-battery state, both elements still flashing (the previous
section's own state, unchanged) -- so there's something real to restore and confirm stops.

- [x] **(Claude)** Quit the app.
- [x] **(Claude)** Restore `low_battery_level` to its original value noted above. (Restored to 5%.)
- [x] **(Claude)** Start the app and confirm it reconnects to the device (fresh `debug_log`
      `"Login accepted, code=0x02"` row). (Confirmed.)
- [x] **(Claude)** Query `debug_log` and confirm a `battery` row now shows `isLowBattery=false`.
      (Confirmed: `level=22 threshold=5 recoveryAt=10 isLowBattery=false`.)
- [x] **(You)** Confirm the activity name is no longer flashing, and that the Battery line on the
      Device tab is no longer flashing. (Confirmed.)
- [x] **(You)** Click the **left side** of the status item again and confirm it now opens the
      normal dropdown menu (not Settings directly) -- the low-battery left-click skip only applies
      while the warning is active. (Confirmed.)
