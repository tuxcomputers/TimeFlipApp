# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   feature/autoPause
    commit:   233a280bb58e45448aa0fad6706b4a038e0b3d2b
    tree:     clean
    database: rebuilt from the DDL
    started:  2026-08-27 20:26:53
    finished: 2026-08-27 20:44:29
    outcome:  failed
    scripts:  27 of 28 run, 1 with failures
    short:    2 ran fewer checks than they declare
    checks:   630 in total
              629 passed
              1 failed

| script | expected | passed | failed | time |
|---|---|---|---|---|
| 00-setup | 1 | 1 | 0 | 0m 53s (0m 03s) |
| 01-launch | 9 | 9 | 0 | 0m 02s |
| 02-menu-bar | 10 | 10 | 0 | 0m 04s |
| 03-settings-window | 26 | 26 | 0 | 0m 23s |
| 04-categories | 96 | 96 | 0 | 1m 46s |
| 05-faces-timing | 19 | 19 | 0 | 0m 26s |
| 06-time-entries | 12 | 12 | 0 | 0m 19s |
| 07-history-timer | 8 | 8 | 0 | 1m 04s |
| 08-app-settings | 31 | 31 | 0 | 0m 27s |
| 09-report | 22 | 22 | 0 | 0m 17s |
| 10-google-calendar | 10 | 10 | 0 | 0m 16s |
| 11-google-reconnect | 17 | 17 | 0 | 0m 13s (0m 11s) |
| 12-daily-limit | 34 | 34 | 0 | 1m 38s |
| 13-device-tab | 27 | 27 | 0 | 0m 21s |
| 50-device-scan | 15 | 15 | 0 | 0m 24s |
| 51-device-connect | 41 | 41 | 0 | 0m 23s |
| 52-device-reset | 32 | 32 | 0 | 0m 39s |
| 53-device-reconnect | 21 | 21 | 0 | 0m 49s |
| 54-device-battery | 9 | 9 | 0 | 0m 39s |
| 55-device-face | 46 | 46 | 0 | 1m 03s (0m 06s) |
| 56-manual-mode | 28 | 28 | 0 | 1m 40s (0m 18s) |
| 57-cube-pause | 37 | 37 | 0 | 0m 37s (0m 05s) |
| 58-wrong-pin | 20 | 20 | 0 | 0m 39s |
| 59-double-tap | 17 | 17 | 0 | 0m 11s |
| 60-device-backlog | 21 | 21 | 0 | 0m 35s (0m 22s) |
| 61-lock-without-pause | 13 | 13 | 0 | 0m 15s |
| 62-forced-pause | 13 | 7 | 1 | 0m 11s (0m 17s) |
| 99-quit | 14 | 0 | 0 | - |
| **total** | **649** | **629** | **1** | **16m 14s (1m 22s)** |

A bracketed figure is time the script spent waiting for a person, already taken out of the time beside it.

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
