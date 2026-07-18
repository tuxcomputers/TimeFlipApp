# Low-Battery Indicator Checklist

Covers the low-battery blink (`MenuBarController.updateLowBatteryBlinkTimer`/
`updatedLowBatteryLatch`): the activity name blinks red/white once battery drops to or below
`low_battery_level`, and only clears once it climbs `lowBatteryRecoveryMarginPercent` (5 points)
above that threshold. Requires Developer Mode enabled, the `debug` setting's `enabled` field
`true` (so `.battery`-tagged debug prints land in `debug_log` -- see `Tests/Bench/README.md`),
and a paired, connected device.

Battery level itself isn't persisted anywhere else in the DB (it's a live BLE reading) -- only the
threshold is a DB setting, which is what lets this test trigger the blink on demand instead of
waiting for the real battery to drain or charge. The threshold is only read once at launch, so it
must be changed while the app is down, not while it's running.

**Automated coverage:** the hysteresis/recovery-margin latch is unit-tested in
`Tests/TimeFlipAppTests/LowBatteryLatchTests.swift`, the red/white blink color selection in
`MenuBarStatusStyleTests.swift`, and the Settings-window blink mirror + forced-Device-tab hint in
`AppStateDeviceTabTests.swift`. The steps below remain for what those can't reach: a real battery
reading crossing the threshold, the live blink *timer*, and the actual menu-item/Device-tab flash
rendering.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Trigger the low-battery state

- [x] **(Claude)** Query `debug_log` for the most recent `battery` row (`SELECT message FROM
      debug_log WHERE tag = 'battery' ORDER BY debug_log_id DESC LIMIT 1;`) for the current actual
      `level`. (Confirmed: current level 27%, threshold 5%, not low.)
- [x] **(You)** Quit the app.
- [x] **(Claude)** Query the current threshold: `sqlite3 ~/Library/Application\ Support/TimeFlip/appdata.sqlite
      "SELECT setting_value FROM setting WHERE setting_name = 'low_battery_level';"` and note it
      as the original value to restore later. (Original: 5%. Matches `current_settings.json`'s
      snapshot, so no new snapshot needed.)
- [x] **(Claude)** Update the threshold to at/above the level noted above, so the fresh connection
      registers as low immediately: `sqlite3 ~/Library/Application\ Support/TimeFlip/appdata.sqlite
      "UPDATE setting SET setting_value = '{\"percent\":<level>}' WHERE setting_name =
      'low_battery_level';"`. (Set to 30% -- battery was at 27%.)
- [x] **(You)** Start the app and confirm it reconnects to the device.
- [x] **(Claude)** Query `debug_log` and confirm a `battery` row logged after the restart shows
      `isLowBattery=true`. (Confirmed: `level=27 threshold=30 recoveryAt=35 isLowBattery=true`.)
- [x] **(You)** Confirm the activity name (left side of the menu bar item) is blinking red/white.

## Confirm recovery clears it

- [x] **(You)** Quit the app.
- [x] **(Claude)** Restore the threshold to its original value (from the first step above) via the
      same `UPDATE setting ...` command. (Restored to 5%.)
- [x] **(You)** Start the app and confirm it reconnects to the device.
- [x] **(Claude)** Query `debug_log` and confirm a `battery` row logged after the restart shows
      `isLowBattery=false`, with `level` above `recoveryAt` (threshold + 5), not just above the
      bare threshold. (Confirmed: `level=27 threshold=5 recoveryAt=10 isLowBattery=false`.)
- [x] **(You)** Confirm the activity name is no longer flashing.

## Confirm the recovery margin, not just the bare threshold, controls the latch

The battery's live reading naturally flaps by 1% (e.g. 26/27) even when not actively
charging/draining. This section sets the threshold to that lower reading so the fresh connection
is immediately low, then waits for a natural flap up to the higher reading -- which is still below
`recoveryAt` (threshold + 5) -- to confirm the blink does *not* clear on that small rise. This is
the real hysteresis case the "Confirm recovery clears it" section above doesn't exercise, since
that one already restored the threshold to a value (5%) far enough below the live level that
`recoveryAt` was trivially satisfied.

- [x] **(Claude)** Query `debug_log` for recent `battery` rows and note the live level's natural
      fluctuation range (its lower and higher reading). (Confirmed: flaps between 26% (lower) and
      27% (higher).)
- [x] **(You)** Quit the app.
- [x] **(Claude)** Update the threshold to the lower reading noted above via the same `UPDATE
      setting ...` command. (Set to 26%; recoveryAt will be 31%.)
