# Single Instance Checklist

### Last run - 2026-08-11 18:35 on the branch 'feature/inactiveID'

Nothing needed.

Whether a second launch stands down is a question about processes, not about anything on screen or
on the cube: the duplicate exits before it opens the database, claims a status item or reaches the
radio, so there is nothing for a person to look at. `Tests/Bench/13b` launches the built app a
second time, reads what it printed and counts the processes left, which is the whole of it.

The one thing that might have wanted an eye, that no second status item appears in the menu bar, is
better answered by `13b` Step 2 than by looking: a duplicate that got far enough to draw a status
item would still be running, and a process count catches that whether or not anyone happened to be
watching the menu bar at the time.

The device is not involved beyond being connected, and `13b` Scenario A Step 4 confirms the
incumbent still holds it.
