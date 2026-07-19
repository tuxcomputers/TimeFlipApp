# Lock / pause_on_lock Checklist (Interactive)

This checklist is fully interactive -- it has no Bench counterpart. Every scenario is triggered by a
status-**menu** Lock/Unlock/Resume click or the status-**item** double-click gesture, and confirmed
by the custom-drawn red lock badge and the ⏸/▶ indicator -- none of which a UI-automation harness can
reliably drive or read (the status item lives in a separate process and has no accessibility text).
Resetting lock/pause state between scenarios likewise needs a menu action or a physical double-tap.
So although the `(Claude)` `debug_log`/`device_events` assertions are machine-checkable, they only
have meaning wrapped around human actions, and the whole file stays here.

Covers the app's own "Lock"/"Unlock" menu item (`MenuBarController`/`ApplicationDelegate
.handleLockRequest`) and the `pause_on_lock` setting. Despite the setting's name, it has **nothing
to do with the Mac's screen locking or sleeping** -- there is no code anywhere that listens for
that. `pause_on_lock` only controls whether *this app's own* Lock action (menu item, or the
status-item's double-click-right-half gesture) also pauses the device first, and whether **quitting
the app** does the same. There is also no auto-resume: once paused via Lock/Quit, the device stays
paused until manually resumed (Pause menu item, or a physical double-tap) -- Unlock alone does not
resume it.

Unlike `low_battery_level`/`fetch_history_interval_seconds`, `pause_on_lock` is read live from
SQLite on every Lock/Quit action (`AppDataStore.loadPauseOnLockEnabled()`) -- it does **not**
require an app restart to take effect.

Requires Developer Mode enabled, the `debug` setting's `enabled` field `true` (so `.timeFlip`-tagged
debug prints land in `debug_log`), and a paired, connected device.

Lock and pause state are both visible directly in the menu bar status item without opening the
menu: a red lock badge appears to the left of the activity indicator while locked
(`statusIndicatorImage`/lock badge in `MenuBarController.swift`), and that indicator itself is a
pause icon (⏸) while paused or a play icon (▶) while running. Ask about those icons directly rather
than menu item text/enabled state -- simpler for you to answer without opening the menu each time.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Setup

- [x] **(Claude)** Query the current `pause_on_lock` value: `sqlite3 ~/Library/Application\
      Support/TimeFlip/appdata.sqlite "SELECT setting_value FROM setting WHERE setting_name =
      'pause_on_lock';"` and note it as the original value to restore later. (Original: `false`.)
- [x] **(Claude)** Query the device's current lock/pause state from the most recent `device_events`
      row (`SELECT device_events_id, event_number, is_paused, finalised FROM device_events ORDER BY
      device_events_id DESC LIMIT 1;`), and from the menu (ask if needed) whether it currently shows
      "Lock" or "Unlock". If the device is currently paused or locked, resolve that first (Resume /
      Unlock via the menu) so both scenarios below start from a clean unlocked, unpaused state.
      (Device unlocked but paused; needed a Resume click to reach a clean state.)

## Scenario A -- manual Lock/Unlock via the menu item, with pause_on_lock disabled

- [x] **(Claude)** Ensure `pause_on_lock` is `false`: `sqlite3 ~/Library/Application\
      Support/TimeFlip/appdata.sqlite "UPDATE setting SET setting_value = '{\"enabled\":false}'
      WHERE setting_name = 'pause_on_lock';"`. (Already `false`.)
- [x] **(You)** Click the "Lock" menu item.
- [x] **(Claude)** Query `debug_log` (`SELECT message FROM debug_log WHERE tag = 'TimeFlip' ORDER BY
      debug_log_id DESC LIMIT 10;`) and confirm `"Lock ON triggered"` followed by `"Lock
      verification confirmed: requested=ON actual=ON"`.
- [x] **(You)** Confirm the red lock badge now appears in the status item.
- [x] **(You)** Open the menu and confirm the item now reads "Unlock".
- [x] **(Claude)** Confirm no new `is_paused = 1` row was added to `device_events` -- Lock alone,
      with `pause_on_lock` off, must not pause the device.
- [x] **(You)** While still in that same menu, confirm the Pause item is disabled/greyed out --
      this is gated purely by lock state (`isEnabled = isPaired && !isLocked`), independent of
      `pause_on_lock`.