- [x] **(You)** Start the app and confirm it reconnects to the device.
- [x] **(Claude)** Query `debug_log` and confirm a `battery` row logged after the restart shows
      `isLowBattery=true`. (Confirmed: `level=26 threshold=26 recoveryAt=31 isLowBattery=true` --
      the reconnect's first reading was 27%, above the 26% threshold, so it took one flap down to
      26% to go low.)
- [x] **(You)** Confirm the activity name is blinking red/white.
- [x] **(Claude)** Poll `debug_log` until a `battery` row shows `level` at the higher reading noted
      above, and confirm `isLowBattery` is still `true` on that row (since the higher reading
      remains below `recoveryAt`). (Confirmed: `level=27 threshold=26 recoveryAt=31
      isLowBattery=true`, logged right after the 26% reading -- the flap up to 27% did not clear
      the latch, as expected since 27 < recoveryAt 31.)
- [x] **(You)** Confirm the activity name is still blinking red/white.
- [x] **(You)** Quit the app.
- [x] **(Claude)** Restore the threshold to its original value (5%, from the first section above)
      via the same `UPDATE setting ...` command. (Restored to 5%.)
- [x] **(You)** Start the app and confirm it reconnects to the device.
- [x] **(Claude)** Query `debug_log` and confirm a `battery` row logged after the restart shows
      `isLowBattery=false`. (Confirmed: `level=27 threshold=5 recoveryAt=10 isLowBattery=false`.)
- [x] **(You)** Confirm the activity name is no longer flashing.

## Preferences menu item and Device tab flash on low battery

Covers three additions on top of the menu bar blink above, all driven by the same blink
timer/phase (`MenuBarController.updatePreferencesMenuItemAppearance`,
`AppState.pendingSettingsTab`, and the Device tab's Battery line color via
`AppState.isLowBattery`/`lowBatteryBlinkPhaseOn`), so all three should visibly flash in lockstep
with the menu bar text and with each other:
- The "Preferences..." dropdown menu item flashes red/white.
- Opening Preferences while low-battery is flashing jumps straight to the Device tab, regardless
  of whichever tab was last selected.
- The Battery line on the Device tab flashes red/default.

- [x] **(Claude)** Query `db_type` to confirm which database is active (see "Switching to the test
      database" in this directory's README). (Confirmed: `{"type":"test"}`.)
- [x] **(Claude)** Query the current threshold and the live battery level (same queries as the
      first section above) and note them as the original values to restore later. (Original
      threshold: 5%. Live level: 20%.)
- [x] **(You)** Quit the app.
- [x] **(Claude)** Update the threshold to at/above the live level noted above, so the fresh
      connection registers as low immediately. (Set to 25%.)
- [x] **(You)** Start the app and confirm it reconnects to the device.
- [x] **(Claude)** Query `debug_log` and confirm a `battery` row logged after the restart shows
      `isLowBattery=true`. (Confirmed: `level=20 threshold=25 recoveryAt=30 isLowBattery=true`.)

## Action needed
1. Click the menu bar item to open the dropdown menu (don't click Preferences yet).
2. Watch the "Preferences..." item for a few seconds.

- [x] **(You)** Confirm the "Preferences..." menu item is flashing red/white in sync with the menu
      bar's activity-name blink (both change color at the same moment).
- [x] **(You)** Click "Preferences...".
- [x] **(You)** Confirm the Settings window opens with the **Device** tab selected, regardless of
      whichever tab was open the last time you used Preferences.
- [x] **(You)** Confirm the "Battery" line on the Device tab is flashing red/default in sync with
      the menu bar blink.
### Bugs found and fixed
2026-07-18 - Only the battery percentage value was flashing, not the "Battery" label itself; fixed
by applying the same flash color to both.
- [x] **(You)** Switch to a different tab (e.g. Facets), close Preferences, then reopen it via the
      menu bar item while still low on battery.
- [x] **(You)** Confirm it jumped back to the Device tab again, not the Facets tab you left it on.
- [x] **(You)** Quit the app.
- [x] **(Claude)** Restore the threshold to its original value (from the second step above).
      (Restored to 5%.)
- [x] **(You)** Start the app and confirm it reconnects to the device.
- [x] **(Claude)** Query `debug_log` and confirm a `battery` row logged after the restart shows
      `isLowBattery=false`. (Confirmed: `level=20 threshold=5 recoveryAt=10 isLowBattery=false`.)
- [x] **(You)** Confirm the "Preferences..." menu item is no longer flashing (plain title/color).
- [x] **(You)** Open Preferences and confirm the Battery line is no longer flashing, and that
      opening it no longer force-selects the Device tab -- whatever tab you had open previously
      stays selected.
