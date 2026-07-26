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

> Facets used throughout this checklist's run: facet 2 ("Meeting") and facet 8 ("Break") only.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Scenario A -- normal flip

**Preconditions:** device connected and paired, test DB active -- left by the Bench run above,
which this scenario runs straight on from. Check device connection before asking for the flip.

- [ ] **(Claude)** Step 1: Confirm the device shows connected before asking for the flip below.
```toml step
action = "sql_query"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Login accepted%' ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Login accepted"
```
- [ ] **(Claude)** Step 2: Note the current max `event_number` (call it N), by `device_event_id DESC`, not
      `MAX(event_number)` -- [Method: Number 20](../Methods.md#method-20). (Re-noted after an
      unrelated cleanup below: N=9, facet 2 "Meeting", running/unpaused.)
```toml step
[[actions]]
action = "sql_query"
query = "SELECT event_number FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
capture = "n_before_flip"

[[actions]]
action = "sql_query"
query = "SELECT CASE WHEN (SELECT device_face FROM device_event ORDER BY device_event_id DESC LIMIT 1) = 8 THEN 'Meeting' ELSE 'Break' END;"
capture = "flip_target_name"

[[actions]]
action = "sql_query"
query = "SELECT CASE WHEN (SELECT device_face FROM device_event ORDER BY device_event_id DESC LIMIT 1) = 8 THEN 2 ELSE 8 END;"
capture = "flip_target_face"
```
- [ ] **(Claude)** Step 3: Confirm the device isn't locked (no lock badge on the menu bar) before asking for
      the flip below -- the device silently refuses flips while locked, which would otherwise leave
      the poll below waiting forever with nothing to detect. Unlock first if locked. (Found the
      device locked+paused -- leftover from `05b`-`07b`'s Setup sections quitting with
      `pause_on_lock=true` still enabled from `04b`. Resolved via Unlock then Resume. Noted along the
      way: clicking Unlock then Resume back-to-back too fast raced an async history refresh from a
      flip the device had accumulated while locked, causing the first Resume to pause instead of
      resume -- resolved by re-clicking Resume once things settled. Not filed as a bug since it took
      rapid automated clicks to trigger, not normal usage timing.)
```toml step
action = "ensure_unlocked_unpaused"
```
- [ ] **(You)** Step 4: Flip to whichever of **Break**/**Meeting** the device is *not* already on -- Step 2
      read the current face and named the target in the prompt, so a real flip happens; asking for the
      face it's already resting on would leave the poll with nothing to detect. (Detected
      automatically by polling `device_event` every couple of seconds -- no need to ask for
      confirmation. [Method: Number 19](../Methods.md#method-19).)
```toml step
action = "ask_user_or_detect"
prompt = "Flip the cube to the $flip_target_name face."
detect_query = "SELECT event_number FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
timeout_seconds = 120
poll_interval = 2
```
- [ ] **(Claude)** Step 5: Confirm a new `device_event` row exists with `event_number` > N, and that
      event N's row is now `finalised = 1` with a `duration_seconds` that stopped growing.
```toml step
[[actions]]
action = "sql_query"
query = "SELECT event_number FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
capture = "n_after_flip"

[[actions]]
action = "sql_query"
query = "SELECT finalised FROM device_event WHERE event_number = $n_before_flip ORDER BY device_event_id DESC LIMIT 1;"
expect = "1"
```
- [ ] **(Claude)** Step 6: Confirm the menu bar updated to the new facet -- its `device_face` is now the
      target face flipped to in Step 4.
```toml step
action = "sql_query"
query = "SELECT device_face FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
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
- [ ] **(Claude)** Step 2: Note the current max `event_number` (call it N). (N=10, facet 8 "Break", still
      open.)
```toml step
[[actions]]
action = "sql_query"
query = "SELECT MAX(debug_log_id) FROM debug_log;"
capture = "before_disconnect_id"

[[actions]]
action = "sql_query"
query = "SELECT event_number FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
capture = "n_before_disconnect"
```
- [ ] **(You)** Step 3: Turn **off** Bluetooth on the Mac (menu bar icon or System Settings -- **not**
      `sudo`/system-wide toggling, which also drops every other Bluetooth peripheral), so the app
      loses the device. Don't flip the cube yet -- that comes once the disconnect is confirmed.
```toml step
action = "ask_user"
prompt = "Turn OFF Bluetooth on the Mac (menu bar icon or System Settings, NOT sudo/system-wide). Don't flip the cube yet. Have you turned Bluetooth off? (y/n)"
```
- [ ] **(Claude)** Step 4: Detect the disconnection -- wait for a fresh `connection.connection_lost recorded`
      row in `debug_log` (`TimeFlip` tag) after Step 2's baseline, confirming the app actually saw the
      device drop before any flips happen. (The status item's title text doesn't reflect connection
      state, so this reads the app's own disconnect marker, not the menu bar.)
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'connection.connection_lost recorded%' AND debug_log_id > $before_disconnect_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "connection.connection_lost recorded"
prompt = "Still looks connected -- make sure Bluetooth is actually off (the status item should show disconnected)."
timeout_seconds = 30
```
- [ ] **(You)** Step 5: With the device **still disconnected**, flip the cube back and forth between the
      **Break** and **Meeting** faces 2-3 times, so it accumulates a backlog of events the app can't
      see yet.
```toml step
action = "ask_user"
prompt = "While the device is STILL disconnected, flip the cube back and forth between the Break and Meeting faces 2-3 times. Have you done that? (y/n)"
```
- [ ] **(You)** Step 6: Turn Bluetooth back **on** so the app can reconnect and sync the backlog.
```toml step
action = "ask_user"
prompt = "Turn Bluetooth back ON so the app can reconnect. Have you turned it back on? (y/n)"
```
- [ ] **(Claude)** Step 7: Detect that the device reconnects (Method: Confirm device reconnect,
      `../Methods.md`): wait for a fresh `TimeFlip`-tagged `"Login accepted, code=0x02"` row logged
      after the disconnect. Flips while disconnected can't be polled in real time -- no connection
      means no data flows -- so this is the point automatic detection resumes.
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Login accepted%' AND debug_log_id > $before_disconnect_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Login accepted"
timeout_seconds = 30
```
- [ ] **(Claude)** Step 8: Confirm the disconnected-flip backlog synced on reconnect: poll until at least
      **2** new `device_event` rows exist with `event_number` greater than N (the pre-disconnect
      baseline), i.e. the intermediate flips arrived as their own segments once the connection came
      back. (No-gap ordering and the final open row matching the resting facet are visual/interpretive
      -- a gap can be legitimate: a sub-`blip_time` quick pass-over gets merged into the surrounding
      segment and logged as `debug_log`'s `"history gap explained: ev=<N> dur=<s>s under 5s, device's
      own filter"`, so confirm any gap is explained that way before treating it as missing data.)
```toml step
action = "wait_for_sql"
query = "SELECT CASE WHEN (SELECT COUNT(DISTINCT event_number) FROM device_event WHERE event_number > $n_before_disconnect) >= 2 THEN 'synced' ELSE 'waiting' END;"
expect = "synced"
timeout_seconds = 60
poll_interval = 3
```
