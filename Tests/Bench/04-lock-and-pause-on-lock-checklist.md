# Lock / pause_on_lock Checklist (Bench)

Covers the app's own "Lock"/"Unlock"/"Pause"/"Resume" status-item **menu** actions
(`MenuBarController`/`ApplicationDelegate.handleLockRequest`) and the `pause_on_lock` setting, for
the scenarios that use only menu clicks and DB-verifiable state -- no status-item gesture
(single/double-click on the right half) and no physical device flip, so all three are fully
Claude-drivable via the verified status-item-menu mechanic (see "Driving the app directly" in
`../CLAUDE.md`). Scenario A and B were originally Scenario C and D of a single combined checklist;
Scenario C was originally Scenario E, with "is the time increasing?" converted from a `(You)`
menu-bar observation to a DB check (the same still-open event's `duration_seconds` growing) --
proving the same fact without needing eyes on the screen. Scenario A, B in
`Tests/Interactive/04-lock-and-pause-on-lock-checklist.md` still need the status-item gesture
(unverified via script) or a physical flip, and assume the clean, unlocked/unpaused state this
file's last scenario leaves behind.

Despite the setting's name, `pause_on_lock` has **nothing to do with the Mac's screen locking or
sleeping** -- it only controls whether *this app's own* Lock action (menu item, or the
status-item's double-click gesture) also pauses the device first, and whether **quitting the app**
does the same. There is also no auto-resume: once paused via Lock/Quit, the device stays paused
until manually resumed (Pause menu item, or a physical double-tap) -- Unlock alone does not resume
it. Unlike `low_battery_level`/`fetch_history_interval_seconds`, `pause_on_lock` is read live from
SQLite on every Lock/Quit action (`AppDataStore.loadPauseOnLockEnabled()`) -- no app restart needed.

Requires Developer Mode enabled, the `debug` setting's `enabled` field `true` (so `.timeFlip`-tagged
debug prints land in `debug_log`), and a paired, connected device.

Lock and pause state are both visible directly in the menu bar status item: a red lock badge
appears to the left of the activity indicator while locked, and that indicator itself is a pause
icon (⏸) while paused or a play icon (▶) while running -- read via accessibility/screenshot, no
menu needs to be open for these two. Reading the menu item's own text/enabled state needs the menu
open first.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Setup

- [ ] Query the current `pause_on_lock` value: `sqlite3 ~/Library/Application\
      Support/TimeFlip/appdata.sqlite "SELECT setting_value FROM setting WHERE setting_name =
      'pause_on_lock';"` and note it as the original value to restore later.
- [ ] Query the device's current lock/pause state from the most recent `device_events` row
      (`SELECT device_events_id, event_number, is_paused, finalised FROM device_events ORDER BY
      device_events_id DESC LIMIT 1;`) and from the status-item menu's item names whether it
      currently shows "Lock" or "Unlock". If the device is currently paused or locked, resolve that
      first (click Resume / Unlock via the menu) so the scenarios below start from a clean
      unlocked, unpaused state.

## Scenario A -- Lock also pauses when pause_on_lock is enabled, and Unlock does not auto-resume

- [ ] Set `pause_on_lock` to `true`: `sqlite3 ~/Library/Application\ Support/TimeFlip/appdata.sqlite
      "UPDATE setting SET setting_value = '{\"enabled\":true}' WHERE setting_name =
      'pause_on_lock';"`.
- [ ] Screenshot the menu bar; confirm the status item shows the play icon (▶) -- device not
      already paused.
- [ ] Click the "Lock" menu item.
- [ ] Confirm a new `is_paused = 1` device_events row was written (the pause that Lock triggered),
      and that `debug_log` shows `"Lock ON triggered"` followed by `"Lock verification confirmed:
      requested=ON actual=ON"`.
- [ ] Screenshot the menu bar; confirm the lock badge is now shown and the icon switched to pause
      (⏸) -- confirming Lock paused the device before locking it.
