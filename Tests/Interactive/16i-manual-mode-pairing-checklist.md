# Manual Mode Pairing Checklist (Interactive)

The one part of pairing out of a manual session that needs a person: proving the app really is timing
from the **cube** afterwards, and not still from the stand-in it replaced.

`16b` proves the handover from the app's side -- the virtual device is stood down, its segment is closed
and converted, the connection is live -- and every one of those could in principle be true of a session
that had swapped in a device nobody was flipping. A physical flip landing on the right face is the only
thing that cannot.

**Preconditions:** `Tests/Bench/16b-manual-mode-pairing-checklist.md` complete, so the app is paired and
connected having paired out of a manual session, with no Settings window open.

- [ ] **(Claude)** Step 1: Note the face the cube is not resting on, and the log baseline.
[Method: Number 24.h](../Methods.md#method-24) names the face to ask for; the baseline scopes the wait to
this flip. [Method: Number 24.b](../Methods.md#method-24).
```toml step
[[actions]]
use = "method-24.h"
capture = "flip_target"

[[actions]]
use = "method-24.b"
capture = "before_flip"
```
- [ ] **(You)** Step 2: Flip the cube to the face named above.
- [ ] **(Claude)** Step 3: Confirm the flip reached the app as a cube event on that face.
A face between 1 and 12 is the whole assertion: manual mode owns face 13, so a row on a real face can only
have come from the device. [Method: Number 19](../Methods.md#method-19) -- detected from the database rather
than asked about.
```toml step
[[actions]]
action = "wait_for_sql"
query = "SELECT CASE WHEN (SELECT device_face FROM device_event WHERE event_number < 900000 ORDER BY device_event_id DESC LIMIT 1) BETWEEN 1 AND 12 THEN 'cube' ELSE 'not a cube face' END;"
expect = "cube"
timeout_seconds = 120

[[actions]]
use = "method-24.k"
column = "paused"
expect = "0"
```
- [ ] **(Claude)** Step 4: Confirm the menu bar is showing the flipped-to category.
The display is the same in device mode as it was in manual mode, which is the point -- what changed is
where the reading comes from. [Method: Number 27](../Methods.md#method-27).
```toml step
use = "method-27"
expect_contains = "$flip_target"
```
