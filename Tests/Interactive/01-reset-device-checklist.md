# Reset Device Checklist

Covers the Device tab's **Reset Device** button (factory reset, command `0xFF`) -- confirms it
actually wipes the device's own event-number counter, not just app-side/DB state, by comparing the
device's event numbering before and after a real reset. A confirmed reset also unpairs the app
from the device (`TimeFlipBLEDevice.factoryReset()` only returns success once it verifies via a
real re-login with the factory default password, and `AppState.forgetDevice()` only runs after
that), so this also exercises fresh re-pairing afterward.

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
- [ ] **(Claude)** Query `device_events` for the max `event_number` now. If it's still 0 (no event
      generated yet -- reconnecting alone doesn't create one), ask the user to flip the device to a
      different facet once, then re-query.
- [ ] **(Claude)** Confirm this new event's `event_number` is a small number close to the device's
      own reset baseline -- **1** is expected, but **2** or **3** is also a pass if the device was
      flipped quickly enough right around the reset for an intermediate event to be skipped -- and
      confirm it is far lower than the pre-reset baseline **N** from Setup either way.
- [ ] **(Claude)** Query `debug_log` for the `history`-tagged fetch that picked up this new event
      and a following `dev-check` row confirming `device_events max_start_epoch OK`, so the
      post-reset event number is backed by logged evidence, not just the queried row.
