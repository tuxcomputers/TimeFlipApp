# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   test/dailyLimit
    commit:   c707de9fa49c1a4eeeb7e9ed972644c9835f3af5
    tree:     clean
    database: rebuilt from the DDL
    started:  2026-08-16 15:25:35
    finished: 2026-08-16 15:31:25
    outcome:  passed
    scripts:  14 run, 0 with failures
    checks:   264 in total
              263 passed
              0 failed
              1 skipped

| script | passed | failed | skipped |
|---|---|---|---|
| 00-setup | 6 | 0 | 0 |
| 01-launch | 9 | 0 | 0 |
| 02-menu-bar | 10 | 0 | 0 |
| 03-settings-window | 26 | 0 | 0 |
| 04-categories | 96 | 0 | 0 |
| 05-faces-timing | 14 | 0 | 0 |
| 06-time-entries | 12 | 0 | 0 |
| 07-history-timer | 8 | 0 | 0 |
| 08-app-settings | 15 | 0 | 0 |
| 09-report | 22 | 0 | 0 |
| 10-google-calendar | 10 | 0 | 0 |
| 11-google-reconnect | 9 | 0 | 1 |
| 12-daily-limit | 19 | 0 | 0 |
| 99-quit | 7 | 0 | 0 |
| **total** | **263** | **0** | **1** |

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
