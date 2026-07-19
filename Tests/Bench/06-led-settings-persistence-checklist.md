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
- [ ] Open Preferences (status-item menu -> "Preferences...") and switch to the Device tab (radio
      button 1 of the tab picker), then expand the **LED** disclosure under Settings.

## Scenario -- brightness and blink interval persist across a restart

- [ ] Set Brightness to `77` and Blink Interval to `42` by typing directly into their fields (see
      "Driving the app directly" in `../CLAUDE.md` for the focus/select-all/type/tab pattern).
- [ ] Query `led_settings` and confirm it reads `{"brightness":77,"blink_interval":42}`.
- [ ] Quit the app and start it again; confirm reconnect via a fresh `debug_log` `"Login accepted,
      code=0x02"` row.
- [ ] Reopen Preferences, Device tab, expand **LED**, and confirm Brightness still shows `77` and
      Blink Interval still shows `42` -- read both fields' values directly via accessibility, no
      screenshot needed.
- [ ] Query `led_settings` again and confirm it's unchanged (the restart's startup sync re-applies
      the stored value to the device but doesn't alter the stored row).
