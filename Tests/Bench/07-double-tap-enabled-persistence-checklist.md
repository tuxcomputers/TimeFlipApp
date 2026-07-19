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

- [ ] Quit the app if it's running (`osascript -e 'tell application "TimeFlip" to quit'`).
- [ ] Run `scripts/use-test-database.sh`.
- [ ] Start the app and confirm it reconnects to the device (fresh `debug_log` `"Login accepted,
      code=0x02"` row).
- [ ] Query `db_type` and confirm it reads `{"type":"test"}` before proceeding:
      `sqlite3 ~/Library/Application\ Support/TimeFlip/appdata.sqlite "SELECT setting_value FROM
      setting WHERE setting_name = 'db_type';"`.
- [ ] Open Preferences (status-item menu -> "Preferences...") and switch to the Device tab (radio
      button 1 of the tab picker), then expand the **Double tap** disclosure under Settings.

## Scenario -- enabled flag persists across a restart

- [ ] Read whether **Disable** is currently checked or not (accessibility `value` of the checkbox),
      then toggle it to the opposite state.
- [ ] Query `double_tap_settings` and confirm its `enabled` field flipped to match (`false` if
      Disable is now checked, `true` if not).
- [ ] Quit the app and start it again; confirm reconnect via a fresh `debug_log` `"Login accepted,
      code=0x02"` row.
- [ ] Reopen Preferences, Device tab, expand **Double tap**, and confirm **Disable** still shows the
      state set above -- read the checkbox's value directly via accessibility, no screenshot
      needed.
- [ ] Toggle **Disable** back to its original state from the first step, so the session doesn't
      leave a real setting changed.
