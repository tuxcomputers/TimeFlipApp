# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   feature/autoPause
    commit:   4a350ada5d5cb1ba046003db5a9fc51cde0f685c
    tree:     clean
    database: rebuilt from the DDL
    started:  2026-08-27 21:42:57
    finished: 2026-08-27 22:03:23
    outcome:  failed
    scripts:  22 of 28 run, 0 with failures
    short:    7 ran fewer checks than they declare
    checks:   550 in total
              550 passed
              0 failed

| script | expected | passed | failed | time |
|---|---|---|---|---|
| 00-setup | 1 | 1 | 0 | 0m 56s (0m 53s) |
| 01-launch | 9 | 9 | 0 | 0m 01s |
| 02-menu-bar | 10 | 10 | 0 | 0m 05s |
| 03-settings-window | 26 | 26 | 0 | 0m 22s |
| 04-categories | 96 | 96 | 0 | 1m 46s |
| 05-faces-timing | 19 | 19 | 0 | 0m 26s |
| 06-time-entries | 12 | 12 | 0 | 0m 18s |
| 07-history-timer | 8 | 8 | 0 | 1m 05s |
| 08-app-settings | 31 | 31 | 0 | 0m 28s |
| 09-report | 22 | 22 | 0 | 0m 16s |
| 10-google-calendar | 10 | 10 | 0 | 0m 17s |
| 11-google-reconnect | 17 | 17 | 0 | 0m 16s (1m 52s) |
| 12-daily-limit | 34 | 34 | 0 | 1m 38s |
| 13-device-tab | 27 | 27 | 0 | 0m 21s |
| 50-device-scan | 15 | 15 | 0 | 0m 23s |
| 51-device-connect | 41 | 41 | 0 | 0m 23s |
| 52-device-reset | 32 | 32 | 0 | 0m 41s |
| 53-device-reconnect | 21 | 21 | 0 | 0m 49s |
| 54-device-battery | 9 | 9 | 0 | 0m 37s |
| 55-device-face | 46 | 46 | 0 | 1m 13s (1m 18s) |
| 56-manual-mode | 28 | 28 | 0 | 1m 42s (1m 35s) |
| 57-cube-pause | 37 | 36 | 0 | 0m 35s (0m 08s) |
| 58-wrong-pin | 20 | 0 | 0 | - |
| 59-double-tap | 17 | 0 | 0 | - |
| 60-device-backlog | 21 | 0 | 0 | - |
| 61-lock-without-pause | 13 | 0 | 0 | - |
| 62-forced-pause | 13 | 0 | 0 | - |
| 99-quit | 14 | 0 | 0 | - |
| **total** | **649** | **550** | **0** | **14m 38s (5m 46s)** |

A bracketed figure is time the script spent waiting for a person, already taken out of the time beside it.

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
