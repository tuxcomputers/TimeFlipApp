# Low-Battery Indicator Checklist (Interactive)

The visual half of the low-battery test: confirming the three elements actually *flash* in lockstep
-- the menu-bar activity name, the "Settings..." dropdown menu item, and the Battery line on the
Device tab. None of these is machine-readable (the menu-bar item is a custom-drawn status item; the
flash is a color animation, not text/state), so a person has to watch them. The `isLowBattery` latch
logic, hysteresis, and forced-Device-tab selection are all covered by
`Tests/Bench/03b-battery-low-indicator-checklist.md` and its unit tests; this file only adds eyes on
the rendering.

Run **after** the bench file, which restores the threshold at the end -- so this file re-triggers
the low state itself, then restores it again. Requires the test DB active (`db_type` = `test`) and a
paired, connected device.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Scenario A -- re-trigger the low-battery state

**Preconditions:** device connected, threshold at its real default (5%), not currently in a
low-battery state -- the clean state the Bench run's own restore leaves behind. Check via the
query below; if it shows a non-default threshold or `isLowBattery=true` left over from an
interrupted prior run, restore the threshold to 5% and restart the app before continuing.

- [ ] **(Claude)** Query the current threshold and the most recent `battery` `level`, and note both
      as the original values to restore later.
- [ ] **(Claude)** Quit the app. Method: Quit the app (`../Methods.md`).
- [ ] **(Claude)** Update `low_battery_level` to at/above the live level noted above, so the fresh
      connection registers as low immediately: `sqlite3 ~/Library/Application\ Support/TimeFlip/appdata.sqlite
      "UPDATE setting SET setting_value = '{\"percent\":<level>}' WHERE setting_name =
      'low_battery_level';"`.
- [ ] **(Claude)** Start the app and confirm it reconnects to the device (fresh `debug_log`
      `"Login accepted, code=0x02"` row).
- [ ] **(Claude)** Query `debug_log` and confirm a `battery` row logged after the restart shows
      `isLowBattery=true`, so the visual checks below are being made while the app really is in the
      low state.

## Scenario B -- confirm the flashing (all three in lockstep)

**Preconditions:** currently in the low-battery state the previous section triggered
(`isLowBattery=true`) -- confirmed by that section's own final query above; re-check it directly
if running this section standalone rather than straight after.

- [ ] **(You)** Confirm the activity name (left side of the menu bar item) is blinking red/white.
- [ ] **(You)** Click the menu bar item to open the dropdown (don't click Preferences yet) and
      confirm the "Settings..." item is flashing red/white in sync with the activity-name blink
      (both change color at the same moment).
- [ ] **(You)** Click "Settings..." and confirm the "Battery" line on the Device tab -- both the
      **label** and the percentage value -- is flashing red/default in sync with the menu bar blink.

## Scenario C -- restore and confirm it all stops

**Preconditions:** still in the low-battery state, all three elements still flashing (the previous
section's own state, unchanged) -- so there's something real to restore and confirm stops.

- [ ] **(Claude)** Quit the app.
- [ ] **(Claude)** Restore `low_battery_level` to its original value noted above.
- [ ] **(Claude)** Start the app and confirm it reconnects to the device (fresh `debug_log`
      `"Login accepted, code=0x02"` row).
- [ ] **(Claude)** Query `debug_log` and confirm a `battery` row now shows `isLowBattery=false`.
- [ ] **(You)** Confirm the activity name and the "Settings..." menu item are no longer flashing,
      and that the Battery line on the Device tab is no longer flashing.
