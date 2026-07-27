# Lock / pause_on_lock Checklist (Interactive)

### Last run - 2026-07-22 on the branch 'feature/projects'

Run **after** `Tests/Bench/04b-lock-and-pause-on-lock-checklist.md`. Everything that used to live
here -- the status-item's own single/double-click-right-half gesture -- moved to that file's
Scenarios D/E once CGEventPost (with `kCGMouseEventClickState` set explicitly) was confirmed to
drive it ([Method: Number 7](../Methods.md#method-7)), previously believed unscriptable. What's left needs a physical facet flip, which
no synthetic event can produce.

Requires Developer Mode enabled, the `debug` setting's `enabled` field `true`, and a paired,
connected device.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Scenario A -- the device refuses a physical flip while locked

**Preconditions:** device connected, unpaired state not applicable here; check the menu bar (lock
badge) before continuing.

- [x] **(Claude)** Step 1: If the device isn't already locked, click the "Lock" menu item and confirm
      `debug_log` shows `"Lock ON triggered"` / `"...confirmed: requested=ON actual=ON"`.
```toml step
[[actions]]
action = "click_menu_item"
item = "Lock"

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Lock verification confirmed: requested=ON actual=ON"
timeout_seconds = 10
```
- [x] **(You)** Step 2: Try flipping to whichever of **Break**/**Meeting** the device is *not* already on,
      while locked (the step reads the current face and names the target below, so it's a real
      attempted transition); confirm nothing happens (the device itself refuses the flip while
      locked).
```toml step
[[actions]]
action = "sql_query"
query = "SELECT device_event_id FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
capture = "event_id_before_locked_flip"

[[actions]]
action = "sql_query"
query = "SELECT CASE WHEN (SELECT device_face FROM device_event ORDER BY device_event_id DESC LIMIT 1) = 8 THEN 'Meeting' ELSE 'Break' END;"
capture = "flip_target_name"

[[actions]]
action = "ask_user"
prompt = "Flip the cube to the $flip_target_name face while it's locked. Did the device refuse the flip -- i.e. nothing happened? (y/n)"
```
- [x] **(Claude)** Step 3: Confirm no new `device_event` row appeared for the attempted flip (query
      `device_event_id DESC`, latest row unchanged before/after).
```toml step
action = "sql_query"
query = "SELECT device_event_id FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
expect = "$event_id_before_locked_flip"
```
- [x] **(Claude)** Step 4: Click "Unlock" from the menu and confirm `debug_log` shows `"Lock OFF triggered"`
      / `"...confirmed: requested=OFF actual=OFF"`, returning to a clean unlocked state.
```toml step
[[actions]]
action = "click_menu_item"
item = "Unlock"

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Lock verification confirmed: requested=OFF actual=OFF"
timeout_seconds = 10
```
