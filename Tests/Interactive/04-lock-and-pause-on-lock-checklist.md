# Lock / pause_on_lock Checklist (Interactive)

Run **after** `Tests/Bench/04-lock-and-pause-on-lock-checklist.md`, which covers the same
Lock/Unlock/Pause/Resume behavior via menu clicks alone and leaves the device in a clean, unlocked,
unpaused state. What's left here needs a person for one of two reasons: the status-item's
single/double-click-right-half gesture (a real screen-position hit-test that scripted UI automation
could not reliably trigger -- see "Driving the app directly" in `../CLAUDE.md`), or a physical
facet flip. Everything else in these scenarios that *can* be Claude-driven (menu clicks, reading
menu/badge/icon state, or a DB-based running/paused check in place of watching the menu bar) has
been.

Covers the app's own "Lock"/"Unlock" menu item and status-item gesture
(`MenuBarController`/`ApplicationDelegate.handleLockRequest`) and the `pause_on_lock` setting --
see the Bench file for what that setting actually does.

Requires Developer Mode enabled, the `debug` setting's `enabled` field `true` (so `.timeFlip`-tagged
debug prints land in `debug_log`), and a paired, connected device.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Scenario A -- manual Lock/Unlock via the menu item, with pause_on_lock disabled

**Preconditions:** device connected, unlocked, unpaused -- the clean state the Bench run's last
scenario is supposed to leave behind, though don't take that on faith: check the menu bar (lock
badge, play/pause icon) before continuing, and resolve via Unlock/Resume from the menu if it isn't
actually clean. (Confirmed live this run: the device was found locked *and* paused at this exact
point, left over from a previous session's quit-while-`pause_on_lock`-enabled, not anything the
Bench run itself had done -- resolved via Unlock then Resume before Scenario A's own steps below.)
`pause_on_lock` itself is forced to `false` by this scenario's own first step regardless of its
starting value, so it isn't part of the precondition check.

- [x] **(Claude)** Confirm the menu bar shows no lock badge and a play icon; if it doesn't, click
      Unlock and/or Resume from the menu first. (Found locked and paused; resolved via Unlock then
      Resume.)
- [x] **(Claude)** Ensure `pause_on_lock` is `false`: `sqlite3 ~/Library/Application\
      Support/TimeFlip/appdata.sqlite "UPDATE setting SET setting_value = '{\"enabled\":false}'
      WHERE setting_name = 'pause_on_lock';"`.
- [x] **(Claude)** Click the "Lock" menu item.
- [x] **(Claude)** Query `debug_log` (`SELECT message FROM debug_log WHERE tag = 'TimeFlip' ORDER BY
      debug_log_id DESC LIMIT 10;`) and confirm `"Lock ON triggered"` followed by `"Lock
      verification confirmed: requested=ON actual=ON"`.
- [x] **(Claude)** Screenshot the menu bar; confirm the red lock badge is now visible.
- [x] **(Claude)** Open the menu; confirm the item reads "Unlock" and the Pause item is
      disabled/greyed out (gated purely by lock state -- `isEnabled = isPaired && !isLocked`,
      independent of `pause_on_lock`).
- [x] **(Claude)** Confirm no new `is_paused = 1` row was added to `device_event` -- Lock alone,
      with `pause_on_lock` off, must not pause the device.
- [x] **(You)** Single-click (not double-click) the right half of the status icon.
- [x] **(Claude)** Screenshot the menu bar; confirm nothing changed -- still locked, no pause/resume
      toggle. This is a separate gesture from the double-click lock toggle tested in Scenario B, and
      is a no-op while locked (`togglePause()`'s own guard).
- [x] **(You)** Try flipping the device to a different facet while locked; confirm nothing happens
      (the device itself refuses the flip while locked).
- [x] **(Claude)** Click "Unlock" from the menu.
- [x] **(Claude)** Confirm `debug_log` shows `"Lock OFF triggered"` followed by `"Lock verification
      confirmed: requested=OFF actual=OFF"`.
- [x] **(Claude)** Screenshot the menu bar; confirm the lock badge is gone.
- [x] **(Claude)** Open the menu; confirm the item reads "Lock" again.

## Scenario B -- manual Lock/Unlock via the double-click gesture, with pause_on_lock disabled

Same as Scenario A, but via the status icon's double-click-right-half gesture instead of the menu
item, to confirm the gesture is a genuine equivalent and not just wired to open the menu.

**Preconditions:** device connected, unlocked, unpaused, `pause_on_lock=false` -- the clean state
Scenario A's own last two steps (Unlock via menu, `pause_on_lock` still `false` from its first
step) leave behind. Check the menu bar before continuing; resolve via Unlock/Resume from the menu
if it doesn't match.

- [x] **(Claude)** Confirm the menu bar shows no lock badge and a play icon before asking for the
      double-click below; if it doesn't, click Unlock and/or Resume from the menu first.
      (Confirmed clean, left by Scenario A.)
- [x] **(You)** Double-click the right half of the status icon.
- [x] **(Claude)** Query `debug_log` and confirm the same `"Lock ON triggered"` /
      `"...confirmed: requested=ON actual=ON"` pair.
- [x] **(Claude)** Screenshot the menu bar; confirm the lock badge is now visible.
- [x] **(Claude)** Open the menu; confirm the item reads "Unlock" and the Pause item is disabled.
- [x] **(Claude)** Confirm no new `is_paused = 1` row was added -- same as Scenario A, still
      `pause_on_lock` disabled. (A pause row did appear at the same time in one run, but
      `device_notification` confirmed it was a physical double-tap on the device itself -- not
      caused by the double-click gesture.)
- [x] **(You)** Single-click (not double-click) the right half of the status icon.
- [x] **(Claude)** Screenshot the menu bar; confirm nothing changed -- still locked, no pause toggle.
- [x] **(You)** Double-click the right half of the status icon again.
- [x] **(Claude)** Confirm `debug_log` shows `"Lock OFF triggered"` / `"...confirmed: requested=OFF
      actual=OFF"`.
- [x] **(Claude)** Screenshot the menu bar; confirm the lock badge is gone.
- [x] **(Claude)** Open the menu; confirm the item reads "Lock" again, and the Pause item is enabled
      (no longer greyed out).
