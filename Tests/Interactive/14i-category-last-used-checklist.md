# Category Last Used Checklist

### Last run - 2026-08-11 18:35 on the branch 'feature/inactiveID'

Nothing needed.

The Last used column is a date drawn from rows already in the database, and a date is text: it is
accessibility-readable, so `Tests/Bench/14b` asserts the exact characters rather than screenshotting
them. Nothing about it changes with a flip of the cube, and the categories it reports on are retired,
so no face can be on them and no hand on the device can alter what they say.

The fixture is deliberately seeded rather than earned by real flips, and that is what removes the
person from this one: the column's whole job is to report history that is already there, so history
put there on purpose, on known days, tests it better than whatever anyone happened to record. Time
recorded by a real flip reaching the database at all is covered where it belongs, in
`Interactive/01i` and `Interactive/10i`.
