# LED Settings Persistence Checklist

Covers LED brightness/blink interval moving from UserDefaults to being DB-backed via
`AppDataStore`/the `led_settings` row -- confirms a value set in the Settings UI survives an app
restart by round-tripping through the DB, not just in-memory state. Requires Developer Mode
enabled and a paired, connected device (the controls are disabled while unpaired).

**Automated coverage:** the brightness/blink-interval DB round-trip across a restart -- including
that saving one field leaves the other intact -- is unit-tested in
`Tests/TimeFlipAppTests/SettingsPersistenceTests.swift` (a second `AppDataStore` on the same file
stands in for the restart). The steps below remain for what that can't reach: the slider/field UI
writing the value and the startup sync re-applying it to a real device.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Setup

- [ ] **(You)** Quit the app if it's running.
- [ ] **(Claude)** Run `scripts/use-test-database.sh`.
- [ ] **(You)** Start the app and confirm it reconnects to the device.
- [ ] **(Claude)** Query `db_type` and confirm it reads `{"type":"test"}` before proceeding:
      `sqlite3 ~/Library/Application\ Support/TimeFlip/appdata.sqlite "SELECT setting_value FROM
      setting WHERE setting_name = 'db_type';"`.
- [ ] **(You)** Open Preferences, Device tab, and expand the **LED** disclosure under Settings.

## Scenario -- brightness and blink interval persist across a restart

- [ ] **(You)** Set Brightness to `77` and Blink Interval to `42` (drag the sliders or type
      directly into the fields).
- [ ] **(Claude)** Query `led_settings` and confirm it reads
      `{"brightness":77,"blink_interval":42}`.
- [ ] **(You)** Quit the app and start it again.
- [ ] **(You)** Reopen Preferences, Device tab, expand **LED**, and confirm Brightness still shows
      `77` and Blink Interval still shows `42`.
- [ ] **(Claude)** Query `led_settings` again and confirm it's unchanged (the restart's startup
      sync re-applies the stored value to the device but doesn't alter the stored row).
