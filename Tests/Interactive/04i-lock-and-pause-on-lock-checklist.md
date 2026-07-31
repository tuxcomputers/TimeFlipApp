# Lock / pause_on_lock Checklist (Interactive)

### Last run - 2026-07-22 on the branch 'feature/projects'

Run **after** `Tests/Bench/04b-lock-and-pause-on-lock-checklist.md`. Everything that used to live
here -- the status-item's own single/double-click-right-half gesture -- moved to that file's
Scenarios D/E once CGEventPost (with `kCGMouseEventClickState` set explicitly) was confirmed to
drive it ([Method: Number 7](../Methods.md#method-7)), previously believed unscriptable. What's left needs a physical face flip, which
no synthetic event can produce.

Requires Developer Mode enabled, the `debug` setting's `enabled` field `true`, and a paired,
connected device.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Scenario A -- the device refuses a physical flip while locked

**Preconditions:** device connected, unpaired state not applicable here; check the menu bar (lock
badge) before continuing.

- [ ] **(Claude)** Step 1: Click the "Lock" menu item
if the device isn't already locked. Confirm `debug_log` shows `"Lock ON triggered"` / `"...confirmed: requested=ON actual=ON"`.
```toml step
[[actions]]
use = "method-6"
item = "Lock"

[[actions]]
use = "method-24.d"
action = "wait_for_sql"
tag = "TimeFlip"
expect_contains = "Lock verification confirmed: requested=ON actual=ON"
timeout_seconds = 30
```
- [ ] **(You)** Step 2: Flip to whichever of **Break**/**Meeting** it is *not* on.
The step reads the current face and names the target below, so it's a real attempted transition. confirm nothing happens (the device itself refuses the flip while locked).
```toml step
[[actions]]
use = "method-24.c"
column = "device_event_id"
capture = "event_id_before_locked_flip"

[[actions]]
use = "method-24.h"
capture = "flip_target_name"

[[actions]]
action = "ask_user"
prompt = "Flip the cube to the $flip_target_name face while it's locked. Did the device refuse the flip -- i.e. nothing happened? (y/n)"
```
- [ ] **(Claude)** Step 3: Confirm no new `device_event` row appeared
for the attempted flip (query `device_event_id DESC`, latest row unchanged before/after).
```toml step
use = "method-24.c"
column = "device_event_id"
expect = "$event_id_before_locked_flip"
```
- [ ] **(Claude)** Step 4: Click "Unlock" from the menu, returning to a clean unlocked state.
      Confirm `debug_log` shows `"Lock OFF triggered"` / `"...confirmed: requested=OFF
      actual=OFF"`.
```toml step
[[actions]]
use = "method-6"
item = "Unlock"

[[actions]]
use = "method-24.d"
action = "wait_for_sql"
tag = "TimeFlip"
expect_contains = "Lock verification confirmed: requested=OFF actual=OFF"
timeout_seconds = 30
```
