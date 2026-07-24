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
      `MAX(event_number)` -- Method: Read debug output, `../Methods.md`. (Re-noted after an
      unrelated cleanup below: N=9, facet 2 "Meeting", running/unpaused.)
```toml step
action = "sql_query"
query = "SELECT event_number FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
capture = "n_before_flip"
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
- [ ] **(You)** Step 4: Flip to the **Break** face (name the exact facet, per `../CLAUDE.md` -- only
      Break/Meeting have stickers on this cube). (Detected automatically by polling
      `device_event` every couple of seconds -- no need to ask for confirmation. Method: Detect a
      physical action instead of asking, `../Methods.md`.)
```toml step
action = "ask_user_or_detect"
prompt = "Flip the cube to the Break face."
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
- [ ] **(Claude)** Step 6: Screenshot the menu bar; confirm the activity name/icon updated to the new
      facet.
```toml step
action = "sql_query"
query = "SELECT device_face FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
expect = "8"
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
- [ ] **(You)** Step 3: Disconnect the device from the app -- either move it out of Bluetooth range, or (the
      practical equivalent used for this run, since the device's real range is long enough to make
      physically walking away impractical) turn off Bluetooth on the Mac itself, via the menu bar
      icon or System Settings, NOT `sudo`/system-wide toggling, which also disconnects any other
      Bluetooth peripherals -- wait for the menu bar to turn yellow (disconnected), then flip it
      2-3 times while still disconnected, then reconnect (bring it back in range, or turn Bluetooth
      back on). (Detect the disconnect via `debug_log` -- the status item's own title text doesn't
      reflect connection color/state, so poll `debug_log` for a `history` fetch repeatedly returning
      `device_last_event=nil` against an unchanged `known_max`, or check the Preferences window's
      `Connection` field directly, rather than the status item's name/title.)
```toml step
action = "ask_user"
prompt = "Turn off Bluetooth on the Mac (menu bar icon or System Settings, not sudo/system-wide). Wait for the status item to show disconnected, flip the cube 2-3 times while still disconnected, then turn Bluetooth back on. Did you complete all of that? (y/n)"
```
- [ ] **(Claude)** Step 4: Confirm the app reconnects automatically (Method: Confirm device reconnect,
      `../Methods.md`): query `debug_log` for a fresh `TimeFlip`-tagged `"Login accepted, code=0x02"`
      row logged after the reconnect. Flips while disconnected can't be polled in real time -- no
      connection means no data flows -- so this is the point to resume automatic detection, once
      reconnected.
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Login accepted%' AND debug_log_id > $before_disconnect_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Login accepted"
timeout_seconds = 30
```
- [ ] **(Claude)** Step 5: Confirm every intermediate flip shows up as its own finalised `device_event`
      row in ascending `event_number` order with no gaps, and the final row (still open) matches
      the device's actual current facet. (A gap can be legitimate rather than a bug -- a genuine
      sub-`blip_time` quick pass-over gets merged into the surrounding segment rather than recorded
      as its own row, logged as `debug_log`'s `"history gap explained: ev=<N> dur=<s>s under 5s,
      device's own filter"` -- confirm any gap is explained this way before treating it as missing
      data.)
