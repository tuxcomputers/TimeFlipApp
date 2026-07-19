# Auto-Pause Arrow Stepper Checklist

Covers the auto-pause field's press-and-hold arrow behavior (`AutoPauseStepper`): ticks by 1 until
passing the *second* multiple-of-5 gridline from the value the hold started at, then by 5, at a
slower tick rate. This replaced a stock SwiftUI `Stepper` (whose held-repeat rate can't be varied).
Also covers a fix for a hold whose release event never arrives (window closed while the mouse button
was still down), which would otherwise keep the repeat loop -- and its device/DB writes -- running
in the background. Requires Developer Mode enabled and a paired, connected device (the field is
disabled while unpaired).

**Automated coverage:** the full tick sequence and slower-past-the-second-boundary timing are
unit-tested in `Tests/TimeFlipAppTests/AutoPauseStepperTests.swift`, the `auto_pause_minutes` DB
round-trip in `SettingsPersistenceTests.swift`, and the hold-cancel-on-window-close in
`AppStateDeviceTabTests.swift`.

This bench file covers what's Claude-drivable against a connected device: typing a value into the
field and confirming it lands in the DB. The real **press-and-hold acceleration gesture** (and the
window-closed-mid-hold case) needs a person to actually hold the mouse button down -- System
Events can click a control but not sustain a held mouse-down/up over time -- and lives in
`Tests/Interactive/05-auto-pause-arrow-stepper-checklist.md`, run after this one.

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
      button 1 of the tab picker). Confirm **Auto-pause** sits at the top of the **Settings**
      section, above the collapsed **LED** disclosure (not inside a separate **Advanced** section,
      which no longer exists) -- read the ordering of static text/control elements in that section
      via accessibility (see "Driving the app directly" in `../CLAUDE.md`).

## Scenario -- typing a value into the field persists to the DB

**Preconditions:** device connected and paired, Preferences open on the Device tab with Auto-pause
visible -- established in Setup immediately above, which this scenario runs straight on from.

- [x] Type `4` directly into the auto-pause text field and confirm the DB row updated:
      `SELECT setting_value FROM setting WHERE setting_name = 'auto_pause_minutes';` should read
      `{"minutes":4}`.
- [x] Type `26` into the field and confirm the same row now reads `{"minutes":26}`.
- [x] Type `0` into the field and confirm the row reads `{"minutes":0}`, leaving auto-pause
      disabled for the next run.

## Scenario -- device write is debounced 1s after the value settles, then read back and verified

Covers `ApplicationDelegate`'s `onAutoPauseChange` (prints + immediate DB write on every change,
device write debounced through `DeviceWriteDebouncer`) and `TimeFlipBLEDevice.setAutoPause`'s
read-back verification (`0x10` status), added alongside the debounce.

**Preconditions:** device connected and paired, Preferences open on the Device tab with the
auto-pause field focusable -- left in place by the previous scenario, which also leaves
`auto_pause_minutes` at `0`, though this scenario overwrites that value immediately anyway.

- [x] Note the latest `debug_log_id`. Type three distinct values into the field in quick
      succession without tabbing away between them (`tab` shifts focus off the field, breaking the
      sequence -- select-all + type commits live on every keystroke already, no `tab` needed): `7`,
      then immediately `70`, then immediately `150`. (Confirmed: typing `150` after `70` landed as
      select-all -> `1` -> `15` -> `150`, i.e. 5 distinct intermediate values in total: `7`, `70`,
      `1`, `15`, `150`.)
- [x] Query `debug_log` (tag `auto-pause`) for rows newer than the noted ID and confirm a
      `"Auto-pause value changed to Xm"` + `"Auto-pause saved to DB: Xm"` pair for **each**
      intermediate value, in order -- the print+DB-write side is immediate and untouched by the
      debounce. (Confirmed: all 5 pairs present, e.g. `debug_log_id` 3363-3372.)
- [x] Confirm `auto_pause_minutes` already reads `{"minutes":150}` immediately (before the 1s
      debounce elapses) -- the DB write never waited on the debounce. (Confirmed.)
- [x] Wait about 1.5s, then query `debug_log` again and confirm exactly **one**
      `"Auto-pause set to 150m triggered"` line appears (not one per intermediate value), timestamped
      roughly 1s after the last (`150`) change, followed by `"Auto-pause verification confirmed:
      requested=150m actual=150m"`. (Confirmed: single triggered/confirmed pair at `debug_log_id`
      3373-3374, one second after the last value-changed line at 19:47:35 -> 19:47:36.)
- [x] Type `0` into the field (single change, not part of a rapid sequence) and confirm after ~1.5s
      the same pattern: one triggered/confirmed pair for `0m`, leaving auto-pause disabled for the
      next run. (Confirmed: `debug_log_id` 3390-3391, `auto_pause_minutes` reads `{"minutes":0}`.)
