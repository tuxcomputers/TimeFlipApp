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

- [ ] **(Claude)** Note the current max `event_number` (call it N).
- [ ] **(You)** Flip the device to a different facet.
- [ ] **(Claude)** Confirm a new `device_events` row exists with `event_number` > N, and that
      event N's row is now `finalised = 1` with a `duration_seconds` that stopped growing.
- [ ] **(Claude)** Screenshot the menu bar; confirm the activity name/icon updated to the new
      facet.

## Scenario C -- backlog after being out of range

- [ ] **(Claude)** Note the current max `event_number` (call it N).
- [ ] **(You)** Disconnect the device from the app -- either move it out of Bluetooth range, or (the
      practical equivalent used for this run, since the device's real range is long enough to make
      physically walking away impractical) turn off Bluetooth on the Mac itself, via the menu bar
      icon or System Settings, NOT `sudo`/system-wide toggling, which also disconnects any other
      Bluetooth peripherals -- wait for the menu bar to turn yellow (disconnected), then flip it
      2-3 times while still disconnected, then reconnect (bring it back in range, or turn Bluetooth
      back on).
- [ ] **(Claude)** Confirm the app reconnects automatically: query `debug_log` for a fresh
      `TimeFlip`-tagged `"Login accepted, code=0x02"` row logged after the reconnect.
- [ ] **(Claude)** Confirm every intermediate flip shows up as its own finalised `device_events`
      row in ascending `event_number` order with no gaps, and the final row (still open) matches
      the device's actual current facet.
