# Lock / pause_on_lock Checklist (Bench)

### Last run - 2026-07-22 on the branch 'feature/projects'

Covers the app's own "Lock"/"Unlock"/"Pause"/"Resume" status-item **menu** actions
(`MenuBarController`/`ApplicationDelegate.handleLockRequest`) and the `pause_on_lock` setting, for
the scenarios that use only menu clicks and DB-verifiable state -- no status-item gesture
(single/double-click on the right half) and no physical device flip, so all three are fully
Claude-drivable via the verified status-item-menu mechanic (Method: Click a status-item menu item,
`../Methods.md`). Scenario A and B were originally Scenario C and D of a single combined checklist;
Scenario C was originally Scenario E, with "is the time increasing?" converted from a `(You)`
menu-bar observation to a DB check (the same still-open event's `duration_seconds` growing) --
proving the same fact without needing eyes on the screen. Scenarios D and E below cover the status-item's own click gesture (single-click pause/resume,
double-click lock), now Claude-drivable via CGEventPost (Method: Simulate a real click,
double-click, or held press via CGEventPost, `../Methods.md`) -- previously believed unscriptable
(a raw screen-position hit-test, not a menu/AX action), until `kCGMouseEventClickState` was found to
be the missing piece. Only the physical facet-flip-while-locked check in
`Tests/Interactive/04i-lock-and-pause-on-lock-checklist.md` still needs a person.

Methods used throughout this file: Click a status-item menu item, Screenshot-based visual
confirmation, Simulate a real click, double-click, or held press via CGEventPost (`../Methods.md`).

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

**Preconditions:** device connected, unlocked, unpaused, `pause_on_lock=true` -- checked and
resolved in Setup immediately above, which this scenario runs straight on from.

- [x] Set `pause_on_lock` to `true`. (Already `true` from Setup.)
- [x] Screenshot the menu bar; confirm the status item shows the play icon (▶) -- device not
      already paused. (Confirmed.)
