# Low-Battery Indicator Checklist

### Last run - 2026-07-21 on the branch 'feature/projects'

Covers the low-battery blink (`MenuBarController.updateLowBatteryBlinkTimer`/
`updatedLowBatteryLatch`): the activity name blinks red/white once battery drops to or below
`low_battery_level`, and only clears once it climbs `lowBatteryRecoveryMarginPercent` (5 points)
above that threshold. Requires Developer Mode enabled, the `debug` setting's `enabled` field
`true` (so `.battery`-tagged debug prints land in `debug_log` -- see `Tests/CLAUDE.md`),
and a paired, connected device.

Battery level itself isn't persisted anywhere else in the DB (it's a live BLE reading) -- only the
threshold is a DB setting, which is what lets this test trigger the blink on demand instead of
waiting for the real battery to drain or charge. The threshold is only read once at launch, so it
must be changed while the app is down, not while it's running.

**Automated coverage:** the hysteresis/recovery-margin latch is unit-tested in
`Tests/TimeFlipAppTests/LowBatteryLatchTests.swift`, the red/white blink color selection in
`MenuBarStatusStyleTests.swift`, and the Settings-window blink mirror + forced-Device-tab hint in
`AppStateDeviceTabTests.swift`.

This bench file drives the state transitions and asserts them from `debug_log` (the `isLowBattery`
latch flipping true/false with the right hysteresis) plus the accessibility-readable forced-Device-tab
behavior. Confirming the actual *flash rendering* -- the menu-bar text and the Battery line visibly
blinking over time -- is a genuinely time-based visual check and lives in
`Tests/Interactive/03i-battery-low-indicator-checklist.md`, run after this one. The "Settings..."
dropdown menu item no longer flashes (design changed live during a test run -- `NSMenuItem` doesn't
reliably repaint an already-open menu row after a highlight change, so continuously animating it
raced AppKit's own redraw during hover); clicking the left side of the status item while low now
opens Settings on the Device tab directly instead, which -- needing real click-position data a
synthetic click doesn't carry -- is also `03i`'s to confirm, not this file's.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Scenario A -- trigger the low-battery state

**Preconditions:** device connected, threshold at its real default (5%), not currently in a
low-battery state -- check via the query below; if it shows `isLowBattery=true` or a non-default
threshold left over from an interrupted prior run, restore the threshold to 5% and restart the app
before continuing.

- [x] Query `debug_log` for the most recent `battery` row for the current actual `level`.
      (Confirmed: level 22%, threshold 5%, not low.)
- [x] Quit the app (`osascript -e 'tell application "TimeFlip" to quit'`).
- [x] Query the current threshold and note it as the original value to restore later. (Original:
      5%.)
- [x] Update the threshold to at/above the level noted above, so the fresh connection registers as
      low immediately. (Set to 30% -- battery was at 22%.)
- [x] Start the app and confirm it reconnects to the device (fresh `debug_log` `"Login accepted,
      code=0x02"` row).
- [x] Query `debug_log` and confirm a `battery` row logged after the restart shows
      `isLowBattery=true`. (Confirmed: `level=23 threshold=30 recoveryAt=35 isLowBattery=true`.)

## Scenario B -- confirm recovery clears it

**Preconditions:** currently in the low-battery state the previous section put it in
(`isLowBattery=true`, threshold above the live level) -- confirm via the query below before
restoring; if it already reads `false`, the previous section's trigger didn't hold and needs
re-running first.

- [x] Query `debug_log` for the most recent `battery` row and confirm `isLowBattery=true` before
      proceeding (state left by the previous section). (Confirmed: `level=23 threshold=30
      recoveryAt=35 isLowBattery=true`.)
- [x] Quit the app.
- [x] Restore the threshold to its original value via the same `UPDATE setting ...` command.
      (Restored to 5%.)
- [x] Start the app and confirm it reconnects to the device. (Confirmed: fresh `"Login accepted,
      code=0x02"` row.)
- [x] Query `debug_log` and confirm a `battery` row logged after the restart shows
      `isLowBattery=false`, with `level` above `recoveryAt` (threshold + 5), not just above the
      bare threshold. (Confirmed: `level=19 threshold=5 recoveryAt=10 isLowBattery=false`.)

## Scenario C -- confirm the recovery margin, not just the bare threshold, controls the latch

**Preconditions:** clean baseline left by the previous section -- threshold restored to its real
default (5%), `isLowBattery=false`. Confirmed by that section's own final query above; re-check it
directly if running this section standalone rather than straight after.

The battery's live reading naturally flaps by 1-2% even when not actively charging/draining (it
was observed genuinely slowly draining over the course of this session, 23% down to 21%, then
stabilizing around 22-23%). This section sets the threshold to a value at/near the live reading so
the fresh connection is immediately low, then confirms a small flap upward -- still below
`recoveryAt` (threshold + 5) -- does *not* clear the latch. This is the real hysteresis case the
"Confirm recovery clears it" section above doesn't exercise, since that one already restored the
threshold to a value (5%) far enough below the live level that `recoveryAt` was trivially
satisfied.

