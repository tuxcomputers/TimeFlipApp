# History Refresh Checklist (Interactive)

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

- [ ] **(Claude)** Confirm the device shows connected before asking for the flip below.
- [ ] **(Claude)** Note the current max `event_number` (call it N), by `device_event_id DESC`, not
      `MAX(event_number)` -- Method: Read debug output, `../Methods.md`.
- [ ] **(You)** Flip the device to a different facet. (Detected automatically by polling
      `device_event` every couple of seconds -- no need to ask for confirmation. Method: Detect a
      physical action instead of asking, `../Methods.md`.)
- [ ] **(Claude)** Confirm a new `device_event` row exists with `event_number` > N, and that
      event N's row is now `finalised = 1` with a `duration_seconds` that stopped growing.
- [ ] **(Claude)** Screenshot the menu bar; confirm the activity name/icon updated to the new
      facet.

## Scenario B -- backlog after being out of range

**Preconditions:** device connected and paired (Scenario A's own ending state), so there's a
starting point to disconnect from below. Check device connection first; if it's not connected,
reconnect before proceeding rather than starting this scenario already disconnected.

- [ ] **(Claude)** Confirm the device shows connected before disconnecting it below.
- [ ] **(Claude)** Note the current max `event_number` (call it N).
- [ ] **(You)** Disconnect the device from the app -- either move it out of Bluetooth range, or (the
      practical equivalent used for this run, since the device's real range is long enough to make
      physically walking away impractical) turn off Bluetooth on the Mac itself, via the menu bar
      icon or System Settings, NOT `sudo`/system-wide toggling, which also disconnects any other
      Bluetooth peripherals -- wait for the menu bar to turn yellow (disconnected), then flip it
      2-3 times while still disconnected, then reconnect (bring it back in range, or turn Bluetooth
      back on). (Detect the disconnect via `debug_log` -- the status item's own title text doesn't
      reflect connection color/state, so poll `debug_log` for a `history` fetch repeatedly returning
      `device_last_event=nil` against an unchanged `known_max`, or check the Preferences window's
      `Connection` field directly, rather than the status item's name/title.)
- [ ] **(Claude)** Confirm the app reconnects automatically (Method: Confirm device reconnect,
      `../Methods.md`): query `debug_log` for a fresh `TimeFlip`-tagged `"Login accepted, code=0x02"`
      row logged after the reconnect. Flips while disconnected can't be polled in real time -- no
      connection means no data flows -- so this is the point to resume automatic detection, once
      reconnected.
- [ ] **(Claude)** Confirm every intermediate flip shows up as its own finalised `device_event`
      row in ascending `event_number` order with no gaps, and the final row (still open) matches
      the device's actual current facet. (A gap can be legitimate rather than a bug -- a genuine
      sub-`blip_time` quick pass-over gets merged into the surrounding segment rather than recorded
      as its own row, logged as `debug_log`'s `"history gap explained: ev=<N> dur=<s>s under 5s,
      device's own filter"` -- confirm any gap is explained this way before treating it as missing
      data.)
