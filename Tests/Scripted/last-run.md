# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   feature/codeOverhaul
    commit:   39c556a114f56f3a8178701cca21b40ae1fd6f85
    tree:     clean
    database: rebuilt from the DDL
    started:  2026-08-16 10:27:49
    finished: 2026-08-16 10:29:35
    outcome:  failed
    scripts:  5 run, 1 with failures
    checks:   112 passed, 3 failed, 0 skipped

| script | passed | failed | skipped |
|---|---|---|---|
| 00-setup | 8 | 0 | 0 |
| 01-launch | 9 | 0 | 0 |
| 02-menu-bar | 10 | 0 | 0 |
| 03-settings-window | 15 | 0 | 0 |
| 04-categories | 70 | 3 | 0 |

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
