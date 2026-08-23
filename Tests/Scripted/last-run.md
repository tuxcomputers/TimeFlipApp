# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   chore/singleMode
    commit:   ed20f0cb62867d46e3bad7088d3f4ebec8fd510e
    tree:     clean
    database: rebuilt from the DDL
    started:  2026-08-23 22:06:13
    finished: 2026-08-23 22:15:32
    outcome:  failed
    scripts:  13 of 24 run, 1 with failures
    short:    12 ran fewer checks than they declare
    checks:   268 in total
              267 passed
              1 failed

| script | expected | passed | failed |
|---|---|---|---|
| 00-setup | 1 | 1 | 0 |
| 01-launch | 9 | 9 | 0 |
| 02-menu-bar | 10 | 10 | 0 |
| 03-settings-window | 26 | 26 | 0 |
| 04-categories | 96 | 96 | 0 |
| 05-faces-timing | 17 | 17 | 0 |
| 06-time-entries | 12 | 12 | 0 |
| 07-history-timer | 8 | 8 | 0 |
| 08-app-settings | 31 | 31 | 0 |
| 09-report | 22 | 22 | 0 |
| 10-google-calendar | 10 | 10 | 0 |
| 11-google-reconnect | 17 | 17 | 0 |
| 12-daily-limit | 32 | 8 | 1 |
| 13-device-tab | 27 | 0 | 0 |
| 50-device-scan | 15 | 0 | 0 |
| 51-device-connect | 41 | 0 | 0 |
| 52-device-reset | 33 | 0 | 0 |
| 53-device-reconnect | 23 | 0 | 0 |
| 54-device-battery | 10 | 0 | 0 |
| 55-device-face | 43 | 0 | 0 |
| 56-manual-mode | 29 | 0 | 0 |
| 57-cube-pause | 38 | 0 | 0 |
| 58-wrong-pin | 21 | 0 | 0 |
| 99-quit | 14 | 0 | 0 |
| **total** | **585** | **267** | **1** |

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
