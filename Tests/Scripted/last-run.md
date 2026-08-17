# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   feature/pairDevice
    commit:   a596cab4fbf72383a2e53f8a25922eb19d08555b
    tree:     clean
    database: rebuilt from the DDL
    started:  2026-08-17 20:53:23
    finished: 2026-08-17 21:08:33
    outcome:  passed
    scripts:  17 run, 0 with failures
    checks:   379 in total
              379 passed
              0 failed
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
| 08-app-settings | 15 | 0 | 0 |
| 09-report | 22 | 0 | 0 |
| 10-google-calendar | 10 | 0 | 0 |
| 11-google-reconnect | 17 | 0 | 0 |
| 12-daily-limit | 32 | 0 | 0 |
| 13-device-scan | 14 | 0 | 0 |
| 14-device-connect | 41 | 0 | 0 |
| 15-device-reset | 33 | 0 | 0 |
| 99-quit | 11 | 0 | 0 |
| **total** | **379** | **0** | **0** |

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