- [x] **(You)** Single-click (not double-click) the right half of the status icon; confirm nothing
      happens -- no pause/resume toggle, still locked. This is a separate gesture from the
      double-click lock toggle tested in Scenario B, and is a no-op while locked
      (`togglePause()`'s own guard).
- [x] **(You)** Try flipping the device to a different facet while locked; confirm nothing happens
      (the device itself refuses the flip while locked).
- [x] **(You)** Click "Unlock" from the menu.
- [x] **(Claude)** Confirm `debug_log` shows `"Lock OFF triggered"` followed by `"Lock verification
      confirmed: requested=OFF actual=OFF"`.
- [x] **(You)** Confirm the lock badge disappears.
- [x] **(You)** Open the menu and confirm the item reads "Lock" again.

## Scenario B -- manual Lock/Unlock via the double-click gesture, with pause_on_lock disabled

Same as Scenario A, but via the status icon's double-click-right-half gesture instead of the menu
item, to confirm the gesture is a genuine equivalent and not just wired to open the menu.

- [x] **(You)** Double-click the right half of the status icon.
- [x] **(Claude)** Query `debug_log` and confirm the same `"Lock ON triggered"` /
      `"...confirmed: requested=ON actual=ON"` pair.
- [x] **(You)** Confirm the lock badge now appears.
- [x] **(You)** Open the menu and confirm the item reads "Unlock" and the Pause item is disabled.
- [x] **(Claude)** Confirm no new `is_paused = 1` row was added -- same as Scenario A, still
      `pause_on_lock` disabled. (A pause row did appear at the same time, but `device_notifications`
      confirms it was a physical double-tap on the device itself -- `double_tap facet=2
      pauseOn=true`, 3s before the Lock action -- not caused by the double-click gesture.)
- [x] **(You)** Single-click (not double-click) the right half of the status icon; confirm nothing
      happens -- still locked, no pause toggle.
- [x] **(You)** Double-click the right half of the status icon again.
- [x] **(Claude)** Confirm `debug_log` shows `"Lock OFF triggered"` / `"...confirmed: requested=OFF
      actual=OFF"`.
- [x] **(You)** Confirm the lock badge disappears and the menu item reads "Lock" again.
- [x] **(You)** Confirm the Pause item is enabled (no longer greyed out) again now that it's
      unlocked. (It reads "Resume", not "Pause" -- device is still paused from the earlier physical
      double-tap, which confirms it's enabled/reachable now that it's unlocked.)

## Scenario C -- Lock also pauses when pause_on_lock is enabled, and Unlock does not auto-resume

- [x] **(Claude)** Set `pause_on_lock` to `true`: same `UPDATE setting ...` command with
      `{\"enabled\":true}`.
- [x] **(You)** Confirm the status item shows the play icon (▶) -- device not already paused.
- [x] **(You)** Click "Lock".
- [x] **(Claude)** Confirm a new `is_paused = 1` device_events row was written (the pause that
      Lock triggered), and that `debug_log` still shows the same `"Lock ON triggered"` /
      `"...confirmed..."` pair from Scenario A/B.
- [x] **(You)** Confirm the lock badge is now shown, and the icon switched to pause (⏸) --
      confirming Lock paused the device before locking it.
- [x] **(You)** Open the menu and confirm the item reads "Unlock" and the Pause item is disabled
      (can't manually toggle pause while locked).
- [x] **(You)** Click "Unlock".
- [x] **(Claude)** Confirm the device is still paused after unlocking -- no new `is_paused = 0` row
      appears in `device_events` from the unlock action itself (there is no auto-resume).
- [x] **(You)** Confirm the lock badge is gone but the icon still shows pause (⏸) -- unlocking alone
      did not resume it.
- [x] **(You)** Open the menu and confirm the item reads "Lock" again, and the Pause item is now
      enabled and reads "Resume".
- [x] **(You)** Click "Resume" to bring the device back to a clean unpaused state.
- [x] **(Claude)** Confirm a new `is_paused = 0` row appears in `device_events` for the resume.

## Scenario D -- Quit pauses and locks the device when pause_on_lock is enabled

- [x] **(Claude)** Confirm `pause_on_lock` is still `true` (from Scenario C).
- [x] **(You)** Confirm no lock badge is shown and the icon shows play (▶).
- [x] **(You)** Quit the app.
- [x] **(Claude)** Query `debug_log` and confirm the sequence `"Quit requested; pause_on_lock
      enabled, pausing and locking device before exit"` then `"Pause+lock on quit complete,
      terminating now"`.
- [x] **(You)** Start the app and confirm it reconnects to the device.
- [x] **(Claude)** Confirm a new `is_paused = 1` device_events row now appears -- note this only
      shows up after this relaunch's startup fetch, not immediately after quit:
      `applicationShouldTerminate` sends the pause over BLE but never calls
      `historyIngestor.refreshHistory` itself (unlike the manual Lock path, which does), so nothing
      records it in `device_events` until the next fetch picks up the device's true state.
- [x] **(You)** Confirm the lock badge is shown and the icon shows pause (⏸), matching what quit
      left the device in.
- [x] **(You)** Open the menu and confirm the item reads "Unlock" and the Pause item is disabled --
      matching the icon/badge check above.
- [x] **(You)** Click "Unlock", then click "Resume" to return to a clean state.
- [x] **(Claude)** Confirm `device_events` shows the corresponding unlock-independent resume
      (`is_paused = 0`) row.

## Scenario E -- Quit does nothing extra when pause_on_lock is disabled

- [x] **(Claude)** Restore `pause_on_lock` to its original value noted in Setup (same `UPDATE
      setting ...` command).
- [x] **(You)** Confirm no lock badge is shown and the icon shows play (▶).
- [x] **(You)** Quit the app.
- [x] **(Claude)** Query `debug_log` and confirm `"Quit requested; pause_on_lock disabled or no
      paired device, exiting immediately"` -- not the pause/lock sequence from Scenario D.
- [x] **(Claude)** Confirm no new `is_paused = 1` device_events row was added around the quit time.
- [x] **(You)** Start the app and confirm it reconnects to the device, still unlocked and unpaused
      (time increasing).
- [x] **(You)** Open the menu one last time and confirm the Lock item reads "Lock" and the Pause
      item reads "Pause" and is enabled -- the menu's own labels agree with the icons throughout
      this checklist, not just at the one or two spot-checks above.
