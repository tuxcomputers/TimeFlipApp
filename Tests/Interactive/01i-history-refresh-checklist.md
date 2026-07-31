# History Refresh Checklist (Interactive)

### Last run - 2026-07-21 on the branch 'feature/projects'

The physical-flip parts of the history refresh test. Run **after the whole Bench phase**
(`Tests/Bench/01b-history-refresh-checklist.md` and, since then, `02b-reset-device-checklist.md`
included). Both scenarios need a person to physically flip the cube -- Scenario A a single normal
flip, Scenario B several flips while the app is disconnected -- which is the only way to make the
device generate the new events these scenarios verify. The `(Claude)` steps assert the resulting
rows from `device_event`/`debug_log`.

Assumes the state the whole Bench phase left: app running, device paired and connected, Developer
Mode and `debug` enabled. Since `02b`'s reset runs before this (in the same overall Bench phase),
event numbers here will be small (post-reset), not a continuation of `01b`'s pre-reset baseline --
that's expected, not a bug; only the *relative* deltas below matter, not any specific absolute
number.

> Faces used throughout this checklist's run: face 2 ("Meeting") and face 8 ("Break") only.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Scenario A -- normal flip

**Preconditions:** device connected and paired, test DB active -- left by the Bench run above,
which this scenario runs straight on from. Check device connection before asking for the flip.

