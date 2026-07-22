# Lock / pause_on_lock Checklist (Interactive)

### Last run - 2026-07-22 on the branch 'feature/projects'

Run **after** `Tests/Bench/04b-lock-and-pause-on-lock-checklist.md`. Everything that used to live
here -- the status-item's own single/double-click-right-half gesture -- moved to that file's
Scenarios D/E once CGEventPost (with `kCGMouseEventClickState` set explicitly) was confirmed to
drive it (Method: Simulate a real click, double-click, or held press via CGEventPost,
`../Methods.md`), previously believed unscriptable. What's left needs a physical facet flip, which
no synthetic event can produce.

Requires Developer Mode enabled, the `debug` setting's `enabled` field `true`, and a paired,
connected device.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Scenario A -- the device refuses a physical flip while locked

**Preconditions:** device connected, unpaired state not applicable here; check the menu bar (lock
badge) before continuing.

- [x] **(Claude)** If the device isn't already locked, click the "Lock" menu item and confirm
      `debug_log` shows `"Lock ON triggered"` / `"...confirmed: requested=ON actual=ON"`. (Confirmed.)
- [x] **(You)** Try flipping to the **Meeting** face while locked (name the exact facet, per
      `../CLAUDE.md`); confirm nothing happens (the device itself refuses the flip while locked).
      (Confirmed: flipped to the Meeting side, `device_event` stayed at `event_number=25`, facet 8
      -- no new row.)
- [x] **(Claude)** Confirm no new `device_event` row appeared for the attempted flip (query
      `device_event_id DESC`, latest row unchanged before/after). (Confirmed.)
- [x] **(Claude)** Click "Unlock" from the menu and confirm `debug_log` shows `"Lock OFF triggered"`
      / `"...confirmed: requested=OFF actual=OFF"`, returning to a clean unlocked state. (Confirmed.)
