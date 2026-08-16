# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   feature/codeOverhaul
    commit:   111c05c70bdf619ff72e48c7c1495ed714e07335
    tree:     clean
    database: rebuilt from the DDL
    started:  2026-08-16 10:53:59
    finished: 2026-08-16 10:55:54
    outcome:  failed
    scripts:  5 run, 1 with failures
    checks:   122 passed, 1 failed, 2 skipped

| script | passed | failed | skipped |
|---|---|---|---|
| 00-setup | 6 | 0 | 2 |
| 01-launch | 9 | 0 | 0 |
| 02-menu-bar | 10 | 0 | 0 |
| 03-settings-window | 15 | 0 | 0 |
| 04-categories | 82 | 1 | 0 |

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
