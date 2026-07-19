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

### Action needed
Flip the device to a different facet once.

- [ ] **(You)** Confirm you flipped the device to a different facet.
- [ ] **(Claude)** Query `device_events` for the max `event_number` now and confirm this new event's
      number is a small number close to the device's own reset baseline -- **1** is expected, but
      **2** or **3** is also a pass if the device was flipped quickly enough right around the reset
      for an intermediate event to be skipped -- and confirm it is far lower than the pre-reset
      baseline **N** from the bench run either way.
- [ ] **(Claude)** Query `debug_log` for the `history`-tagged fetch that picked up this new event
      and a following `dev-check` row confirming `device_events max_start_epoch OK`, so the
      post-reset event number is backed by logged evidence, not just the queried row.