- [x] Query `debug_log` for recent `battery` rows and note the live level's natural fluctuation
      range. (Confirmed: flapped 17-23% over the session, settling around 22-23%. Two thresholds
      were tried first -- 21% and 23% -- but the live level happened to sit exactly at each on
      relaunch, so the initial post-connect reading wasn't reliably low; 22% was the value that
      actually landed inside the flap range on relaunch.)
- [x] Quit the app.
- [x] Update the threshold to a value at/near the live reading via the same `UPDATE setting ...`
      command. (Set to 22%; recoveryAt = 27%.)
- [x] Start the app and confirm it reconnects to the device.
- [x] Query `debug_log` and confirm a `battery` row logged after the restart shows
      `isLowBattery=true`. (Confirmed: `level=20 threshold=22 recoveryAt=27 isLowBattery=true`.)
- [x] Poll `debug_log` until a `battery` row shows a higher reading than the threshold, and confirm
      `isLowBattery` is still `true` on that row (since it remains below `recoveryAt`). (Confirmed:
      `level=23 threshold=22 recoveryAt=27 isLowBattery=true` -- the flap up to 23% did not clear
      the latch, as expected since 23 < recoveryAt 27.)
- [x] Quit the app.
- [x] Restore the threshold to its original value (5%) via the same `UPDATE setting ...` command.
- [x] Start the app and confirm it reconnects to the device.
- [x] Query `debug_log` and confirm a `battery` row logged after the restart shows
      `isLowBattery=false`. (Confirmed: `level=23 threshold=5 recoveryAt=10 isLowBattery=false`.)

## Scenario D -- opening Preferences on low battery force-selects the Device tab

**Preconditions:** clean baseline left by the previous section -- threshold restored to its real
default (5%), `isLowBattery=false`. Confirmed by that section's own final query above; re-check it
directly if running this section standalone rather than straight after.

Covers the `AppState.pendingSettingsTab` hint: opening Preferences while low-battery is active jumps
straight to the Device tab (where the battery reading lives), regardless of whichever tab was last
selected. This is accessibility-readable (the selected tab), so it stays here; the *flashing* of the
Battery line, and confirming the left side of the status item now opens Settings directly (skipping
the dropdown) while low, are the Interactive counterpart.

- [x] Query `db_type` to confirm which database is active. (Confirmed: `{"type":"test"}`.)
- [x] Query the current threshold and the live battery level and note them as the original values
      to restore later. (Original threshold: 5%. Live level: 22%.)
- [x] Quit the app.
- [x] Update the threshold to at/above the live level noted above, so the fresh connection
      registers as low immediately. (Set to 25%.)
- [x] Start the app and confirm it reconnects to the device.
- [x] Query `debug_log` and confirm a `battery` row logged after the restart shows
      `isLowBattery=true`. (Confirmed: `level=22 threshold=25 recoveryAt=30 isLowBattery=true`.)
- [x] With some non-Device tab last selected, open Preferences and confirm via the accessibility
      tree (Method: Read a label or value via accessibility, `../Methods.md`) that the **Device**
      tab is the selected one (the `pendingSettingsTab` hint forced it),
      not whatever was last open. (Confirmed: switched to Facets (radio button 2, value=1), closed,
      reopened -- Device radio button read `value = 1` (selected), and its content --
      `Connection`/`Connected`, `Battery`/`23%` -- was genuinely showing, not just the radio state.)
- [x] Switch to a different tab (e.g. Facets), close Preferences, then reopen it while still low on
      battery, and confirm it jumped back to the Device tab again, not the Facets tab. (Covered by
      the same confirmation above -- this was a reopen after Facets was last selected.)
- [x] Quit the app.
- [x] Restore the threshold to its original value. (Restored to 5%.)
- [x] Start the app and confirm it reconnects to the device.
- [x] Query `debug_log` and confirm a `battery` row logged after the restart shows
      `isLowBattery=false`. (Confirmed: `level=23 threshold=5 recoveryAt=10 isLowBattery=false`.)
- [x] Open Preferences and confirm that, no longer low, opening it no longer force-selects the
      Device tab -- whatever tab was open previously stays selected. (Confirmed: switched to
      Facets, closed, reopened -- Facets radio button read `value = 1`, Device `value = 0`, i.e.
      stayed on Facets.)
