# Reset Device Checklist (Interactive)

The physical-cube part of the reset test. Run **after** `Tests/Bench/01-reset-device-checklist.md`,
which has already reset the device, re-paired, and confirmed the event counter dropped to `0`. This
part flips the device once so a *real* post-reset event is generated -- the strongest evidence that
the device's own event numbering restarted from the bottom, which reconnecting alone can't produce.

Requires a person: the flip can only come from physically turning the cube. Assumes the state the
bench run left -- app running, test DB active (`db_type` = `test`), device freshly reset and
re-paired -- and the pre-reset baseline **N** noted there.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Scenario -- a real post-reset event uses the device's own low numbering

**Preconditions:** app running, test DB active (`db_type` = `test`), device freshly reset and
re-paired, pre-reset baseline **N** noted -- all left by the Bench run above. Check `db_type` and
device connection before the flip below; if either doesn't match, the Bench checklist needs
(re-)running first rather than proceeding here.

- [x] **(Claude)** Confirm `db_type` reads `{"type":"test"}` and the device shows connected before
      asking for the flip below. (Confirmed: state carried straight over from the Bench run in the
      same session.)

### Action needed
Flip the device to a different facet once.

- [x] **(You)** Confirm you flipped the device to a different facet. (Confirmed.)
- [x] **(Claude)** Query `device_events` for the max `event_number` now and confirm this new event's
      number is a small number close to the device's own reset baseline -- **1** is expected, but
      **2** or **3** is also a pass if the device was flipped quickly enough right around the reset
      for an intermediate event to be skipped -- and confirm it is far lower than the pre-reset
      baseline **N** from the bench run either way. (Not literally 1-3 this run -- the Bench 04
      checklist, run afterward in the same session, already generated real post-reset events 1-8
      via its own Lock/Pause menu actions before this flip happened. The flip itself produced
      `event_number = 9`, `device_face = 8` -- still a small number, far below the pre-reset
      baseline **N** = 64. Query by `device_events_id DESC`, not `MAX(event_number)`, to find the
      true latest row -- `MAX(event_number)` conflates pre-reset and post-reset rows since old
      rows aren't deleted and the device's own counter isn't unique across a reset.)
- [x] **(Claude)** Query `debug_log` for the `history`-tagged fetch that picked up this new event
      and a following `dev-check` row confirming `device_events max_start_epoch OK`, so the
      post-reset event number is backed by logged evidence, not just the queried row. (Confirmed:
      `trigger=live_event known_max=8` fetch picked up `device_last_event=9`, followed by a
      `dev-check` row confirming `max_start_epoch OK`.)
