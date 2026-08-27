# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   feature/autoPause
    commit:   dc61c23d85bbd0e4a345ab30fd928234a6e347c2
    tree:     clean
    database: rebuilt from the DDL
    started:  2026-08-27 22:14:52
    finished: 2026-08-27 22:28:17
    outcome:  failed
    scripts:  20 of 28 run, 0 with failures
    short:    9 ran fewer checks than they declare
    checks:   485 in total
              485 passed
              0 failed

| script | expected | passed | failed | time |
|---|---|---|---|---|
| 00-setup | 1 | 1 | 0 | 0m 54s (0m 10s) |
| 01-launch | 9 | 9 | 0 | 0m 02s |
| 02-menu-bar | 10 | 10 | 0 | 0m 04s |
| 03-settings-window | 26 | 26 | 0 | 0m 23s |
| 04-categories | 96 | 96 | 0 | 1m 46s |
| 05-faces-timing | 19 | 19 | 0 | 0m 26s |
| 06-time-entries | 12 | 12 | 0 | 0m 18s |
| 07-history-timer | 8 | 8 | 0 | 1m 05s |
| 08-app-settings | 31 | 31 | 0 | 0m 27s |
| 09-report | 22 | 22 | 0 | 0m 16s |
| 10-google-calendar | 10 | 10 | 0 | 0m 17s |
| 11-google-reconnect | 17 | 17 | 0 | 0m 10s (0m 22s) |
| 12-daily-limit | 34 | 34 | 0 | 1m 39s |
| 13-device-tab | 27 | 27 | 0 | 0m 21s |
| 50-device-scan | 15 | 15 | 0 | 0m 24s |
| 51-device-connect | 41 | 41 | 0 | 0m 25s |
| 52-device-reset | 32 | 32 | 0 | 0m 46s |
| 53-device-reconnect | 21 | 21 | 0 | 0m 51s |
| 54-device-battery | 9 | 9 | 0 | 0m 47s |
| 55-device-face | 46 | 45 | 0 | 1m 05s (0m 27s) |
| 56-manual-mode | 28 | 0 | 0 | - |
| 57-cube-pause | 37 | 0 | 0 | - |
| 58-wrong-pin | 20 | 0 | 0 | - |
| 59-double-tap | 17 | 0 | 0 | - |
| 60-device-backlog | 21 | 0 | 0 | - |
| 61-lock-without-pause | 13 | 0 | 0 | - |
| 62-forced-pause | 13 | 0 | 0 | - |
| 99-quit | 14 | 0 | 0 | - |
| **total** | **649** | **485** | **0** | **12m 26s (0m 59s)** |

A bracketed figure is time the script spent waiting for a person, already taken out of the time beside it.

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
