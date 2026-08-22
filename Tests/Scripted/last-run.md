# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   feature/debugLog
    commit:   a8715b50b680cd5b59e245d8b4ac618dbfcac86e
    tree:     clean
    database: rebuilt from the DDL
    started:  2026-08-22 20:05:31
    finished: 2026-08-22 20:06:55
    outcome:  failed
    scripts:  5 run, 1 with failures
    checks:   89 in total
              88 passed
              1 failed
              0 skipped

| script | passed | failed | skipped |
|---|---|---|---|
| 00-setup | 6 | 0 | 0 |
| 01-launch | 9 | 0 | 0 |
| 02-menu-bar | 10 | 0 | 0 |
| 03-settings-window | 26 | 0 | 0 |
| 04-categories | 37 | 1 | 0 |
| **total** | **88** | **1** | **0** |

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
