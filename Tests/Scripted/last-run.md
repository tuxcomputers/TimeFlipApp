# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   feature/ledSettings
    commit:   f4e8cb1a1b7fdcbbba4e636c631d948a7fc28369
    tree:     clean
    database: rebuilt from the DDL
    started:  2026-08-28 22:38:58
    finished: 2026-08-28 23:03:52
    outcome:  passed
    scripts:  30 of 30 run, 0 with failures
    short:    0 ran fewer checks than they declare
    checks:   690 in total
              690 passed
              0 failed

| script | expected | passed | failed | time |
|---|---|---|---|---|
| 00-setup | 1 | 1 | 0 | 1m 47s (0m 36s) |
| 01-launch | 9 | 9 | 0 | 0m 02s |
| 02-menu-bar | 10 | 10 | 0 | 0m 05s |
| 03-settings-window | 26 | 26 | 0 | 0m 22s |
| 04-categories | 96 | 96 | 0 | 1m 46s |
| 05-faces-timing | 19 | 19 | 0 | 0m 26s |
| 06-time-entries | 12 | 12 | 0 | 0m 19s |
| 07-history-timer | 8 | 8 | 0 | 1m 04s |
| 08-app-settings | 31 | 31 | 0 | 0m 28s |
| 09-report | 22 | 22 | 0 | 0m 16s |
| 10-google-calendar | 10 | 10 | 0 | 0m 17s |
| 11-google-reconnect | 17 | 17 | 0 | 0m 25s (0m 59s) |
| 12-daily-limit | 34 | 34 | 0 | 1m 38s |
| 13-device-tab | 27 | 27 | 0 | 0m 21s |
| 50-device-scan | 15 | 15 | 0 | 0m 24s |
| 51-device-connect | 41 | 41 | 0 | 0m 25s |
| 52-device-reset | 32 | 32 | 0 | 0m 43s |
| 53-device-reconnect | 21 | 21 | 0 | 0m 51s |
| 54-device-battery | 9 | 9 | 0 | 0m 46s |
| 55-device-face | 46 | 46 | 0 | 1m 08s (0m 14s) |
| 56-manual-mode | 28 | 28 | 0 | 1m 44s (1m 07s) |
| 57-cube-pause | 38 | 38 | 0 | 0m 35s (0m 07s) |
| 58-wrong-pin | 20 | 20 | 0 | 0m 44s |
| 59-double-tap | 19 | 19 | 0 | 0m 11s |
| 60-device-backlog | 22 | 22 | 0 | 0m 32s (1m 27s) |
| 61-lock-without-pause | 13 | 13 | 0 | 0m 16s |
| 62-forced-pause | 20 | 20 | 0 | 0m 27s (0m 52s) |
| 63-led-settings | 18 | 18 | 0 | 0m 18s |
| 64-face-colours | 12 | 12 | 0 | 0m 29s |
| 99-quit | 14 | 14 | 0 | 0m 40s |
| **total** | **690** | **690** | **0** | **19m 29s (5m 22s)** |

A bracketed figure is time the script spent waiting for a person, already taken out of the time beside it.

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