- [ ] Open the menu; confirm the item reads "Unlock" and the Pause item is disabled (can't manually
      toggle pause while locked).
- [ ] Click "Unlock".
- [ ] Confirm the device is still paused after unlocking -- no new `is_paused = 0` row appears in
      `device_events` from the unlock action itself (there is no auto-resume).
- [ ] Screenshot the menu bar; confirm the lock badge is gone but the icon still shows pause (⏸) --
      unlocking alone did not resume it.
- [ ] Open the menu; confirm the item reads "Lock" again, and the Pause item is now enabled and
      reads "Resume".
- [ ] Click "Resume" to bring the device back to a clean unpaused state.
- [ ] Confirm a new `is_paused = 0` row appears in `device_events` for the resume.

## Scenario B -- Quit pauses and locks the device when pause_on_lock is enabled; disabled it does nothing extra

- [ ] Confirm `pause_on_lock` is still `true` (from Scenario A).
- [ ] Screenshot the menu bar; confirm no lock badge is shown and the icon shows play (▶).
- [ ] Quit the app (`osascript -e 'tell application "TimeFlip" to quit'`).
- [ ] Query `debug_log` and confirm the sequence `"Quit requested; pause_on_lock enabled, pausing
      and locking device before exit"` then `"Pause+lock on quit complete, terminating now"`.
- [ ] Start the app; confirm reconnect via a fresh `debug_log` `"Login accepted, code=0x02"` row,
      and via screenshot that the status icon is green (reconnected), not yellow.
- [ ] Confirm a new `is_paused = 1` device_events row now appears -- note this only shows up after
      this relaunch's startup fetch, not immediately after quit: `applicationShouldTerminate`
      sends the pause over BLE but never calls `historyIngestor.refreshHistory` itself (unlike the
      manual Lock path, which does), so nothing records it in `device_events` until the next fetch
      picks up the device's true state.
- [ ] Screenshot the menu bar; confirm the lock badge is shown and the icon shows pause (⏸),
      matching what quit left the device in.
- [ ] Open the menu; confirm the item reads "Unlock" and the Pause item is disabled -- matching the
      icon/badge check above.
- [ ] Click "Unlock", then click "Resume" to return to a clean state.
- [ ] Confirm `device_events` shows the corresponding unlock-independent resume (`is_paused = 0`)
      row.
- [ ] Restore `pause_on_lock` to its original value noted in Setup (same `UPDATE setting ...`
      command).
- [ ] Screenshot the menu bar; confirm no lock badge is shown and the icon shows play (▶).
- [ ] Quit the app.
- [ ] Query `debug_log` and confirm `"Quit requested; pause_on_lock disabled or no paired device,
      exiting immediately"` -- not the pause/lock sequence above.
- [ ] Confirm no new `is_paused = 1` device_events row was added around the quit time.
- [ ] Start the app; confirm reconnect (fresh `debug_log` `"Login accepted, code=0x02"` row) and via
      screenshot that the status icon is green with no lock badge -- a clean, unlocked, unpaused
      state.

## Scenario C -- time genuinely passes in this clean, running state

- [ ] Screenshot the menu bar; confirm no lock badge is shown and the icon shows play (▶).
- [ ] Note the current (still-open, non-finalised) `device_events` row's `device_events_id` and
      `duration_seconds`. Wait a few seconds (no need to wait a full
      `fetch_history_interval_seconds` period -- the still-open event's `duration_seconds` is
      computed live from `start_epoch`, not dependent on a fetch landing).
- [ ] Re-query the same `device_events_id` and confirm `duration_seconds` increased and it's still
      the same row (not paused, not superseded by a new flip) -- proves time is genuinely passing
      without needing to watch the menu bar tick up.
- [ ] Open the menu; confirm the Lock item reads "Lock" and the Pause item reads "Pause" and is
      enabled -- the menu's own labels agree with the icons, a clean state ready for
      `Tests/Interactive/04-lock-and-pause-on-lock-checklist.md`.
