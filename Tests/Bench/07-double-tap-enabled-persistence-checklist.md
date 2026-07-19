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

- [x] Quit the app if it's running (`osascript -e 'tell application "TimeFlip" to quit'`).
- [x] Run `scripts/use-test-database.sh`.
- [x] Start the app and confirm it reconnects to the device (fresh `debug_log` `"Login accepted,
      code=0x02"` row).
- [x] Query `db_type` and confirm it reads `{"type":"test"}` before proceeding:
      `sqlite3 ~/Library/Application\ Support/TimeFlip/appdata.sqlite "SELECT setting_value FROM
      setting WHERE setting_name = 'db_type';"`.
- [x] Open Preferences (status-item menu -> "Preferences...") and switch to the Device tab (radio
      button 1 of the tab picker), then expand the **Double tap** disclosure under Settings.

## Scenario -- enabled flag persists across a restart

**Preconditions:** device connected and paired, Preferences open on the Device tab with the
Double tap disclosure expanded -- established in Setup immediately above, which this scenario
runs straight on from.

- [x] Read whether **Disable** is currently checked or not (accessibility `value` of the checkbox),
      then toggle it to the opposite state.
- [x] Query `double_tap_settings` and confirm its `enabled` field flipped to match (`false` if
      Disable is now checked, `true` if not).
- [x] Quit the app and start it again; confirm reconnect via a fresh `debug_log` `"Login accepted,
      code=0x02"` row.
- [x] Reopen Preferences, Device tab, expand **Double tap**, and confirm **Disable** still shows the
      state set above -- read the checkbox's value directly via accessibility, no screenshot
      needed.
- [x] Toggle **Disable** back to its original state from the first step, so the session doesn't
      leave a real setting changed.

## Scenario -- device write is debounced 1s after a param settles, then read back and verified

Covers `ApplicationDelegate`'s `onDoubleTapParametersChange` (prints + immediate DB write on every
change, device write debounced through `DeviceWriteDebouncer`) and
`TimeFlipBLEDevice.setDoubleTapParameters`'s existing read-back verification (`0x17`). Snapshot the
current Threshold/Limit/Latency/Window values in `device_register_snapshot.json` first, per "Suppressing
incidental physical double-taps during a test session" in `../CLAUDE.md`, since this changes a real
physical accelerometer register, not just app state.

**Preconditions:** device connected and paired, Preferences open on the Device tab with the
Double tap disclosure expanded, **Disable** back to its original state -- the clean state the
previous scenario leaves behind (check `double_tap_settings.enabled` directly if running this
scenario standalone).

- [x] Snapshot the current values (`clickThreshold`/`limit`/`latency`/`window`) into
      `Tests/Bench/device_register_snapshot.json` under a timestamp-keyed
      `double_tap_params_as_at` object. (Snapshotted `ths=90 lim=20 lat=50 win=50`.)
- [x] Note the latest `debug_log_id`. In the Threshold field, type three distinct values in quick
      succession without tabbing away between them: `30`, then immediately `150`, then immediately
      `200`.
- [x] Query `debug_log` (tag `double-tap`) for rows newer than the noted ID and confirm a `"Params
      changed: ths=Xm ..."` + `"Params saved to DB: enabled=..."` pair for every intermediate
      value, ending at `ths=200`. (Confirmed: many intermediate pairs -- `numericField`'s
      get/set binding chain fires more than once per keystroke, an existing quirk unrelated to the
      debounce -- but the DB and final value are correct throughout.)
- [x] Confirm `double_tap_settings` already reads `"clickThreshold":200` immediately (before the 1s
      debounce elapses). (Confirmed.)
- [x] Wait about 1.5s, then query `debug_log` again and confirm exactly **one** `"Writing ths=200
      lim=20 lat=50 win=50"` line (not one per intermediate value), followed by `"Read ths=200
      lim=20 lat=50 win=50"` and `"Verification confirmed: requested ths=200 ...; actual ths=200
      ..."`. (Confirmed: `debug_log_id` 3594-3596, ~1s after the last Params-changed line.)
- [x] Restore Threshold to the original value noted in the snapshot (`90`) and confirm
      `double_tap_settings` reads `"clickThreshold":90` again.
