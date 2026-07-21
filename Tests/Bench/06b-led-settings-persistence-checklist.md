# LED Settings Persistence Checklist

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

- [ ] Quit the app if it's running (`osascript -e 'tell application "TimeFlip" to quit'`).
- [ ] Run `scripts/use-test-database.sh`.
- [ ] Start the app and confirm it reconnects to the device (fresh `debug_log` `"Login accepted,
      code=0x02"` row).
- [ ] Query `db_type` and confirm it reads `{"type":"test"}` before proceeding:
      `sqlite3 ~/Library/Application\ Support/TimeFlip/appdata.sqlite "SELECT setting_value FROM
      setting WHERE setting_name = 'db_type';"`.
- [ ] Open Preferences (status-item menu -> "Settings...") and switch to the Device tab (radio
      button 1 of the tab picker), then expand the **LED** disclosure under Settings. Method: Click
      a status-item menu item, Switch Settings-window tabs, Expand or collapse a disclosure group
      (`../Methods.md`).

## Scenario A -- brightness and blink interval persist across a restart

**Preconditions:** device connected and paired, Preferences open on the Device tab with the LED
disclosure expanded -- established in Setup immediately above, which this scenario runs straight
on from.

- [ ] Set Brightness to `77` and Blink Interval to `42` by typing directly into their fields.
      Method: Edit a text field (`../Methods.md`).
- [ ] Query `led_settings` and confirm it reads `{"brightness":77,"blink_interval":42}`.
- [ ] Quit the app and start it again; confirm reconnect via a fresh `debug_log` `"Login accepted,
      code=0x02"` row.
- [ ] Reopen Preferences, Device tab, expand **LED**, and confirm Brightness still shows `77` and
      Blink Interval still shows `42` -- read both fields' values directly via accessibility, no
      screenshot needed.
- [ ] Query `led_settings` again and confirm it's unchanged (the restart's startup sync re-applies
      the stored value to the device but doesn't alter the stored row).

## Scenario B -- device write is debounced 1s after the value settles, with no read-back verification

Covers `ApplicationDelegate`'s `onLEDBrightnessChange`/`onBlinkIntervalChange` (prints + immediate
DB write on every change, device write debounced through `DeviceWriteDebouncer`) and
`TimeFlipBLEDevice.setLEDBrightness`/`setBlinkInterval`. Unlike auto-pause/double-tap, the BLE
protocol has no read-back command for LED brightness (`0x09`) or blink interval (`0x0A`) at all, so
these log that the write happened with no verification, rather than a fabricated confirm/mismatch.

**Preconditions:** device connected and paired, Preferences open on the Device tab with the LED
disclosure expanded, Brightness/Blink Interval at `77`/`42` -- the clean state the previous
scenario leaves behind (check `led_settings` directly if running this scenario standalone).

- [ ] Note the latest `debug_log_id`. In the Brightness field, type three distinct values in quick
      succession without tabbing away between them: `10`, then immediately `50`, then immediately
      `95`. (Confirmed: typing landed as select-all -> `1` -> `10` -> `5` -> `50` -> `9` -> `95`,
      7 distinct intermediate values in total.)
- [ ] Query `debug_log` (tag `led`) for rows newer than the noted ID and confirm a `"Brightness
      value changed to X%"` + `"Brightness saved to DB: X%"` pair for **each** intermediate value,
      in order. (Confirmed: 7 pairs, `debug_log_id` 3448-3459.)
- [ ] Confirm `led_settings` already reads `"brightness":95` immediately (before the 1s debounce
      elapses). (Confirmed.)
- [ ] Wait about 1.5s, then query `debug_log` again and confirm exactly **one** `"Brightness set to
      95% triggered"` line (not one per intermediate value), followed immediately by `"Brightness
      written to 95% (no device read-back available)"` -- no confirmed/MISMATCH line, since the
      protocol has no brightness read-back. (Confirmed: `debug_log_id` 3460-3461, ~1s after the
      last value-changed line.)
- [ ] Repeat the same rapid-sequence test on the Blink Interval field (`8`, then `25`, then `55`)
      and confirm the identical pattern: every intermediate value printed+DB-saved immediately, one
      debounced `"Blink interval set to 55s triggered"` + `"Blink interval written to 55s (no
      device read-back available)"` pair about 1s later. (Confirmed: `debug_log_id` 3474-3485.)
- [ ] Restore Brightness to `77` and Blink Interval to `42` (the values from the persistence
      scenario above), and confirm `led_settings` reads `{"brightness":77,"blink_interval":42}`
      again, so the session doesn't leave a real setting changed.