- [ ] **(Claude)** Step 1: Confirm the device shows connected
before asking for the flip below.
```toml step
action = "sql_query"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Login accepted%' ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Login accepted"
```
- [ ] **(Claude)** Step 2: Note the current max `event_number`
By `device_event_id DESC`, not `MAX(event_number)` -- [Method: Number 20](../Methods.md#method-20).
```toml step
[[actions]]
use = "method-24.c"
column = "event_number"
capture = "n_before_flip"

[[actions]]
use = "method-24.h"
capture = "flip_target_name"

[[actions]]
action = "sql_query"
query = "SELECT CASE WHEN (SELECT device_face FROM device_event ORDER BY device_event_id DESC LIMIT 1) = 8 THEN 2 ELSE 8 END;"
capture = "flip_target_face"
```
- [ ] **(Claude)** Step 3: Confirm the device isn't locked
(no lock badge on the menu bar) before asking for the flip below -- the device silently refuses flips while locked, which would otherwise leave the poll below waiting forever with nothing to detect. Unlock first if locked. (Found the device locked+paused -- leftover from `05b`-`07b`'s Setup sections quitting with `pause_on_lock=true` still enabled from `04b`. Resolved via Unlock then Resume. Noted along the way: clicking Unlock then Resume back-to-back too fast raced an async history refresh from a flip the device had accumulated while locked, causing the first Resume to pause instead of resume -- resolved by re-clicking Resume once things settled. Not filed as a bug since it took rapid automated clicks to trigger, not normal usage timing.)
```toml step
action = "ensure_unlocked_unpaused"
```
- [ ] **(You)** Step 4: Flip to whichever of **Break**/**Meeting** the device is *not* already on
-- Step 2 read the current face and named the target in the prompt, so a real flip happens; asking for the face it's already resting on would leave the poll with nothing to detect. (Detected automatically by polling `device_event` every couple of seconds -- no need to ask for confirmation, and **no timeout**: it keeps polling until you flip, so taking your time won't fail the run. [Method: Number 19](../Methods.md#method-19).)
```toml step
action = "ask_user_or_detect"
prompt = "Flip the cube to the $flip_target_name face."
detect_query = "SELECT event_number FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
timeout_seconds = 0
poll_interval = 2
```
- [ ] **(Claude)** Step 5: Confirm a new `device_event` row exists with a higher `event_number`.
      The previously-open row must now be `finalised = 1`, with a `duration_seconds` that stopped
      growing.
```toml step
[[actions]]
use = "method-24.c"
column = "event_number"
capture = "n_after_flip"

[[actions]]
action = "sql_query"
query = "SELECT finalised FROM device_event WHERE event_number = $n_before_flip ORDER BY device_event_id DESC LIMIT 1;"
expect = "1"
```
- [ ] **(Claude)** Step 6: Confirm the menu bar updated to the new face
      -- its `device_face` is now the target face flipped to in Step 4.
```toml step
use = "method-24.c"
column = "device_face"
expect = "$flip_target_face"
```

## Scenario B -- backlog after being out of range

**Preconditions:** device connected and paired (Scenario A's own ending state), so there's a
starting point to disconnect from below. Check device connection first; if it's not connected,
reconnect before proceeding rather than starting this scenario already disconnected.

- [ ] **(Claude)** Step 1: Confirm the device shows connected before disconnecting it below.
```toml step
action = "sql_query"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Login accepted%' ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Login accepted"
```
- [ ] **(Claude)** Step 2: Note the current max `event_number`.
```toml step
[[actions]]
use = "method-24.b"
capture = "before_disconnect_id"

[[actions]]
use = "method-24.c"
column = "event_number"
capture = "n_before_disconnect"
```
- [ ] **(You)** Step 3: Turn **off** Bluetooth on the Mac
 so the app loses the device. Use the menu bar icon or System Settings -- **not** `sudo`/system-wide toggling, which also drops every other Bluetooth peripheral. Don't flip the cube yet -- that comes once the disconnect is detected. No y/n to answer: the script waits for the app's own `connection.connection_lost recorded` marker (`TimeFlip` tag) and continues on its own. (The status item's title doesn't reflect connection state, so this reads that marker, not the menu bar.) (Note: the app doesn't record the drop immediately -- `connection.connection_lost recorded` lands a few minutes after Bluetooth actually goes off, observed ~3.5-4 min between the request and the disconnect. There's **no timeout** here: it just keeps polling until the marker appears, so taking your time won't fail the run.)
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'connection.connection_lost recorded%' AND debug_log_id > $before_disconnect_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "connection.connection_lost recorded"
prompt = "Turn OFF Bluetooth on the Mac (menu bar icon or System Settings, NOT sudo/system-wide, which drops every other peripheral too). Don't flip the cube yet -- waiting for the app to record the drop (it can take a few minutes after Bluetooth goes off)."
timeout_seconds = 0
poll_interval = 5
```
- [ ] **(You)** Step 4: Flip between **Break** and **Meeting** 2-3 times.
That accumulates a backlog of events the app can't see yet. (This one keeps a y/n confirm: nothing is logged while disconnected -- no data flows -- so there's no side effect to detect until the reconnect below.)
```toml step
action = "ask_user"
prompt = "While the device is STILL disconnected, flip the cube back and forth between the Break and Meeting faces 2-3 times. Have you done that? (y/n)"
```
- [ ] **(You)** Step 5: Turn Bluetooth back **on**
so the app can reconnect and sync the backlog. No y/n to answer and **no timeout**: the script keeps polling for a fresh `TimeFlip`-tagged `"Login accepted, code=0x02"` row after the disconnect and continues on its own -- the point automatic detection resumes (flips while disconnected can't be polled in real time, no connection means no data flows). [Method: Number 4](../Methods.md#method-4).
```toml step
use = "method-4"
since_id = "$before_disconnect_id"
expect_contains = "Login accepted"
prompt = "Turn Bluetooth back ON so the app can reconnect and sync the backlog -- waiting for the reconnect."
timeout_seconds = 0
poll_interval = 3
```
- [ ] **(Claude)** Step 6: Confirm the disconnected-flip backlog synced on reconnect
poll until at least **2** new `device_event` rows exist above the pre-disconnect baseline, i.e. the intermediate flips arrived as their own segments once the connection came back. (No-gap ordering and the final open row matching the resting face are visual/interpretive -- a gap can be legitimate: a sub-`blip_time` quick pass-over gets merged into the surrounding segment and logged as `debug_log`'s `"history gap explained: ev=<N> dur=<s>s under 5s, device's own filter"`, so confirm any gap is explained that way before treating it as missing data.)
```toml step
action = "wait_for_sql"
query = "SELECT CASE WHEN (SELECT COUNT(DISTINCT event_number) FROM device_event WHERE event_number > $n_before_disconnect) >= 2 THEN 'synced' ELSE 'waiting' END;"
expect = "synced"
timeout_seconds = 60
poll_interval = 3
```
