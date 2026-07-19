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

- [x] Query the current `pause_on_lock` value and note it as the original value to restore later.
      (Original: `true`.)
- [x] Query the device's current lock/pause state and the status-item menu's item names. If the
      device is currently paused or locked, resolve that first (click Resume / Unlock via the
      menu) so the scenarios below start from a clean unlocked, unpaused state. (Found locked +
      paused leftover from an earlier session; resolved via Unlock then Resume.)

## Scenario A -- Lock also pauses when pause_on_lock is enabled, and Unlock does not auto-resume

- [x] Set `pause_on_lock` to `true`. (Already `true` from Setup.)
- [x] Screenshot the menu bar; confirm the status item shows the play icon (▶) -- device not
      already paused. (Confirmed.)
- [x] Click the "Lock" menu item.
- [x] Confirm a new `is_paused = 1` device_events row was written, and that `debug_log` shows
      `"Lock ON triggered"` followed by `"Lock verification confirmed: requested=ON actual=ON"`.
      (Confirmed -- this is also where real post-reset events started appearing again after
      `01-reset-device-checklist.md`'s reset: event_number 1, then 2 here, proving the counter
      wipe more directly than the `device_last_event=nil` evidence noted there.)
- [x] Screenshot the menu bar; confirm the lock badge is now shown and the icon switched to pause
      (⏸). (Confirmed visually.)
- [x] Open the menu; confirm the item reads "Unlock" and the Pause item is disabled. (Confirmed:
      `Resume` item `enabled = false`.)
- [x] Click "Unlock".
- [x] Confirm the device is still paused after unlocking -- no new `is_paused = 0` row appears.
      (Confirmed.)
- [x] Screenshot the menu bar; confirm the lock badge is gone but the icon still shows pause (⏸).
      (Confirmed visually, duration frozen.)
- [x] Open the menu; confirm the item reads "Lock" again, and the Pause item is now enabled and
      reads "Resume". (Confirmed: `Resume` item `enabled = true`.)
- [x] Click "Resume" to bring the device back to a clean unpaused state.
- [x] Confirm a new `is_paused = 0` row appears in `device_events` for the resume. (Confirmed.)

## Scenario B -- Quit pauses and locks the device when pause_on_lock is enabled; disabled it does nothing extra

- [x] Confirm `pause_on_lock` is still `true`. Screenshot: no lock badge, play icon. (Confirmed.)
- [x] Quit the app.
- [x] Query `debug_log` and confirm the sequence `"Quit requested; pause_on_lock enabled, pausing
      and locking device before exit"` then `"Pause+lock on quit complete, terminating now"`.
      (Confirmed.)
- [x] Start the app; confirm reconnect and via screenshot that the status icon is green. (Confirmed
      fresh `"Login accepted, code=0x02"`.)
- [x] Confirm a new `is_paused = 1` device_events row now appears (only after this relaunch's
      startup fetch, not immediately after quit). (Confirmed.)
- [x] Screenshot the menu bar; confirm the lock badge is shown and the icon shows pause (⏸).
      (Confirmed visually.)
- [x] Open the menu; confirm the item reads "Unlock" and the Pause item is disabled. (Confirmed:
      `Resume` item `enabled = false`.)
- [x] Click "Unlock", then click "Resume" to return to a clean state. (Confirmed via new
      `is_paused = 0` row.)
- [x] Test the *disabled* case properly: the noted "original" value is `true`, not `false`, so
      restoring "to original" here wouldn't actually exercise the disabled-quit path. Explicitly
      set `pause_on_lock` to `false` instead, confirmed via querying the setting back.
- [x] Quit the app (from the clean, unlocked/unpaused state above, with `pause_on_lock` now
      genuinely `false`).
- [x] Query `debug_log` and confirm `"Quit requested; pause_on_lock disabled or no paired device,
      exiting immediately"` -- not the pause/lock sequence above. (Confirmed.)
- [x] Confirm no new `is_paused = 1` device_events row was added around the quit time. (Confirmed.)
- [x] Restore `pause_on_lock` to the real original value (`true`) noted in Setup.
- [x] Start the app; confirm reconnect and via screenshot that the status icon is green with no
      lock badge -- a clean, unlocked, unpaused state, `pause_on_lock` back to its real original
      value. (Confirmed.)

## Scenario C -- time genuinely passes in this clean, running state

- [x] Screenshot the menu bar; confirm no lock badge is shown and the icon shows play (▶).
      (Confirmed.)
- [x] Note the current (still-open, non-finalised) `device_events` row's `device_events_id` and
      `duration_seconds`. Wait a few seconds.
- [x] Re-query the same `device_events_id` and confirm `duration_seconds` increased and it's still
      the same row. (Confirmed: 51.0s -> 71.0s, same row, `is_paused = 0`.)
- [x] Open the menu; confirm the Lock item reads "Lock" and the Pause item reads "Pause" and is
      enabled -- a clean state ready for `Tests/Interactive/04-lock-and-pause-on-lock-checklist.md`.
      (Confirmed.)
