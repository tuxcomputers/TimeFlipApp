# Reset Device Checklist

### Last run - 2026-07-20 on the branch 'bugfix/resetDevice'

Covers the Device tab's **Reset Device** button (factory reset, command `0xFF`) -- confirms it
actually wipes the device's own event-number counter, not just app-side/DB state, by comparing the
device's event numbering before and after a real reset. A reset intentionally ends with the device
**forgotten / "Not paired"**: `TimeFlipBLEDevice.factoryReset()` just *sends* 0xFF (the device gives
no usable ack and reboots), then the app reconnects, and a successful re-login with the factory
default password confirms the wipe -- that login is deliberately **not** treated as a pairing, so
the app drops the connection into the pristine never-paired state ("Resetting..." -> "Not paired").
Continuing to use the device therefore requires a fresh Scan/re-pair, which this checklist also
exercises.

Every step here is Claude-driven against a connected device -- launching/quitting the app, driving
Preferences-window controls via System Events, and reading `sqlite3`/`debug_log` -- see "Driving
the app directly" in `../CLAUDE.md` for the verified mechanics. The one part that requires a
physical facet flip (generating a *real* post-reset event to see the device's own low numbering)
lives in `Tests/Interactive/01-reset-device-checklist.md`, run after this one.

**Do not reset the device before this checklist starts** -- the reset is the test itself, not
setup. Requires Developer Mode enabled, the `debug` setting's `enabled` field `true` (see
`010_setting.sql`), and a device that is *already paired*, with some pre-existing event history on
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
      active and connected -- a periodic `history` fetch read `device_last_event=6` and completed
      `DB refreshed` before switching.)
- [x] Quit the app if it's running (`osascript -e 'tell application "TimeFlip" to quit'`). Do not
      reset the device.
- [x] Run `scripts/use-test-database.sh`.
- [x] Start the app and confirm it connects to the device: query `debug_log` for a recent
      `TimeFlip`-tagged `"Login accepted, code=0x02"` row. (If the device is on the factory default
      password from an earlier reset, the app's default-password fallback logs in with `000000`.)
      (Confirmed: fresh `Login accepted, code=0x02` on relaunch.)
- [x] Query `db_type` and confirm it reads `{"type":"test"}` before proceeding. (Confirmed.)
- [x] Query `debug_log` for `history`-tagged rows logged since the restart and confirm a
      `trigger=startup` fetch ran. (Confirmed: `trigger=startup known_max=0`.)
- [x] Note the device's current event counter as **N** (the pre-reset baseline): query
      `device_events` by `device_events_id DESC` for the latest `event_number`, and/or read a
      `history` fetch's `device_last_event=`. **N** must be > 0; if the device has no events yet,
      flip it once first to create one (that single flip is the only physical action Setup needs).
      (**N = 6** -- `device_last_event=6`, `device_events` max `event_number=6`; no Setup flip
      needed, the device already had history.)
- [x] Query `debug_log` for a `dev-check` row confirming `device_events max_start_epoch OK` logged
      after the backfill. (Confirmed.)

## Scenario -- factory reset wipes the device's own event counter and ends never-paired

**Preconditions:** test DB active, device paired and connected, pre-reset baseline **N** (> 0)
noted -- all established immediately above in Setup, which this scenario runs straight on from.

- [x] Open Preferences (status-item menu -> "Settings...") and switch to the Device tab (radio
      button 1 of the tab picker). (Note: on this branch the menu item is "Settings..." and the
      other tabs are "Faces"/"App" -- it is based on `main`, which includes the settings-rename
      merge; the Device tab is still radio button 1.)
- [x] Click **Reset Device** and confirm the destructive-action dialog. (Driven by the user this
      run -- System Events driving hung, so the operator clicked while Claude verified via
      `debug_log`; the mechanics below are all Claude-verified.)
- [x] Confirm the reset sequence via `debug_log` (`TimeFlip` tag): a
      `"Factory reset (0xFF) sent; ... awaiting device reboot to confirm via default-password login"`
      row, then reconnect/login attempts, then
      `"Factory reset confirmed: device is back on the default password; returning to never-paired state"`.
      (Confirmed, including the expected transient: `0xFF` sent with stale read-back
      `17 3A 5A 3B 14 3C 32 3D 32 ...`; reconnect #1 accepted the OLD password `123456` -> logged
      `"Factory reset not yet confirmed: device still accepts the old password; retrying"`; reconnect
      #2 rejected `123456` (`0x01`), accepted `000000` (`0x02`) -> `"Factory reset confirmed ...
      returning to never-paired state"`.)
- [x] Confirm the UI reaches the pristine never-paired state. During the confirm window the
      `Connection` row reads `Resetting...` (the Forget/Reset buttons replaced by a "Resetting
      device…" progress row); it then settles with `Name` = `Not paired`, `Connection` = `Not
      paired`, and `Battery` = `Not paired` (all greyed). It must **not** end on `Reconnecting...`
      or `Connected`. (Operator confirmed the `Connection` passed through "Resetting..." and settled
      on "Not paired", and the Battery greyed to "Not paired" as expected.)
- [x] Confirm no auto-reconnect follows the forget: no further `TimeFlip` `"Login accepted"` /
      reconnect rows after the `"returning to never-paired state"` row, until the manual re-pair
      below. (Confirmed: zero `"Login accepted"` rows between the confirmation and the manual
      re-pair. Unlike the old flow, the app also **stops** its periodic `history` fetches once
      forgotten, so no `device_last_event` rows appear in this gap either -- the wipe evidence
      instead comes from the re-pair's startup fetch below.)
- [x] Confirm the device's own event counter was wiped by the reset: the first `history` fetch after
      re-pairing reads `device_last_event=nil` (a wiped counter with no events yet), not resuming
      from the pre-reset baseline **N**. (`MAX(event_number)` in the local `device_events` table
      still reads old rows -- a reset doesn't delete rows recorded locally before it -- so query by
      `device_events_id DESC`, and rely on the live `device_last_event=nil` for the wipe evidence.
      Seeing a *real* post-reset event with the device's own low numbering needs a physical flip --
      that's the Interactive counterpart.) (Confirmed: post-re-pair fetch read `device_last_event=nil`
      where it had read `6` pre-reset -- the device's own counter was wiped.)
- [x] Re-pair the forgotten device: click **Scan for Devices**, wait for the device to appear in the
      discovered-devices list, and click it to select and pair (it is on the factory default PIN
      `000000` now). Confirm a fresh `TimeFlip`-tagged `"Login accepted, code=0x02"` row. (Confirmed:
      paired with `000000` (`Login accepted 0x02`), then the pairing flow rotated the password to
      `123456` and re-confirmed, followed by the usual device-sync of auto-pause/LED/double-tap.)
- [x] Confirm the Device tab shows the device paired and connected again: read the `Connection` row
      (`Connected`), `Name` (the device name, no longer "Not paired"), and `Battery` (a `%`, no
      longer "Not paired"). (Operator confirmed the device paired and connected again.)
