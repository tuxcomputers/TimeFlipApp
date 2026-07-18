# Double-Tap Enabled Persistence Checklist

Covers the Double-tap **Disable** checkbox's `enabled` flag moving from UserDefaults to being
DB-backed via `AppDataStore`/the `double_tap_settings` row -- confirms the flag set in the
Settings UI survives an app restart by round-tripping through the DB, not just in-memory state.
Requires Developer Mode enabled and a paired, connected device (the control is disabled while
unpaired).

**Automated coverage:** the `enabled` flag's DB round-trip across a restart -- including that
toggling it leaves the accelerometer params intact -- is unit-tested in
`Tests/TimeFlipAppTests/SettingsPersistenceTests.swift` (a second `AppDataStore` on the same file
stands in for the restart). The steps below remain for what that can't reach: the checkbox UI
writing the flag and the real device honoring it.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Setup

- [ ] **(You)** Quit the app if it's running.
- [ ] **(Claude)** Run `scripts/use-test-database.sh`.
- [ ] **(You)** Start the app and confirm it reconnects to the device.
- [ ] **(Claude)** Query `db_type` and confirm it reads `{"type":"test"}` before proceeding:
      `sqlite3 ~/Library/Application\ Support/TimeFlip/appdata.sqlite "SELECT setting_value FROM
      setting WHERE setting_name = 'db_type';"`.
- [ ] **(You)** Open Preferences, Device tab, and expand the **Double tap** disclosure under
      Settings.

## Scenario -- enabled flag persists across a restart

- [ ] **(You)** Note whether **Disable** is currently checked or not, then toggle it to the
      opposite state.
- [ ] **(Claude)** Query `double_tap_settings` and confirm its `enabled` field flipped to match
      (`false` if Disable is now checked, `true` if not).
- [ ] **(You)** Quit the app and start it again.
- [ ] **(You)** Reopen Preferences, Device tab, expand **Double tap**, and confirm **Disable**
      still shows the state you set.
- [ ] **(You)** Toggle **Disable** back to its original state from the first step, so the session
      doesn't leave a real setting changed.
