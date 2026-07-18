# Auto-Pause Arrow Stepper Checklist

Covers the auto-pause field's press-and-hold arrow behavior (`AutoPauseStepper`): ticks by 1 until
passing the *second* multiple-of-5 gridline from the value the hold started at, then by 5, at a
slower tick rate. This replaced a stock SwiftUI `Stepper` (whose held-repeat rate can't be varied),
so none of this has any prior interactive coverage. Also covers a fix for a hold whose release
event never arrives (window closed while the mouse button was still down), which would otherwise
keep the repeat loop -- and its device/DB writes -- running in the background. Requires Developer
Mode enabled and a paired, connected device (the field is disabled while unpaired).

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Setup

- [ ] **(You)** Quit the app if it's running.
- [ ] **(Claude)** Run `scripts/use-test-database.sh`.
- [ ] **(You)** Start the app and confirm it reconnects to the device.
- [ ] **(Claude)** Query `db_type` and confirm it reads `{"type":"test"}` before proceeding:
      `sqlite3 ~/Library/Application\ Support/TimeFlip/appdata.sqlite "SELECT setting_value FROM
      setting WHERE setting_name = 'db_type';"`.
- [ ] **(You)** Open Preferences, Device tab. Confirm **Auto-pause** sits at the top of the
      **Settings** section, above the collapsed **LED** disclosure (not inside a separate
      **Advanced** section, which no longer exists).

## Scenario A -- press-and-hold acceleration, up arrow

- [ ] **(Claude)** Type `4` directly into the auto-pause text field and confirm the DB row
      updated: `SELECT setting_value FROM setting WHERE setting_name = 'auto_pause_minutes';`
      should read `{"minutes":4}`.

### Action needed
Click and hold the **up** arrow on the auto-pause field (don't release the mouse button) until the
value passes 30, then release. Report the full sequence of numbers you see, and whether the tick
rate visibly changes partway through.

- [ ] **(You)** Report the observed sequence and whether the pace changed.
- [ ] **(Claude)** Confirm the reported sequence is `5, 6, 7, 8, 9, 10, 15, 20, 25, 30` (or further
      multiples of 5 beyond 30, depending on how long the button was held) -- single-digit steps
      up through 10 (the second gridline past the starting value of 4), then steps of 5 -- and
      that the user reported the steps-of-5 phase as *slower*, not faster or the same pace, than
      the single-digit phase.
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
- [ ] **(You)** On the reopened Device tab, click the up arrow once (a plain click, not a hold) and
      confirm the value increases by exactly 1 -- i.e. the arrow isn't stuck "held" from before.
