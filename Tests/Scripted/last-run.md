# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   feature/groupings
    commit:   54a584e82e93d8c9da6c1f17383af108540c026d
    tree:     clean
    database: rebuilt from the DDL
    started:  2026-08-22 21:43:12
    finished: 2026-08-22 21:59:26
    outcome:  failed
    scripts:  22 run, 1 with failures
    checks:   526 in total
              525 passed
              1 failed
              0 skipped

| script | passed | failed | skipped |
|---|---|---|---|
| 00-setup | 6 | 0 | 0 |
| 01-launch | 9 | 0 | 0 |
| 02-menu-bar | 10 | 0 | 0 |
| 03-settings-window | 26 | 0 | 0 |
| 04-categories | 96 | 0 | 0 |
| 05-faces-timing | 17 | 0 | 0 |
| 06-time-entries | 12 | 0 | 0 |
| 07-history-timer | 8 | 0 | 0 |
| 08-app-settings | 31 | 0 | 0 |
| 09-report | 22 | 0 | 0 |
| 10-google-calendar | 10 | 0 | 0 |
| 11-google-reconnect | 17 | 0 | 0 |
| 12-daily-limit | 32 | 0 | 0 |
| 13-device-tab | 27 | 0 | 0 |
| 50-device-scan | 14 | 0 | 0 |
| 51-device-connect | 41 | 0 | 0 |
| 52-device-reset | 33 | 0 | 0 |
| 53-device-reconnect | 22 | 0 | 0 |
| 54-device-battery | 10 | 0 | 0 |
| 55-device-face | 43 | 0 | 0 |
| 56-manual-mode | 28 | 0 | 0 |
| 57-cube-pause | 11 | 1 | 0 |
| **total** | **525** | **1** | **0** |

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
