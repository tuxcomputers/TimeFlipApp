# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   feature/deviceTime
    commit:   3b0e97526838bd133a2bf52f9d4cd9acca953d41
    tree:     clean
    database: rebuilt from the DDL
    started:  2026-08-25 22:19:14
    finished: 2026-08-25 22:36:40
    outcome:  passed
    scripts:  25 of 25 run, 0 with failures
    short:    0 ran fewer checks than they declare
    checks:   607 in total
              607 passed
              0 failed

| script | expected | passed | failed | time |
|---|---|---|---|---|
| 00-setup | 1 | 1 | 0 | 0m 52s |
| 01-launch | 9 | 9 | 0 | 0m 01s |
| 02-menu-bar | 10 | 10 | 0 | 0m 05s |
| 03-settings-window | 26 | 26 | 0 | 0m 23s |
| 04-categories | 96 | 96 | 0 | 1m 46s |
| 05-faces-timing | 17 | 17 | 0 | 0m 26s |
| 06-time-entries | 12 | 12 | 0 | 0m 19s |
| 07-history-timer | 8 | 8 | 0 | 1m 04s |
| 08-app-settings | 31 | 31 | 0 | 0m 28s |
| 09-report | 22 | 22 | 0 | 0m 17s |
| 10-google-calendar | 10 | 10 | 0 | 0m 16s |
| 11-google-reconnect | 17 | 17 | 0 | 0m 28s |
| 12-daily-limit | 32 | 32 | 0 | 1m 38s |
| 13-device-tab | 27 | 27 | 0 | 0m 22s |
| 50-device-scan | 15 | 15 | 0 | 0m 25s |
| 51-device-connect | 41 | 41 | 0 | 0m 13s |
| 52-device-reset | 33 | 33 | 0 | 0m 44s |
| 53-device-reconnect | 23 | 23 | 0 | 0m 42s |
| 54-device-battery | 10 | 10 | 0 | 0m 26s |
| 55-device-face | 46 | 46 | 0 | 0m 55s |
| 56-manual-mode | 29 | 29 | 0 | 1m 59s |
| 57-cube-pause | 38 | 38 | 0 | 0m 57s |
| 58-wrong-pin | 21 | 21 | 0 | 1m 07s |
| 59-double-tap | 19 | 19 | 0 | 0m 32s |
| 99-quit | 14 | 14 | 0 | 1m 00s |
| **total** | **607** | **607** | **0** | **17m 25s** |

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
