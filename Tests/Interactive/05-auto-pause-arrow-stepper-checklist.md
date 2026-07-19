# Auto-Pause Arrow Stepper Checklist (Interactive)

The press-and-hold gesture part of the auto-pause stepper. Run **after**
`Tests/Bench/05-auto-pause-arrow-stepper-checklist.md`. Every scenario needs a person to click and
*hold* the mouse button on the arrow (and, in Scenario C, close the window with the other hand while
still holding) -- a real held-mouse gesture and the on-screen value read, neither of which a harness
or a `sqlite3` query can produce. The `(Claude)` steps set the starting value and check the DB
around each hold.

Assumes the state the bench run left: app running, test DB active (`db_type` = `test`), Preferences
open on the Device tab.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Scenario A -- press-and-hold acceleration, up arrow

- [ ] **(Claude)** Type `1` directly into the auto-pause text field (starting value for the hold).

### Action needed
Click and hold the **up** arrow on the auto-pause field (don't release the mouse button) until the
value passes 30, then release. Report the full sequence of numbers you see, and whether the tick
rate visibly changes partway through.

- [ ] **(You)** Report the observed sequence and whether the pace changed.
- [ ] **(Claude)** Confirm the reported sequence is `2, 3, 4, 5, 6, 7, 8, 9, 10, 15, 20, 25, 30` (or
      further multiples of 5 beyond 30, depending on how long the button was held) -- single-digit
      steps up through 10 (the second gridline past the starting value of 1 -- `secondBoundary`
      uses integer division, so 1 and 4 both land on the same 5/10 gridlines, just with a longer
      visible ramp starting from 1), then steps of 5 -- and that the user reported the steps-of-5
      phase as *slower*, not faster or the same pace, than the single-digit phase.
- [ ] **(Claude)** Query the DB and confirm `auto_pause_minutes` matches the final on-screen value.

## Scenario B -- press-and-hold acceleration, down arrow

- [ ] **(Claude)** Type `26` directly into the auto-pause text field.

### Action needed
Click and hold the **down** arrow (don't release) until the value reaches 0, then release. Report
the full sequence of numbers you see.

- [ ] **(You)** Report the observed sequence.
- [ ] **(Claude)** Confirm it mirrors Scenario A: `25, 24, 23, 22, 21, 20, 15, 10, 5, 0` -- single
      digits down to 20 (the second gridline below 26), then by 5 down to 0 -- and that the field
      stayed at 0 rather than going negative once the down arrow was held past it.

## Scenario C -- a hold interrupted by closing the window doesn't keep running

- [ ] **(Claude)** Type `50` directly into the auto-pause text field.

### Action needed
Click and hold the **up** arrow. While still holding the mouse button down, press **Cmd+W** with
your other hand to close the Preferences window. Wait about 5 seconds, then reopen Preferences
(the mouse button can be released at any point after the window closes).

- [ ] **(You)** Confirm you completed the steps above.
- [ ] **(Claude)** Query `auto_pause_minutes` immediately after reopening and again 5 seconds later;
      confirm the two readings are identical (the hold did not keep advancing after the window
      closed).
- [ ] **(Claude)** Note `auto_pause_minutes`, click the up arrow once (a plain click, not a hold --
      this is a normal button click, unlike the hold gesture above, so it's Claude-drivable), and
      confirm the value increased by exactly 1 -- i.e. the arrow isn't stuck "held" from before.
