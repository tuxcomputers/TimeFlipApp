# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   chore/singleMode
    commit:   3be097b6305e687067fc22f8bcb48e7be6ed06e7
    tree:     clean
    database: rebuilt from the DDL
    started:  2026-08-23 21:19:36
    finished: 2026-08-23 21:35:50
    outcome:  failed
    scripts:  22 of 24 run, 0 with failures
    short:    2 ran fewer checks than they declare
    checks:   551 in total
              551 passed
              0 failed

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
| 12-daily-limit | 32 | 32 | 0 |
| 13-device-tab | 27 | 27 | 0 |
| 50-device-scan | 15 | 15 | 0 |
| 51-device-connect | 41 | 41 | 0 |
| 52-device-reset | 33 | 33 | 0 |
| 53-device-reconnect | 23 | 23 | 0 |
| 54-device-battery | 10 | 10 | 0 |
| 55-device-face | 43 | 43 | 0 |
| 56-manual-mode | 29 | 29 | 0 |
| 57-cube-pause | 38 | 39 | 0 |
| 58-wrong-pin | 21 | 0 | 0 |
| 99-quit | 13 | 0 | 0 |
| **total** | **584** | **551** | **0** |

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
