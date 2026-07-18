# History Refresh Checklist

Covers the periodic/live-event history refresh rework: the cheap max-event-number check, the
skip-and-refresh-duration fast path, and the ambiguous/cut-short-stream safeguards (see
`HistoryIngestor.refreshHistory`). Requires a paired physical TimeFlip device and the app running
with Developer Mode enabled and the `debug` setting's `enabled` field `true` (see
`009_setting.sql`) -- every dev-only debug message is then also recorded to the `debug_log` table,
so all `(Claude)` log-reading steps below are plain `sqlite3` queries against it, not a terminal
transcript that has to be captured live.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Setup

- [x] **(You)** Launch the app from a terminal with the device already paired and connected.
- [x] **(Claude)** Query the current state as a baseline:
      `sqlite3 ~/Library/Application\ Support/TimeFlip/appdata.sqlite "SELECT event_number, device_face, duration_seconds, finalised FROM device_events ORDER BY event_number DESC LIMIT 3;"`

## Scenario A -- nothing changes (skip path + duration refresh)

- [x] **(Claude)** Note the current max `event_number` and its `duration_seconds` from Setup.
- [x] **(You)** Leave the device untouched (same facet, not paused) for at least one full
      `fetch_history_interval_seconds` period (check the setting; default is short enough to not
      need a long wait).
- [x] **(Claude)** Query `debug_log` for a `history` row containing `device max_event_number=<N>
      unchanged; DB refreshed` (not a full stream fetch) logged after the baseline query.
- [x] **(Claude)** Re-query `device_events` for that same `event_number` and confirm
      `duration_seconds` increased since the baseline, with no new rows added.

## Scenario B -- normal flip

- [x] **(Claude)** Note the current max `event_number` (call it N).
- [x] **(You)** Flip the device to a different facet.
- [x] **(Claude)** Confirm a new `device_events` row exists with `event_number` > N, and that
      event N's row is now `finalised = 1` with a `duration_seconds` that stopped growing.
- [x] **(You)** Confirm the menu bar activity name/icon updated to the new facet.

## Scenario C -- backlog after being out of range

> Facets used throughout this checklist's run: facet 2 ("Meeting") and facet 8 ("Break") only.

- [x] **(Claude)** Note the current max `event_number` (call it N).
- [x] **(You)** Disconnect the device from the app -- either move it out of Bluetooth range, or (the
      practical equivalent used for this run, since the device's real range is long enough to make
      physically walking away impractical) turn off Bluetooth on the Mac itself, via the menu bar
      icon or System Settings, NOT `sudo`/system-wide toggling, which also disconnects any other
      Bluetooth peripherals -- wait for the menu bar to turn yellow (disconnected), then flip it
      2-3 times while still disconnected, then reconnect (bring it back in range, or turn Bluetooth
      back on).
- [x] **(You)** Confirm the app reconnects automatically (menu bar returns to green).
- [x] **(Claude)** Confirm every intermediate flip shows up as its own finalised `device_events`
      row in ascending `event_number` order with no gaps, and the final row (still open) matches
      the device's actual current facet.

      **Found and fixed during this run:** the first disconnect cycle actually surfaced a real,
      pre-existing gap (event 29 missing from `device_events`). Root cause turned out to be the
      vendor spec's own documented behavior -- 0x02 only streams "intervals that lasted at least 5
      sec", and event 29 was a genuine 4-second segment the device still holds but doesn't include
      in the stream. Added gap detection + targeted single-event (0x01) recovery to
      `TimeFlipBLEDevice.fetchHistory`, which only keeps a recovered entry if it meets that same
      5-second minimum (otherwise it's the device's own filter working as intended, not a bug).
      Verified live: a subsequent disconnect/flip/reconnect cycle produced a fully gapless sequence
      (events 33-36).
- [x] **(Claude)** Confirm `integration_event_cursors` (`identifier = 'device-history'`) advanced
      to the last finalised event number, not the still-open one.

## Scenario D -- quit and relaunch resumes from the persisted cursor

- [x] **(Claude)** Note the current `integration_event_cursors.last_sent_ev` for
      `identifier = 'device-history'`.
- [x] **(You)** Quit the app, then relaunch it.
- [x] **(Claude)** Query `debug_log` for the startup history fetch's `known_max=` value and
      confirm it matches that persisted cursor (not `known_max=0` / a full re-fetch of all
      history).

      Confirmed: `trigger=startup known_max=36`. The cursor had legitimately advanced from 35 to
      36 between the baseline note and quitting (event 36 was finalised in that window), and
      startup correctly resumed from that persisted value rather than re-fetching all history.
- [x] **(You)** Confirm the menu bar shows the correct current facet/duration immediately after
      reconnecting, matching the device's actual state.

      Confirmed: menu bar showed "Meeting" at 20:07, paused. That's the accumulated total of
      today's non-paused, finalized Meeting segments since the 3am daily reset window (events 18,
      20, 23, 27, 32, 34, 36: 1+301+301+33+5+265+302 = 1208s = 20:08) -- not the still-open event
      37's own `duration_seconds`, which is excluded both because it isn't finalized yet and
      because it's currently paused (`is_paused=1`). Matches `dailyFacetDurations`/`isPaused` logic
      in `MenuBarController.swift`/`DailyFacetTotals.swift` exactly.
