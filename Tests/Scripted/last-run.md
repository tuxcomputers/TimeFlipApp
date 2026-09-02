# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   bugfix/missingDevice
    commit:   a4b4481c378c5042e2e0e1de3fa62b422cba2d55
    tree:     clean
    database: rebuilt from the DDL
    started:  2026-09-02 21:34:31
    finished: 2026-09-02 22:18:06
    outcome:  passed
    scripts:  32 of 32 run, 0 with failures
    short:    0 ran fewer checks than they declare
    checks:   749 in total
              749 passed
              0 failed

| script | expected | passed | failed | time |
|---|---|---|---|---|
| 00-setup | 1 | 1 | 0 | 0m 54s (0m 57s) |
| 01-launch | 9 | 9 | 0 | 0m 01s |
| 02-menu-bar | 10 | 10 | 0 | 0m 05s |
| 03-settings-window | 26 | 26 | 0 | 0m 22s |
| 04-categories | 98 | 98 | 0 | 1m 49s |
| 05-faces-timing | 19 | 19 | 0 | 0m 26s |
| 06-time-entries | 12 | 12 | 0 | 0m 19s |
| 07-history-timer | 8 | 8 | 0 | 1m 04s |
| 08-app-settings | 31 | 31 | 0 | 0m 28s |
| 09-report | 22 | 22 | 0 | 0m 16s |
| 10-google-calendar | 10 | 10 | 0 | 0m 17s |
| 11-google-reconnect | 17 | 17 | 0 | 0m 15s (2m 09s) |
| 12-daily-limit | 34 | 34 | 0 | 1m 39s |
| 13-device-tab | 34 | 34 | 0 | 0m 23s |
| 50-device-scan | 15 | 15 | 0 | 0m 23s |
| 51-device-connect | 41 | 41 | 0 | 0m 27s |
| 52-device-reset | 32 | 32 | 0 | 0m 43s |
| 53-device-reconnect | 24 | 24 | 0 | 0m 55s |
| 54-device-battery | 9 | 9 | 0 | 0m 46s |
| 55-device-face | 46 | 46 | 0 | 1m 07s (1m 25s) |
| 56-manual-mode | 35 | 35 | 0 | 1m 49s (4m 19s) |
| 57-cube-pause | 38 | 38 | 0 | 0m 36s (1m 25s) |
| 58-wrong-pin | 20 | 20 | 0 | 0m 43s |
| 59-double-tap | 19 | 19 | 0 | 0m 12s |
| 60-device-backlog | 23 | 23 | 0 | 0m 37s (2m 14s) |
| 61-lock-without-pause | 13 | 13 | 0 | 0m 16s |
| 62-forced-pause | 20 | 20 | 0 | 0m 31s (6m 33s) |
| 63-led-settings | 18 | 18 | 0 | 0m 18s |
| 64-face-colours | 12 | 12 | 0 | 0m 28s |
| 65-auto-pause | 18 | 18 | 0 | 1m 31s (3m 39s) |
| 66-device-rename | 21 | 21 | 0 | 0m 33s |
| 99-quit | 14 | 14 | 0 | 0m 40s |
| **total** | **749** | **749** | **0** | **20m 53s (22m 41s)** |

A bracketed figure is time the script spent waiting for a person, already taken out of the time beside it.

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
