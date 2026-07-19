# Reset Device Checklist

Covers the Device tab's **Reset Device** button (factory reset, command `0xFF`) -- confirms it
actually wipes the device's own event-number counter, not just app-side/DB state, by comparing the
device's event numbering before and after a real reset. A confirmed reset also unpairs the app
from the device (`TimeFlipBLEDevice.factoryReset()` only returns success once it verifies via a
real re-login with the factory default password, and `AppState.forgetDevice()` only runs after
that), so this also exercises fresh re-pairing afterward.

Every step here is script-drivable against a connected device -- the reset and re-pair are
Preferences-window controls, and the assertions are `sqlite3`/`debug_log` reads -- so no human
eyes or hands on the physical cube are needed. The one part that requires a physical facet flip
(generating a *real* post-reset event to see the device's own low numbering) lives in
`Tests/Interactive/01-reset-device-checklist.md`, run after this one.

**Do not reset the device before this checklist starts** -- the reset is the test itself, not
setup. Requires Developer Mode enabled, the `debug` setting's `enabled` field `true` (see
`009_setting.sql`), and a device that is *already paired*, with some pre-existing event history on
it, going into Setup below.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Setup

- [ ] **(You)** Quit the app if it's running. Do not reset the device.
- [ ] **(Claude)** Run `scripts/use-test-database.sh`.
- [ ] **(You)** Start the app and confirm it reconnects to the already-paired device.
- [ ] **(Claude)** Query `db_type` and confirm it reads `{"type":"test"}` before proceeding:
      `sqlite3 ~/Library/Application\ Support/TimeFlip/appdata.sqlite "SELECT setting_value FROM
      setting WHERE setting_name = 'db_type';"`.
- [ ] **(Claude)** Query `debug_log` for `history`-tagged rows logged since the restart and confirm
      a `trigger=startup` fetch ran -- this is the device's real, pre-existing event history being
      read fresh into `test.sqlite` for the first time.
- [ ] **(Claude)** Query `device_events` for the current max `event_number` and note it as **N**
      (the pre-reset baseline).
- [ ] **(Claude)** Query `debug_log` for a `dev-check` row confirming `device_events
      max_start_epoch OK` logged after the backfill, so the baseline is backed by logged evidence,
      not just the queried row.

## Scenario -- factory reset resets the device's own event counter

### Action needed
1. Open Preferences, Device tab, **TimeFlip** section.
2. Click **Reset Device** and confirm the destructive-action dialog.

- [ ] **(You)** Confirm you completed the reset and its confirmation dialog.
- [ ] **(Claude)** Query `debug_log` for a `TimeFlip`-tagged row confirming the reset succeeded
      (re-login with the factory default password accepted).
- [ ] **(You)** Confirm the Device tab now shows **Not paired**.

### Action needed
Re-pair with the device: click **Scan for Devices**, select it once it appears in the list, and
wait for pairing to complete.

- [ ] **(You)** Confirm the Device tab shows the device as paired and connected again.
- [ ] **(Claude)** Query `device_events` for the max `event_number` now and confirm it is `0` --
      reconnecting alone generates no event, so a wiped counter reads `0` here, far below the
      pre-reset baseline **N** from Setup. (Seeing a *real* post-reset event with the device's own
      low numbering needs a physical flip -- that's the Interactive counterpart.)
- [ ] **(Claude)** Query `debug_log` for the `history`-tagged fetch that ran on re-pair and confirm
      its `device_last_event=0` (down from the pre-reset baseline), backing the counter wipe with
      logged evidence, not just the queried row.
