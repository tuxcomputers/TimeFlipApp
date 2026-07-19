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

**The reset step below is irreversible on real hardware, but does not need a live pause-and-confirm
before it** -- Setup's pre-flight (sync real device history to `production.sqlite` before switching
to the test DB) already guarantees nothing real is at risk. See "Switching to the test database
before testing" in `../CLAUDE.md`.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Setup

- [x] Confirm `db_type` currently reads `{"type":"production"}`, confirm the device is connected,
      and wait until a `history` fetch completes, so any real device history syncs to
      `production.sqlite` before anything below touches the device's state. (Confirmed production
      active and a periodic history fetch completed before switching.)
- [x] Quit the app if it's running (`osascript -e 'tell application "TimeFlip" to quit'`). Do not
      reset the device.
- [x] Run `scripts/use-test-database.sh`.
- [x] Start the app and confirm it reconnects to the already-paired device: query `debug_log` for a
      recent `TimeFlip`-tagged `"Login accepted, code=0x02"` row.
- [x] Query `db_type` and confirm it reads `{"type":"test"}` before proceeding. (Confirmed.)
- [x] Query `debug_log` for `history`-tagged rows logged since the restart and confirm a
      `trigger=startup` fetch ran. (Confirmed: `trigger=startup known_max=0`.)
- [x] Query `device_events` for the current max `event_number` and note it as **N** (the pre-reset
      baseline). (N = 64.)
- [x] Query `debug_log` for a `dev-check` row confirming `device_events max_start_epoch OK` logged
      after the backfill. (Confirmed.)

## Scenario -- factory reset resets the device's own event counter

- [x] Open Preferences (status-item menu -> "Preferences...") and switch to the Device tab (radio
      button 1 of the tab picker).
- [x] Click **Reset Device** and confirm the destructive-action dialog (button 2 of the sheet,
      identified via `description`, not `title`, which is `missing value` for these buttons).
- [x] Query `debug_log` for confirmation the reset succeeded. (Did **not** get the expected
      `TimeFlip`-tagged success row -- see "Bugs found and fixed" below. The reset genuinely
      succeeded on the device regardless, confirmed independently further down.)
- [x] Confirm the device's pairing/connection state. (Did **not** show "Not paired" as expected --
      showed "Reconnecting..." instead, then recovered straight to "Connected" via the automatic
      reconnect path once the bug below was fixed, without ever passing through "Not paired" or
      needing Forget Device/re-scan. See "Bugs found and fixed".)
- [x] ~~Click **Scan for Devices**, wait for the device to appear in the discovered-devices list,
      and click it to select and pair.~~ Not needed this run -- recovery happened via automatic
      reconnect (see below), not fresh pairing. The device never stopped being "paired" from the
      app's perspective.
- [x] Confirm the Device tab shows the device as paired and connected again: read the `Connection`
      row's value, and query `debug_log` for a fresh `"Login accepted, code=0x02"` row. (Confirmed:
      `Connection` = `Connected`, fresh `Login accepted, code=0x02` logged after the fix.)
- [x] Confirm the device's own event counter was wiped by the reset. `MAX(event_number)` in our
      local `device_events` table still reads the pre-reset value (64) -- expected, since a device
      reset doesn't retroactively delete rows we'd already recorded locally before it happened.
      What actually reflects the device's *live* counter is the `history` fetch's
      `device_last_event=` value, which read `nil` on every fetch after reconnecting -- consistent
      with a wiped counter (no events at all yet, rather than resuming from 64). (Seeing a *real*
      post-reset event with the device's own low numbering needs a physical flip -- that's the
      Interactive counterpart.)
- [x] Query `debug_log` for the `history`-tagged fetch that ran on re-pair and confirm
      `device_last_event=nil` (not resuming from the pre-reset baseline), backing the counter wipe
      with logged evidence, not just the queried row. (Confirmed, repeatedly, across several
      periodic fetches after reconnecting.)
- [x] **Stronger, more direct evidence surfaced later** (during `04-lock-and-pause-on-lock-checklist.md`,
      run afterward in the same session): the device eventually generated real events again, and
      they started from `event_number = 1`, then `2`, not resuming anywhere near the pre-reset
      baseline **N** (64) -- direct proof of the wipe, not just an absence-of-events inference.

### Bugs found and fixed
2026-07-19 - The device drops its BLE connection right after accepting the `0xFF` reset command (a
real reboot), and `factoryReset()`'s own immediate re-login confirmation can race that disconnect
and get an explicit rejection before the reboot completes -- so it reports the reset as
NOT confirmed even though it genuinely succeeded, and never calls `forgetDevice()`. The app's
automatic reconnect then retries the stale pre-reset password forever with no recovery path in the
UI (Forget Device and Reset Device both silently no-op while not logged in). Fixed by adding a
fallback in the reconnect login path (`ApplicationDelegate.startDeviceEvents`): when the stored
password is explicitly rejected (`TimeFlipBLEDevice.wasWrongPassword`, new) and isn't already the
factory default, retry with the default before giving up, then persist whichever password actually
worked -- same reasoning already used for a freshly-selected device during pairing. Verified live:
recovered the actual stuck device, and the following reconnect used the recovered password directly
with no further fallback needed.
2026-07-19 - While investigating the above, also directly verified (at the user's request, a
device/security check rather than a code test) that the device correctly rejects an arbitrary wrong
password (`999999`) with an explicit `commandResult` rejection rather than silently accepting it --
no security concern found.
