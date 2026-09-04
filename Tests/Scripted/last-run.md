# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   feature/debugRecord
    commit:   3018b9e8084831a6ecdb1ecdffea48af193078e2
    tree:     clean
    database: rebuilt from the DDL
    started:  2026-09-04 10:02:44
    finished: 2026-09-04 10:08:43
    outcome:  failed
    scripts:  9 of 32 run, 1 with failures
    short:    24 ran fewer checks than they declare
    checks:   215 in total
              214 passed
              1 failed

| script | expected | passed | failed | time |
|---|---|---|---|---|
| 00-setup | 1 | 1 | 0 | 1m 01s (0m 03s) |
| 01-launch | 9 | 9 | 0 | 0m 01s |
| 02-menu-bar | 9 | 9 | 0 | 0m 05s |
| 03-settings-window | 26 | 26 | 0 | 0m 23s |
| 04-categories | 98 | 98 | 0 | 1m 51s |
| 05-faces-timing | 19 | 19 | 0 | 0m 27s |
| 06-time-entries | 12 | 12 | 0 | 0m 18s |
| 07-history-timer | 8 | 8 | 0 | 1m 05s |
| 08-app-settings | 44 | 32 | 1 | 0m 44s |
| 09-report | 22 | 0 | 0 | - |
| 10-google-calendar | 10 | 0 | 0 | - |
| 11-google-reconnect | 17 | 0 | 0 | - |
| 12-daily-limit | 34 | 0 | 0 | - |
| 13-device-tab | 45 | 0 | 0 | - |
| 50-device-scan | 15 | 0 | 0 | - |
| 51-device-connect | 41 | 0 | 0 | - |
| 52-device-reset | 32 | 0 | 0 | - |
| 53-device-reconnect | 24 | 0 | 0 | - |
| 54-device-battery | 12 | 0 | 0 | - |
| 55-device-face | 46 | 0 | 0 | - |
| 56-manual-mode | 37 | 0 | 0 | - |
| 57-cube-pause | 39 | 0 | 0 | - |
| 58-wrong-pin | 22 | 0 | 0 | - |
| 59-double-tap | 19 | 0 | 0 | - |
| 60-device-backlog | 23 | 0 | 0 | - |
| 61-lock-without-pause | 25 | 0 | 0 | - |
| 62-forced-pause | 20 | 0 | 0 | - |
| 63-led-settings | 18 | 0 | 0 | - |
| 64-face-colours | 12 | 0 | 0 | - |
| 65-auto-pause | 18 | 0 | 0 | - |
| 66-device-rename | 21 | 0 | 0 | - |
| 99-quit | 14 | 0 | 0 | - |
| **total** | **792** | **214** | **1** | **5m 55s (0m 03s)** |

A bracketed figure is time the script spent waiting for a person, already taken out of the time beside it.

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
