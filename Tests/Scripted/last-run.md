# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   bug/categoryNameWidth
    commit:   02525ff328043d844ff3ed1d61e910d527534368
    tree:     clean
    database: rebuilt from the DDL
    started:  2026-09-04 18:38:47
    finished: 2026-09-04 19:21:53
    outcome:  passed
    scripts:  32 of 32 run, 0 with failures
    short:    0 ran fewer checks than they declare
    checks:   810 in total
              810 passed
              0 failed

| script | expected | passed | failed | time |
|---|---|---|---|---|
| 00-setup | 1 | 1 | 0 | 0m 58s (1m 48s) |
| 01-launch | 9 | 9 | 0 | 0m 02s |
| 02-menu-bar | 9 | 9 | 0 | 0m 04s |
| 03-settings-window | 32 | 32 | 0 | 0m 25s |
| 04-categories | 101 | 101 | 0 | 1m 53s |
| 05-faces-timing | 28 | 28 | 0 | 0m 35s |
| 06-time-entries | 12 | 12 | 0 | 0m 19s |
| 07-history-timer | 8 | 8 | 0 | 1m 05s |
| 08-app-settings | 44 | 44 | 0 | 0m 33s |
| 09-report | 22 | 22 | 0 | 0m 17s |
| 10-google-calendar | 10 | 10 | 0 | 0m 16s |
| 11-google-reconnect | 17 | 17 | 0 | 0m 14s (1m 30s) |
| 12-daily-limit | 34 | 34 | 0 | 1m 39s |
| 13-device-tab | 45 | 45 | 0 | 0m 29s |
| 50-device-scan | 15 | 15 | 0 | 0m 23s |
| 51-device-connect | 41 | 41 | 0 | 0m 28s |
| 52-device-reset | 32 | 32 | 0 | 0m 43s |
| 53-device-reconnect | 24 | 24 | 0 | 0m 56s |
| 54-device-battery | 12 | 12 | 0 | 0m 53s |
| 55-device-face | 46 | 46 | 0 | 1m 07s (2m 56s) |
| 56-manual-mode | 37 | 37 | 0 | 1m 50s (2m 55s) |
| 57-cube-pause | 39 | 39 | 0 | 0m 33s (1m 27s) |
| 58-wrong-pin | 22 | 22 | 0 | 0m 44s |
| 59-double-tap | 19 | 19 | 0 | 0m 11s |
| 60-device-backlog | 23 | 23 | 0 | 0m 28s (7m 29s) |
| 61-lock-without-pause | 25 | 25 | 0 | 0m 26s |
| 62-forced-pause | 20 | 20 | 0 | 0m 29s (2m 43s) |
| 63-led-settings | 18 | 18 | 0 | 0m 19s |
| 64-face-colours | 12 | 12 | 0 | 0m 27s |
| 65-auto-pause | 18 | 18 | 0 | 1m 24s (0m 54s) |
| 66-device-rename | 21 | 21 | 0 | 0m 33s |
| 99-quit | 14 | 14 | 0 | 0m 40s |
| **total** | **810** | **810** | **0** | **21m 23s (21m 42s)** |

A bracketed figure is time the script spent waiting for a person, already taken out of the time beside it.

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
