# Reset Device Checklist

Covers the Device tab's **Reset Device** button (factory reset, command `0xFF`) -- confirms it
actually wipes the device's own event-number counter, not just app-side/DB state, by comparing the
device's event numbering before and after a real reset. A confirmed reset also unpairs the app
from the device (`TimeFlipBLEDevice.factoryReset()` only returns success once it verifies via a
real re-login with the factory default password, and `AppState.forgetDevice()` only runs after
that), so this also exercises fresh re-pairing afterward.

Every step here is Claude-driven against a connected device -- launching/quitting the app, driving
Preferences-window controls via System Events, and reading `sqlite3`/`debug_log` -- see "Driving
the app directly" in `../CLAUDE.md` for the verified mechanics. The one part that requires a
physical facet flip (generating a *real* post-reset event to see the device's own low numbering)
lives in `Tests/Interactive/01-reset-device-checklist.md`, run after this one.

**Do not reset the device before this checklist starts** -- the reset is the test itself, not
setup. Requires Developer Mode enabled, the `debug` setting's `enabled` field `true` (see
`009_setting.sql`), and a device that is *already paired*, with some pre-existing event history on
it, going into Setup below.

**The reset step below is irreversible on real hardware.** Even though it's just another scripted
click, pause and get the user's explicit go-ahead immediately before clicking Reset Device, every
time -- don't click through it unattended.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Setup

- [ ] Quit the app if it's running (`osascript -e 'tell application "TimeFlip" to quit'`). Do not
      reset the device.
- [ ] Run `scripts/use-test-database.sh`.
- [ ] Start the app and confirm it reconnects to the already-paired device: query `debug_log` for a
      recent `TimeFlip`-tagged `"Login accepted, code=0x02"` row.
- [ ] Query `db_type` and confirm it reads `{"type":"test"}` before proceeding:
      `sqlite3 ~/Library/Application\ Support/TimeFlip/appdata.sqlite "SELECT setting_value FROM
      setting WHERE setting_name = 'db_type';"`.
- [ ] Query `debug_log` for `history`-tagged rows logged since the restart and confirm a
      `trigger=startup` fetch ran -- this is the device's real, pre-existing event history being
      read fresh into `test.sqlite` for the first time.
- [ ] Query `device_events` for the current max `event_number` and note it as **N** (the pre-reset
      baseline).
- [ ] Query `debug_log` for a `dev-check` row confirming `device_events max_start_epoch OK` logged
      after the backfill, so the baseline is backed by logged evidence, not just the queried row.

## Scenario -- factory reset resets the device's own event counter

- [ ] Open Preferences (status-item menu -> "Preferences...") and switch to the Device tab (radio
      button 1 of the tab picker).
- [ ] **Pause here and get the user's explicit go-ahead before continuing** -- the next step
      factory-resets the physical device and cannot be undone.
- [ ] Click **Reset Device** and confirm the destructive-action dialog.
- [ ] Query `debug_log` for a `TimeFlip`-tagged row confirming the reset succeeded (re-login with
      the factory default password accepted).
- [ ] Confirm the Device tab now shows **Not paired**: read the `Connection` row's static text
      value via accessibility (no screenshot needed -- see "Driving the app directly").
- [ ] Click **Scan for Devices**, wait for the device to appear in the discovered-devices list, and
      click it to select and pair.
- [ ] Confirm the Device tab shows the device as paired and connected again: read the `Connection`
      row's value, and query `debug_log` for a fresh `"Login accepted, code=0x02"` row.
- [ ] Query `device_events` for the max `event_number` now and confirm it is `0` -- reconnecting
      alone generates no event, so a wiped counter reads `0` here, far below the pre-reset baseline
      **N** from Setup. (Seeing a *real* post-reset event with the device's own low numbering needs
      a physical flip -- that's the Interactive counterpart.)
- [ ] Query `debug_log` for the `history`-tagged fetch that ran on re-pair and confirm its
      `device_last_event=0` (down from the pre-reset baseline), backing the counter wipe with
      logged evidence, not just the queried row.
