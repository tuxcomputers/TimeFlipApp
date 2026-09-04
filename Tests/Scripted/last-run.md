# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   bug/appWidth
    commit:   2b52d20f393cb21ae604c80b5a0412fc7d1e89a0
    tree:     clean
    database: rebuilt from the DDL
    started:  2026-09-04 16:58:52
    finished: 2026-09-04 17:28:28
    outcome:  passed
    scripts:  32 of 32 run, 0 with failures
    short:    0 ran fewer checks than they declare
    checks:   798 in total
              798 passed
              0 failed

| script | expected | passed | failed | time |
|---|---|---|---|---|
| 00-setup | 1 | 1 | 0 | 0m 55s (0m 10s) |
| 01-launch | 9 | 9 | 0 | 0m 02s |
| 02-menu-bar | 9 | 9 | 0 | 0m 04s |
| 03-settings-window | 32 | 32 | 0 | 0m 24s |
| 04-categories | 98 | 98 | 0 | 1m 49s |
| 05-faces-timing | 19 | 19 | 0 | 0m 27s |
| 06-time-entries | 12 | 12 | 0 | 0m 18s |
| 07-history-timer | 8 | 8 | 0 | 1m 04s |
| 08-app-settings | 44 | 44 | 0 | 0m 33s |
| 09-report | 22 | 22 | 0 | 0m 17s |
| 10-google-calendar | 10 | 10 | 0 | 0m 16s |
| 11-google-reconnect | 17 | 17 | 0 | 0m 13s (0m 17s) |
| 12-daily-limit | 34 | 34 | 0 | 1m 39s |
| 13-device-tab | 45 | 45 | 0 | 0m 28s |
| 50-device-scan | 15 | 15 | 0 | 0m 25s |
| 51-device-connect | 41 | 41 | 0 | 0m 27s |
| 52-device-reset | 32 | 32 | 0 | 0m 47s |
| 53-device-reconnect | 24 | 24 | 0 | 0m 54s |
| 54-device-battery | 12 | 12 | 0 | 0m 51s |
| 55-device-face | 46 | 46 | 0 | 1m 13s (0m 10s) |
| 56-manual-mode | 37 | 37 | 0 | 1m 47s (0m 19s) |
| 57-cube-pause | 39 | 39 | 0 | 0m 35s (0m 05s) |
| 58-wrong-pin | 22 | 22 | 0 | 0m 46s |
| 59-double-tap | 19 | 19 | 0 | 0m 11s |
| 60-device-backlog | 23 | 23 | 0 | 0m 26s (2m 37s) |
| 61-lock-without-pause | 25 | 25 | 0 | 0m 25s |
| 62-forced-pause | 20 | 20 | 0 | 0m 30s (4m 33s) |
| 63-led-settings | 18 | 18 | 0 | 0m 19s |
| 64-face-colours | 12 | 12 | 0 | 0m 28s |
| 65-auto-pause | 18 | 18 | 0 | 1m 30s (0m 07s) |
| 66-device-rename | 21 | 21 | 0 | 0m 33s |
| 99-quit | 14 | 14 | 0 | 0m 40s |
| **total** | **798** | **798** | **0** | **21m 16s (8m 18s)** |

A bracketed figure is time the script spent waiting for a person, already taken out of the time beside it.

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
