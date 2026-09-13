# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   feature/linuxPort
    commit:   f99dfe893f25d727224a621449a64bd0acb713d9
    tree:     clean
    database: rebuilt from the DDL
    started:  2026-09-13 13:15:43
    finished: 2026-09-13 13:43:28
    outcome:  failed
    scripts:  24 of 32 run, 1 with failures
    short:    9 ran fewer checks than they declare
    checks:   639 in total
              638 passed
              1 failed

| script | expected | passed | failed | time |
|---|---|---|---|---|
| 00-setup | 1 | 1 | 0 | 0m 53s (0m 07s) |
| 01-launch | 9 | 9 | 0 | 0m 01s |
| 02-menu-bar | 9 | 9 | 0 | 0m 05s |
| 03-settings-window | 32 | 32 | 0 | 0m 24s |
| 04-categories | 101 | 101 | 0 | 1m 53s |
| 05-faces-timing | 28 | 28 | 0 | 0m 35s |
| 06-time-entries | 12 | 12 | 0 | 0m 19s |
| 07-history-timer | 8 | 8 | 0 | 1m 04s |
| 08-app-settings | 44 | 44 | 0 | 0m 34s |
| 09-report | 22 | 22 | 0 | 0m 17s |
| 10-google-calendar | 10 | 10 | 0 | 0m 16s |
| 11-google-reconnect | 17 | 17 | 0 | 0m 16s (2m 46s) |
| 12-daily-limit | 34 | 34 | 0 | 1m 39s |
| 13-device-tab | 40 | 40 | 0 | 0m 26s |
| 50-device-scan | 15 | 15 | 0 | 0m 28s |
| 51-device-connect | 41 | 41 | 0 | 0m 26s |
| 52-device-reset | 32 | 32 | 0 | 0m 44s |
| 53-device-reconnect | 26 | 26 | 0 | 0m 54s |
| 54-device-battery | 12 | 12 | 0 | 0m 52s |
| 55-device-face | 46 | 46 | 0 | 1m 14s (0m 19s) |
| 56-manual-mode | 37 | 37 | 0 | 1m 50s (3m 23s) |
| 57-cube-pause | 39 | 39 | 0 | 0m 33s (3m 19s) |
| 58-wrong-pin | 22 | 22 | 0 | 0m 47s |
| 59-double-tap | 4 | 1 | 1 | 1m 20s |
| 60-device-backlog | 23 | 0 | 0 | - |
| 61-lock-without-pause | 25 | 0 | 0 | - |
| 62-forced-pause | 20 | 0 | 0 | - |
| 63-led-settings | 18 | 0 | 0 | - |
| 64-face-colours | 12 | 0 | 0 | - |
| 65-auto-pause | 18 | 0 | 0 | - |
| 66-device-rename | 22 | 0 | 0 | - |
| 99-quit | 14 | 0 | 0 | - |
| **total** | **793** | **638** | **1** | **17m 50s (9m 54s)** |

A bracketed figure is time the script spent waiting for a person, already taken out of the time beside it.

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
