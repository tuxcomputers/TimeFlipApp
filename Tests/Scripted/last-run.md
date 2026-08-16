# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   feature/codeOverhaul
    commit:   de2579d8332eebc6f66c14c5758a3430eecc8ee3
    tree:     clean
    database: rebuilt from the DDL
    started:  2026-08-16 11:13:05
    finished: 2026-08-16 11:15:06
    outcome:  failed
    scripts:  5 run, 1 with failures
    checks:   121 passed, 1 failed, 2 skipped

| script | passed | failed | skipped |
|---|---|---|---|
| 00-setup | 6 | 0 | 2 |
| 01-launch | 9 | 0 | 0 |
| 02-menu-bar | 10 | 0 | 0 |
| 03-settings-window | 15 | 0 | 0 |
| 04-categories | 81 | 1 | 0 |

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
