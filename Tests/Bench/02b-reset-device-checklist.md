# Reset Device Checklist

### Last run - 2026-07-22 on the branch 'feature/projects'

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
Preferences-window controls via System Events, and reading `sqlite3`/`debug_log` -- see
`../Methods.md` for the verified mechanics. The one part that requires a physical facet flip
(generating a *real* post-reset event to see the device's own low numbering) lives in
`Tests/Interactive/02i-reset-device-checklist.md`, run after the whole Bench phase.

**Do not reset the device before this checklist starts** -- the reset is the test itself, not
setup. Requires Developer Mode enabled, the `debug` setting's `enabled` field `true` (see
`011_setting.sql`), and a device that is *already paired*, with some pre-existing event history on
it, going into Setup below.

**Runs after `01b-history-refresh-checklist.md`, deliberately** -- that checklist's own Setup is
what does the production-history-sync-then-switch-to-test-database pre-flight (Method: Switch to
the test database, `../Methods.md`); this file just confirms the test DB is still active rather
than repeating that pre-flight. The reset step below is irreversible on real hardware, but doesn't
need a live pause-and-confirm before it -- `01b`'s pre-flight already synced real device history to
`production.sqlite` first, so nothing real is at risk.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Setup

- [x] Confirm `db_type` still reads `{"type":"test"}` (left active by `01b-history-refresh-checklist.md`)
      and the device is connected. If it reads `production`, `01b`'s Setup needs (re-)running first
      rather than switching databases from here. (Confirmed: `{"type":"test"}`, device connected.)
```toml step
action = "sql_query"
query = "SELECT setting_value FROM setting WHERE setting_name='db_type';"
expect = "{\"type\":\"test\"}"
```
- [x] Note the device's current event counter as **N** (the pre-reset baseline): query
      `device_event` by `device_event_id DESC` for the latest `event_number`, and/or read a
      `history` fetch's `device_last_event=`. **N** must be > 0 -- `01b`'s Setup backfill should
      already guarantee this. (Note: `device_event` has no timestamp column named `logged_at` --
      use `start_epoch`/`start_time` if a time is needed, or omit entirely and just order by
      `device_event_id DESC`.) (Confirmed: N=13.)
```toml step
action = "sql_query"
query = "SELECT event_number FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
capture = "n_pre_reset"
```

## Scenario A -- factory reset wipes the device's own event counter and ends never-paired

**Preconditions:** test DB active, device paired and connected, pre-reset baseline **N** (> 0)
noted -- all established immediately above in Setup, which this scenario runs straight on from.

- [x] Open Settings (status-item menu -> "Settings...") and switch to the Device tab (radio
      button 1 of the tab picker). Method: Click a status-item menu item, Switch Settings-window
      tabs (`../Methods.md`). (Note: on this branch the menu item is "Settings..." and the other
      tabs are "Faces"/"App" -- it is based on `main`, which includes the settings-rename merge;
      the Device tab is still radio button 1.) (Confirmed via screenshot: Device tab open, Name
      `TimeFlip`, Connection `Connected`, Battery `23%`.)
```toml step
[[actions]]
action = "click_menu_item"
item = "Settings..."

[[actions]]
action = "shell"
command = "sleep 1.5"

[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        click radio button 1 of radio group 1 of group 1 of toolbar 1 of window "TimeFlip Settings"
    end tell
end tell'''
```
- [x] Click **Reset Device** (`AXButton` in the pairing section's `AXGroup`, right of **Forget
      Device**) and confirm the destructive-action dialog. Method: Confirm a confirmation-dialog
      sheet (`../Methods.md`) -- **Cancel** is button 1, **Reset Device** (the destructive confirm)
      is button 2. **Both fully Claude-driven** this run, contradicting the previous run's note that
      System Events driving hung. (Confirmed: sheet detected via `count of sheets of win = 1`,
      description read `Cancel`/`Reset Device`, click succeeded with no hang.)
