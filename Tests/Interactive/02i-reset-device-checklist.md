# Reset Device Checklist (Interactive)

The physical-flip part of the reset test. Run **after the whole Bench phase**
(`Tests/Bench/02b-reset-device-checklist.md` included) -- by this point the device is already reset
*and* re-paired: `02b`'s own last steps click **Scan for Devices** and then the discovered-device
row itself (an ad hoc user click, since that row doesn't respond to any Claude-driven click --
Method: Discovered-device row click, `../Methods.md` -- and Bench must end with the device paired
for `03b`-`07b` to run, which can't wait for the Interactive phase). So there's no separate
re-pairing step here anymore -- what's left is flipping the device once so a *real* post-reset event
is generated, the strongest evidence that the device's own event numbering restarted from the
bottom, which reconnecting alone can't produce.

Requires a person for the flip. Assumes the state the whole Bench phase left -- app running, test DB
active (`db_type` = `test`), device freshly reset and re-paired -- and the pre-reset baseline **N**
noted by `02b`.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Scenario A -- a real post-reset event uses the device's own low numbering

**Preconditions:** app running, test DB active (`db_type` = `test`), device paired and connected
(left by `02b-reset-device-checklist.md`, run earlier in the same Bench phase), pre-reset baseline
**N** noted there. Check `db_type` and device connection before the flip below; if either doesn't
match, re-run `02b` first rather than proceeding here.

- [ ] **(Claude)** Confirm `db_type` reads `{"type":"test"}` and the device shows connected before
      asking for the flip below.

### Action needed
Flip the device to a different facet once.

- [ ] **(You)** Confirm you flipped the device to a different facet.
- [ ] **(Claude)** Query `device_event` (Method: Read debug output, `../Methods.md` -- by
      `device_event_id DESC`, not `MAX(event_number)`, since old pre-reset rows aren't deleted and
      the device's own counter isn't unique across a reset) for the new event's `event_number` and
      confirm it is a small number close to the device's own reset baseline -- **1** is expected, but
      a slightly higher small number is also a pass if earlier post-reset events were already
      generated this session (e.g. during `02b`'s own re-pair) -- and confirm it is far lower than
      the pre-reset baseline **N** from `02b` either way.
- [ ] **(Claude)** Query `debug_log` for the `history`-tagged fetch that picked up this new event
      (`trigger=live_event`, `device_last_event=` the new small number) and a following `dev-check`
      row confirming `device_event max_start_epoch OK`, so the post-reset event number is backed by
      logged evidence, not just the queried row.
