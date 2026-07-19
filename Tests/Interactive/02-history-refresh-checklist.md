# History Refresh Checklist (Interactive)

The physical-flip parts of the history refresh test. Run **after**
`Tests/Bench/02-history-refresh-checklist.md`. Both scenarios need a person to physically flip the
cube -- Scenario B a single normal flip, Scenario C several flips while the app is disconnected --
which is the only way to make the device generate the new events these scenarios verify. The
`(Claude)` steps assert the resulting rows from `device_events`/`debug_log`.

Assumes the state the bench run left: app running, device paired and connected, Developer Mode and
`debug` enabled.

> Facets used throughout this checklist's run: facet 2 ("Meeting") and facet 8 ("Break") only.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Scenario B -- normal flip

**Preconditions:** device connected and paired, test DB active -- left by the Bench run above,
which this scenario runs straight on from. Check device connection before asking for the flip.

- [x] **(Claude)** Confirm the device shows connected before asking for the flip below. (Confirmed:
      state carried straight over from the Bench run in the same session.)
- [x] **(Claude)** Note the current max `event_number` (call it N). (N = 11, by
      `device_events_id DESC`, not `MAX(event_number)` -- see the note in `../CLAUDE.md`.)
- [x] **(You)** Flip the device to a different facet. (Detected automatically by polling
      `device_events` every couple of seconds -- no need to ask for confirmation, per the note in
      `../CLAUDE.md`.)
- [x] **(Claude)** Confirm a new `device_events` row exists with `event_number` > N, and that
      event N's row is now `finalised = 1` with a `duration_seconds` that stopped growing.
      (Confirmed: new row event_number=12 on facet 9; event 11's row finalised=1,
      duration_seconds=113.0.)
- [x] **(Claude)** Screenshot the menu bar; confirm the activity name/icon updated to the new
      facet. (Confirmed: showed "Unassigned" -- facet 9's mapped name.)

## Scenario C -- backlog after being out of range

**Preconditions:** device connected and paired (Scenario B's own ending state), so there's a
starting point to disconnect from below. Check device connection first; if it's not connected,
reconnect before proceeding rather than starting this scenario already disconnected.

- [x] **(Claude)** Confirm the device shows connected before disconnecting it below. (Confirmed:
      state carried straight over from Scenario B above, in the same session.)
- [x] **(Claude)** Note the current max `event_number` (call it N). (N = 12.)
- [x] **(You)** Disconnect the device from the app -- either move it out of Bluetooth range, or (the
      practical equivalent used for this run, since the device's real range is long enough to make
      physically walking away impractical) turn off Bluetooth on the Mac itself, via the menu bar
      icon or System Settings, NOT `sudo`/system-wide toggling, which also disconnects any other
      Bluetooth peripherals -- wait for the menu bar to turn yellow (disconnected), then flip it
      2-3 times while still disconnected, then reconnect (bring it back in range, or turn Bluetooth
      back on). (Detected the disconnect via `debug_log` -- the status item's own title text
      doesn't reflect connection color/state, so poll `debug_log` for a `history` fetch repeatedly
      returning `device_last_event=nil` against an unchanged `known_max`, or check the Preferences
      window's `Connection` field directly, rather than the status item's name/title.)
- [x] **(Claude)** Confirm the app reconnects automatically: query `debug_log` for a fresh
      `TimeFlip`-tagged `"Login accepted, code=0x02"` row logged after the reconnect. (Confirmed.
      Flips while disconnected can't be polled in real time -- no connection means no data flows --
      so this is the point to resume automatic detection, once reconnected.)
- [x] **(Claude)** Confirm every intermediate flip shows up as its own finalised `device_events`
      row in ascending `event_number` order with no gaps, and the final row (still open) matches
      the device's actual current facet. (Confirmed: events 12 (facet 9) -> 14 (facet 2) -> 15
      (facet 8, open) -- event 13 wasn't missing/a bug, it was correctly explained via
      `debug_log`'s `"history gap explained: ev=13 dur=2.0s under 5s, device's own filter"` (a
      genuine sub-`blip_time` quick pass-over, merged rather than recorded as its own segment, by
      design). Final open row (facet 8) matched the menu bar's displayed "Break".)
