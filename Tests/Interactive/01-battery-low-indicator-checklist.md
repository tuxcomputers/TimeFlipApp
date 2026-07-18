# Low-Battery Indicator Checklist

Covers the low-battery blink (`MenuBarController.updateLowBatteryBlinkTimer`/
`updatedLowBatteryLatch`): the activity name blinks red/white once battery drops to or below
`low_battery_level`, and only clears once it climbs `lowBatteryRecoveryMarginPercent` (5 points)
above that threshold. Requires Developer Mode enabled, the `debug` setting's `enabled` field
`true` (so `.battery`-tagged debug prints land in `debug_log` -- see `Tests/Interactive/README.md`),
and a paired, connected device.

Battery level itself isn't persisted anywhere else in the DB (it's a live BLE reading) -- only the
threshold is a DB setting, which is what lets this test trigger the blink on demand instead of
waiting for the real battery to drain or charge. The threshold is only read once at launch, so it
must be changed while the app is down, not while it's running.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Trigger the low-battery state

- [x] **(Claude)** Query `debug_log` for the most recent `battery` row (`SELECT message FROM
      debug_log WHERE tag = 'battery' ORDER BY debug_log_id DESC LIMIT 1;`) for the current actual
      `level`.

      Current level: 27%, threshold: 5%, not low.
- [x] **(You)** Quit the app.
- [x] **(Claude)** Query the current threshold: `sqlite3 ~/Library/Application\ Support/TimeFlip/appdata.sqlite
      "SELECT setting_value FROM setting WHERE setting_name = 'low_battery_level';"` and note it
      as the original value to restore later.

      Original: 5%. Matches `current_settings.json`'s snapshot, so no new snapshot needed.
- [x] **(Claude)** Update the threshold to at/above the level noted above, so the fresh connection
      registers as low immediately: `sqlite3 ~/Library/Application\ Support/TimeFlip/appdata.sqlite
      "UPDATE setting SET setting_value = '{\"percent\":<level>}' WHERE setting_name =
      'low_battery_level';"`.

      Set to 30% (battery was at 27%).
- [x] **(You)** Start the app and confirm it reconnects to the device.
- [x] **(Claude)** Query `debug_log` and confirm a `battery` row logged after the restart shows
      `isLowBattery=true`.

      Confirmed: `level=27 threshold=30 recoveryAt=35 isLowBattery=true`.
- [x] **(You)** Confirm the activity name (left side of the menu bar item) is blinking red/white.

## Confirm recovery clears it

- [x] **(You)** Quit the app.
- [x] **(Claude)** Restore the threshold to its original value (from the first step above) via the
      same `UPDATE setting ...` command.

      Restored to 5%.
- [x] **(You)** Start the app and confirm it reconnects to the device.
- [x] **(Claude)** Query `debug_log` and confirm a `battery` row logged after the restart shows
      `isLowBattery=false`, with `level` above `recoveryAt` (threshold + 5), not just above the
      bare threshold.

      Confirmed: `level=27 threshold=5 recoveryAt=10 isLowBattery=false`.
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
      fluctuation range (its lower and higher reading).

      Flaps between 26% (lower) and 27% (higher).
- [x] **(You)** Quit the app.
- [x] **(Claude)** Update the threshold to the lower reading noted above via the same `UPDATE
      setting ...` command.

      Set to 26%; recoveryAt will be 31%.
- [x] **(You)** Start the app and confirm it reconnects to the device.
- [x] **(Claude)** Query `debug_log` and confirm a `battery` row logged after the restart shows
      `isLowBattery=true`.

      Confirmed: `level=26 threshold=26 recoveryAt=31 isLowBattery=true` (the reconnect's first
      reading was 27%, above the 26% threshold, so it took one flap down to 26% to go low).
- [x] **(You)** Confirm the activity name is blinking red/white.
- [x] **(Claude)** Poll `debug_log` until a `battery` row shows `level` at the higher reading noted
      above, and confirm `isLowBattery` is still `true` on that row (since the higher reading
      remains below `recoveryAt`).

      Confirmed: `level=27 threshold=26 recoveryAt=31 isLowBattery=true`, logged right after the
      26% reading -- the flap up to 27% did not clear the latch, as expected (27 < recoveryAt 31).
- [x] **(You)** Confirm the activity name is still blinking red/white.
- [x] **(You)** Quit the app.
- [x] **(Claude)** Restore the threshold to its original value (5%, from the first section above)
      via the same `UPDATE setting ...` command.

      Restored to 5%.
- [x] **(You)** Start the app and confirm it reconnects to the device.
- [x] **(Claude)** Query `debug_log` and confirm a `battery` row logged after the restart shows
      `isLowBattery=false`.

      Confirmed: `level=27 threshold=5 recoveryAt=10 isLowBattery=false`.
- [x] **(You)** Confirm the activity name is no longer flashing.