- [x] Click the "Lock" menu item.
- [x] Confirm a new `is_paused = 1` device_event row was written, and that `debug_log` shows
      `"Lock ON triggered"` followed by `"Lock verification confirmed: requested=ON actual=ON"`.
      (Confirmed -- this is also where real post-reset events started appearing again after
      `02b-reset-device-checklist.md`'s reset: event_number 1, then 2 here, proving the counter
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
- [x] Confirm a new `is_paused = 0` row appears in `device_event` for the resume. (Confirmed.)

## Scenario B -- Quit pauses and locks the device when pause_on_lock is enabled; disabled it does nothing extra

**Preconditions:** `pause_on_lock=true`, device connected, unlocked, unpaused -- the clean state
Scenario A's own last two steps (Unlock, Resume) leave behind. Check via the query/screenshot
below; if it doesn't match (a locked/paused leftover from an interrupted prior run, e.g.), resolve
it the same way Setup does above (Unlock/Resume via the menu, set `pause_on_lock=true`) before
continuing.

- [x] Confirm `pause_on_lock` is still `true`. Screenshot: no lock badge, play icon. (Confirmed.)
- [x] Quit the app.
- [x] Query `debug_log` and confirm the sequence `"Quit requested; pause_on_lock enabled, pausing
      and locking device before exit"` then `"Pause+lock on quit complete, terminating now"`.
      (Confirmed.)
- [x] Start the app; confirm reconnect and via screenshot that the status icon is green. (Confirmed
      fresh `"Login accepted, code=0x02"`.)
- [x] Confirm a new `is_paused = 1` device_event row now appears (only after this relaunch's
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
- [x] Confirm no new `is_paused = 1` device_event row was added around the quit time. (Confirmed.)
- [x] Restore `pause_on_lock` to the real original value (`true`) noted in Setup.
- [x] Start the app; confirm reconnect and via screenshot that the status icon is green with no
      lock badge -- a clean, unlocked, unpaused state, `pause_on_lock` back to its real original
      value. (Confirmed.)

## Scenario C -- time genuinely passes in this clean, running state

**Preconditions:** device connected, unlocked, unpaused, `pause_on_lock` back to its real original
value -- the clean state Scenario B's own last step leaves behind. Check via the screenshot below;
if it doesn't match, resolve the same way as Scenario B's own precondition above before continuing.

- [x] Screenshot the menu bar; confirm no lock badge is shown and the icon shows play (▶).
      (Confirmed.)
- [x] Note the current (still-open, non-finalised) `device_event` row's `device_event_id` and
      `duration_seconds`. Wait a few seconds.
- [x] Re-query the same `device_event_id` and confirm `duration_seconds` increased and it's still
      the same row. (Confirmed: 88.0s -> 97.0s, same row `device_event_id=11`, `is_paused = 0`.)
- [x] Open the menu; confirm the Lock item reads "Lock" and the Pause item reads "Pause" and is
      enabled -- a clean state ready for `Tests/Interactive/04i-lock-and-pause-on-lock-checklist.md`.
      (Confirmed.)

## Scenario D -- manual Lock/Unlock via the status item's double-click gesture, with pause_on_lock disabled

Confirms the double-click gesture (`MenuBarController.handleStatusItemClick`) is a genuine
equivalent to the "Lock"/"Unlock" menu item, not just wired to open the menu -- and that the
single-click pause/resume gesture is a no-op while locked. Method: Simulate a real click,
double-click, or held press via CGEventPost (`../Methods.md`), at the status item's right-half
point (`x = position.x + size.width * 0.75`, `y = position.y + size.height / 2`); re-read
`position`/`size` fresh each time, since the status item's width shifts with its content.

**Preconditions:** device connected, unlocked, unpaused -- the clean state Scenario C leaves
behind, though `pause_on_lock` is still `true` from there; this scenario's own first step forces it
to `false` regardless.

- [x] Set `pause_on_lock` to `false`. (Confirmed: `{"enabled":false}`.)
- [x] Confirm the menu bar shows no lock badge and a play icon (unlocked, unpaused).
- [x] Double-click the right half of the status icon (CGEventPost, `click_state=1` then `2`,
      ~0.15s apart). Query `debug_log` (tag `click`) and confirm `clickCount=1` then `clickCount=2`,
      both `side=right`, then (tag `TimeFlip`) `"Lock ON triggered"` / `"...confirmed: requested=ON
      actual=ON"`. (Confirmed live.)
- [x] Confirm no new `is_paused = 1` row was added -- `pause_on_lock` disabled, so Lock alone must
      not pause.
- [x] Single-click (not double) the right half of the status icon; confirm via `debug_log`
      (`clickCount=1`, no accompanying second click) the click landed, and that nothing else
      changed -- still locked, no pause/resume toggle, no new `device_event` row (a no-op while
      locked, `togglePause()`'s own guard). (Confirmed live: click logged, `device_event` row
      unchanged.)
- [x] Double-click the right half of the status icon again; confirm `debug_log` shows
      `clickCount=1` then `clickCount=2` again, then `"Lock OFF triggered"` / `"...confirmed:
      requested=OFF actual=OFF"`. (Confirmed live.)
- [x] Confirm the menu bar shows no lock badge again (unlocked).
- [x] Restore `pause_on_lock` to `true` and confirm the device is unlocked, unpaused -- clean for
      the next scenario. (Confirmed.)

## Scenario E -- status-item single-click gesture is a no-op while locked (menu-driven lock)

Confirms the same no-op guard as Scenario D's single-click check, but with Lock triggered via the
menu item instead of the gesture -- the two lock triggers are independent code paths into the same
`isLocked` state, so each is checked against the gesture-driven pause/resume toggle separately (see
"Running a checklist" rule 5 in `../CLAUDE.md`).

**Preconditions:** device connected, unlocked, unpaused, `pause_on_lock=true` -- Scenario D's own
last step leaves this behind; check via the menu bar and resolve via Unlock/Resume from the menu if
it doesn't match.

- [x] Click the "Lock" menu item. Confirm `debug_log` shows `"Lock ON triggered"` / `"...confirmed:
      requested=ON actual=ON"`. (Confirmed.)
- [x] Single-click the right half of the status icon (CGEventPost, single `click_state=1`). Confirm
      via `debug_log` (tag `click`, `clickCount=1`) the click landed, and confirm no new
      `device_event` row appeared -- still locked, no pause/resume toggle. (Confirmed live: click
      logged, no new row.)
- [x] Click "Unlock" from the menu, then "Resume" to return to a clean, unlocked, unpaused state.
      (Confirmed.)

The physical facet-flip-while-locked check still needs a real cube flip -- see
`Tests/Interactive/04i-lock-and-pause-on-lock-checklist.md`.