```toml step
[[actions]]
action = "sql_query"
query = "SELECT MAX(debug_log_id) FROM debug_log;"
capture = "before_reset_id"

[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        click button 2 of group 3 of scroll area 1 of group 1 of window "TimeFlip Settings"
        delay 0.5
        click button 2 of sheet 1 of window "TimeFlip Settings"
    end tell
end tell'''
```
- [x] Confirm the reset sequence via `debug_log` (`TimeFlip` tag): a
      `"Factory reset (0xFF) sent; ... awaiting device reboot to confirm via default-password login"`
      row, then reconnect/login attempts, then
      `"Factory reset confirmed: device is back on the default password; returning to never-paired state"`.
      (Confirmed, including the expected transient: `0xFF` sent with stale read-back
      `17 3A 5A 3B 14 3C 32 3D 32 00 ...`; reconnect #1 accepted the OLD password `123456` -> logged
      `"Factory reset not yet confirmed: device still accepts the old password; retrying"`; reconnect
      #2 rejected `123456` (`0x01`), accepted `000000` (`0x02`) -> `"Factory reset confirmed ...
      returning to never-paired state"`.)
```toml step
[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Factory reset (0xFF) sent%' AND debug_log_id > $before_reset_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Factory reset (0xFF) sent"
timeout_seconds = 15

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Factory reset confirmed%' AND debug_log_id > $before_reset_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Factory reset confirmed: device is back on the default password; returning to never-paired state"
timeout_seconds = 60
```
- [x] Confirm the UI reaches the pristine never-paired state. During the confirm window the
      `Connection` row reads `Resetting...` (the Forget/Reset buttons replaced by a "Resetting
      device…" progress row); it then settles with `Name` = `Not paired`, `Connection` = `Not
      paired`, and `Battery` = `Not paired` (all greyed). It must **not** end on `Reconnecting...`
      or `Connected`. (Confirmed via accessibility `value` reads of the three rows -- `Not paired` /
      `Not paired` / `Not paired`.)
```toml step
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        set n to value of static text 2 of group 1 of scroll area 1 of group 1 of window "TimeFlip Settings"
        set c to value of static text 4 of group 1 of scroll area 1 of group 1 of window "TimeFlip Settings"
    end tell
end tell
return n & "|" & c'''
expect_contains = "Not paired"
```
- [x] Confirm no auto-reconnect follows the forget: no further `TimeFlip` `"Login accepted"` /
      reconnect rows after the `"returning to never-paired state"` row, until the manual re-pair
      below. (Confirmed: zero `"Login accepted"` rows between the confirmation and the manual
      re-pair. Unlike the old flow, the app also **stops** its periodic `history` fetches once
      forgotten, so no `device_last_event` rows appear in this gap either -- the wipe evidence
      instead comes from the re-pair's startup fetch below.)
```toml step
action = "sql_query"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Login accepted%' AND debug_log_id > $before_reset_id ORDER BY debug_log_id DESC LIMIT 1;"
expect = "(no rows)"
```
- [x] Confirm the device's own event counter was wiped by the reset: the first `history` fetch after
      re-pairing reads `device_last_event=nil` (a wiped counter with no events yet), not resuming
      from the pre-reset baseline **N**. (`MAX(event_number)` in the local `device_event` table
      still reads old rows -- a reset doesn't delete rows recorded locally before it -- so query by
      `device_event_id DESC`, and rely on the live `device_last_event=nil` for the wipe evidence.
      Seeing a *real* post-reset event with the device's own low numbering needs a physical flip --
      that's the Interactive counterpart.) (Confirmed: post-re-pair fetch read `device_last_event=nil`
      where N was `13` pre-reset -- the device's own counter was wiped.)
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='history' AND debug_log_id > $before_reset_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "device_last_event=nil"
timeout_seconds = 30
```
- [x] Click **Scan for Devices** and wait for the device to appear in the discovered-devices list
      (`static text` matching the device name, e.g. `"TimeFlip v2.0"`, under "Click a device below to
      pair with it."). Method: Click a button, checkbox, or slider (`../Methods.md`). (Confirmed:
      `"TimeFlip v2.0"` appeared in the list within a few seconds.)
```toml step
[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        click button 1 of group 3 of scroll area 1 of group 1 of window "TimeFlip Settings"
    end tell
end tell'''

[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        delay 2
        return name of every static text of group 3 of scroll area 1 of group 1 of window "TimeFlip Settings"
    end tell
end tell'''
expect_contains = "TimeFlip"
```
- [x] Click the discovered device's row to select and pair (it is on the factory default PIN
      `000000` now). Method: Discovered-device row click -- not automatable (`../Methods.md`); ask
      the user ad hoc (a large `## Action needed` heading, per "Running a checklist" rule 3 in
      `../CLAUDE.md`). Confirm a fresh `TimeFlip`-tagged `"Login accepted, code=0x02"` row (Method:
      Confirm device reconnect) -- detected by polling `debug_log`, not waiting on chat confirmation
      (Method: Detect a physical action instead of asking, `../Methods.md`). (Confirmed: user clicked
      the row; paired with `000000` (`Login accepted 0x02`), then the pairing flow rotated the
      password to `123456` and re-confirmed, followed by the usual device-sync of
      auto-pause/LED/double-tap.)
```toml step
action = "ask_user_or_detect"
prompt = "Click the discovered device's row in the Device tab to pair it (this can't be scripted -- it's a plain Text+onTapGesture, not a Button)."
detect_query = "SELECT debug_log_id FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Login accepted%' ORDER BY debug_log_id DESC LIMIT 1;"
timeout_seconds = 120
poll_interval = 2
```
- [x] Confirm the Device tab shows the device paired and connected again: read the `Connection` row
      (`Connected`), `Name` (the device name, no longer "Not paired"), and `Battery` (a `%`, no
      longer "Not paired"). (Confirmed: `Name`=`TimeFlip`, `Connection`=`Connected`, `Battery`=`23%`.)
```toml step
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        return value of static text 4 of group 1 of scroll area 1 of group 1 of window "TimeFlip Settings"
    end tell
end tell'''
expect = "Connected"
```
