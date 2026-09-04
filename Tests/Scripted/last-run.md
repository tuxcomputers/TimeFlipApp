# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   feature/debugRecord
    commit:   fffa88c50bdd4caa115129d75b407e52847fdebb
    tree:     clean
    database: rebuilt from the DDL
    started:  2026-09-04 11:03:48
    finished: 2026-09-04 11:40:39
    outcome:  passed
    scripts:  32 of 32 run, 0 with failures
    short:    0 ran fewer checks than they declare
    checks:   792 in total
              792 passed
              0 failed

| script | expected | passed | failed | time |
|---|---|---|---|---|
| 00-setup | 1 | 1 | 0 | 0m 56s (0m 03s) |
| 01-launch | 9 | 9 | 0 | 0m 01s |
| 02-menu-bar | 9 | 9 | 0 | 0m 05s |
| 03-settings-window | 26 | 26 | 0 | 0m 22s |
| 04-categories | 98 | 98 | 0 | 1m 50s |
| 05-faces-timing | 19 | 19 | 0 | 0m 26s |
| 06-time-entries | 12 | 12 | 0 | 0m 19s |
| 07-history-timer | 8 | 8 | 0 | 1m 05s |
| 08-app-settings | 44 | 44 | 0 | 0m 33s |
| 09-report | 22 | 22 | 0 | 0m 17s |
| 10-google-calendar | 10 | 10 | 0 | 0m 17s |
| 11-google-reconnect | 17 | 17 | 0 | 0m 11s (0m 47s) |
| 12-daily-limit | 34 | 34 | 0 | 1m 39s |
| 13-device-tab | 45 | 45 | 0 | 0m 28s |
| 50-device-scan | 15 | 15 | 0 | 0m 24s |
| 51-device-connect | 41 | 41 | 0 | 0m 25s |
| 52-device-reset | 32 | 32 | 0 | 0m 44s |
| 53-device-reconnect | 24 | 24 | 0 | 0m 54s |
| 54-device-battery | 12 | 12 | 0 | 0m 53s |
| 55-device-face | 46 | 46 | 0 | 1m 12s (5m 48s) |
| 56-manual-mode | 37 | 37 | 0 | 1m 57s (6m 33s) |
| 57-cube-pause | 39 | 39 | 0 | 0m 34s (0m 26s) |
| 58-wrong-pin | 22 | 22 | 0 | 0m 48s |
| 59-double-tap | 19 | 19 | 0 | 0m 12s |
| 60-device-backlog | 23 | 23 | 0 | 0m 25s (0m 58s) |
| 61-lock-without-pause | 25 | 25 | 0 | 0m 26s |
| 62-forced-pause | 20 | 20 | 0 | 0m 32s (0m 35s) |
| 63-led-settings | 18 | 18 | 0 | 0m 19s |
| 64-face-colours | 12 | 12 | 0 | 0m 33s |
| 65-auto-pause | 18 | 18 | 0 | 1m 29s (0m 08s) |
| 66-device-rename | 21 | 21 | 0 | 0m 34s |
| 99-quit | 14 | 14 | 0 | 0m 41s |
| **total** | **792** | **792** | **0** | **21m 31s (15m 18s)** |

A bracketed figure is time the script spent waiting for a person, already taken out of the time beside it.

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
