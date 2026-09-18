# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   feature/linuxPort
    commit:   275fbd85e73ea696b44b622e62ef2c600a940c91
    tree:     clean
    database: rebuilt from the DDL
    started:  2026-09-18 19:42:51
    finished: 2026-09-18 20:32:45
    outcome:  passed
    scripts:  32 of 32 run, 0 with failures
    short:    0 ran fewer checks than they declare
    checks:   794 in total
              794 passed
              0 failed

| script | expected | passed | failed | time |
|---|---|---|---|---|
| 00-setup | 1 | 1 | 0 | 0m 55s (4m 25s) |
| 01-launch | 9 | 9 | 0 | 0m 02s |
| 02-menu-bar | 9 | 9 | 0 | 0m 04s |
| 03-settings-window | 32 | 32 | 0 | 0m 24s |
| 04-categories | 101 | 101 | 0 | 1m 53s |
| 05-faces-timing | 28 | 28 | 0 | 0m 36s |
| 06-time-entries | 12 | 12 | 0 | 0m 18s |
| 07-history-timer | 8 | 8 | 0 | 1m 05s |
| 08-app-settings | 44 | 44 | 0 | 0m 33s |
| 09-report | 22 | 22 | 0 | 0m 17s |
| 10-google-calendar | 10 | 10 | 0 | 0m 17s |
| 11-google-reconnect | 17 | 17 | 0 | 0m 14s (0m 14s) |
| 12-daily-limit | 34 | 34 | 0 | 1m 40s |
| 13-device-tab | 40 | 40 | 0 | 0m 26s |
| 50-device-scan | 15 | 15 | 0 | 0m 30s |
| 51-device-connect | 41 | 41 | 0 | 0m 25s |
| 52-device-reset | 32 | 32 | 0 | 0m 46s |
| 53-device-reconnect | 26 | 26 | 0 | 0m 53s |
| 54-device-battery | 12 | 12 | 0 | 0m 49s |
| 55-device-face | 46 | 46 | 0 | 1m 17s (8m 11s) |
| 56-manual-mode | 37 | 37 | 0 | 1m 54s (2m 59s) |
| 57-cube-pause | 39 | 39 | 0 | 0m 34s (0m 44s) |
| 58-wrong-pin | 22 | 22 | 0 | 0m 44s |
| 59-double-tap | 4 | 4 | 0 | 0m 13s |
| 60-device-backlog | 23 | 23 | 0 | 0m 38s (6m 37s) |
| 61-lock-without-pause | 25 | 25 | 0 | 0m 25s |
| 62-forced-pause | 20 | 20 | 0 | 0m 30s (3m 07s) |
| 63-led-settings | 18 | 18 | 0 | 0m 19s |
| 64-face-colours | 12 | 12 | 0 | 0m 30s |
| 65-auto-pause | 19 | 19 | 0 | 1m 32s (1m 38s) |
| 66-device-rename | 22 | 22 | 0 | 0m 34s |
| 99-quit | 14 | 14 | 0 | 0m 40s |
| **total** | **794** | **794** | **0** | **21m 57s (27m 55s)** |

A bracketed figure is time the script spent waiting for a person, already taken out of the time beside it.

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
