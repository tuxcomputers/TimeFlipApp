# Report Tab Checklist

### Last run - 2026-08-10 20:29 on the branch 'feature/singleInstance'

Nothing needed.

The Report tab reads the database and draws it. Every step is a click in the Settings window and a
value read back through accessibility, so the whole thing lives in `Tests/Bench/11b` -- the device
only has to be switched on and in range, the same as it would be for the app to run at all.

Nothing here needs a hand on the cube, and deliberately so: the fixture is **seeded**, on days 3 to 5
back, precisely to avoid depending on what anyone happened to flip. Time recorded by a real flip is
already covered where it belongs -- `Interactive/10i` proves a live segment reaches the totals, and
`Interactive/01i` proves history arrives from the device at all. What is left for the report is
arithmetic over rows that already exist, which is exactly what a Bench checklist is for.

The one part that might have needed an eye -- reading the figures off the screen -- turned out to be
accessibility-readable: each row contributes its category name and duration as `static text`, so they
are asserted directly rather than screenshotted. See [Method 28](../Methods.md#method-28).
