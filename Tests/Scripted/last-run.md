# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   feature/autoPause
    commit:   7a249d5f577ee5fb3b058a76608ac57bc9bf160e
    tree:     clean
    database: rebuilt from the DDL
    started:  2026-08-27 22:30:58
    finished: 2026-08-27 22:52:52
    outcome:  failed
    scripts:  25 of 28 run, 1 with failures
    short:    4 ran fewer checks than they declare
    checks:   595 in total
              594 passed
              1 failed

| script | expected | passed | failed | time |
|---|---|---|---|---|
| 00-setup | 1 | 1 | 0 | 0m 54s (0m 19s) |
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
| 11-google-reconnect | 17 | 17 | 0 | 0m 12s (3m 05s) |
| 12-daily-limit | 34 | 34 | 0 | 1m 39s |
| 13-device-tab | 27 | 27 | 0 | 0m 21s |
| 50-device-scan | 15 | 15 | 0 | 0m 23s |
| 51-device-connect | 41 | 41 | 0 | 0m 27s |
| 52-device-reset | 32 | 32 | 0 | 0m 43s |
| 53-device-reconnect | 21 | 21 | 0 | 0m 53s |
| 54-device-battery | 9 | 9 | 0 | 0m 49s |
| 55-device-face | 45 | 45 | 0 | 1m 14s (1m 00s) |
| 56-manual-mode | 28 | 28 | 0 | 1m 44s (0m 59s) |
| 57-cube-pause | 37 | 37 | 0 | 0m 34s (0m 07s) |
| 58-wrong-pin | 20 | 20 | 0 | 0m 40s |
| 59-double-tap | 17 | 17 | 0 | 0m 11s |
| 60-device-backlog | 21 | 7 | 1 | 0m 17s (0m 09s) |
| 61-lock-without-pause | 13 | 0 | 0 | - |
| 62-forced-pause | 13 | 0 | 0 | - |
| 99-quit | 14 | 0 | 0 | - |
| **total** | **648** | **594** | **1** | **16m 05s (5m 39s)** |

A bracketed figure is time the script spent waiting for a person, already taken out of the time beside it.

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
