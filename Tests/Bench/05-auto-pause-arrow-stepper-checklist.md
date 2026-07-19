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

This bench file covers only what a harness can drive against a connected device: typing a value into
the field and confirming it lands in the DB. The real **press-and-hold acceleration gesture** (and
the window-closed-mid-hold case), which needs a person holding the mouse button, lives in
`Tests/Interactive/05-auto-pause-arrow-stepper-checklist.md`, run after this one.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Setup

- [ ] **(You)** Quit the app if it's running.
- [ ] **(Claude)** Run `scripts/use-test-database.sh`.
- [ ] **(You)** Start the app and confirm it reconnects to the device.
- [ ] **(Claude)** Query `db_type` and confirm it reads `{"type":"test"}` before proceeding:
      `sqlite3 ~/Library/Application\ Support/TimeFlip/appdata.sqlite "SELECT setting_value FROM
      setting WHERE setting_name = 'db_type';"`.
- [ ] **(You)** Open Preferences, Device tab. Confirm **Auto-pause** sits at the top of the
      **Settings** section, above the collapsed **LED** disclosure (not inside a separate
      **Advanced** section, which no longer exists).

## Scenario -- typing a value into the field persists to the DB

- [ ] **(Claude)** Type `4` directly into the auto-pause text field and confirm the DB row updated:
      `SELECT setting_value FROM setting WHERE setting_name = 'auto_pause_minutes';` should read
      `{"minutes":4}`.
- [ ] **(Claude)** Type `26` into the field and confirm the same row now reads `{"minutes":26}`.
- [ ] **(Claude)** Type `0` into the field and confirm the row reads `{"minutes":0}`, leaving
      auto-pause disabled for the next run.
