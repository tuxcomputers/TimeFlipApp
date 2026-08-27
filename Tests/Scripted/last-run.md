# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   bugfix/fixLock
    commit:   1b099d413ba1874a537b6177eaa509f560838771
    tree:     clean
    database: rebuilt from the DDL
    started:  2026-08-27 17:25:35
    finished: 2026-08-27 17:52:36
    outcome:  passed
    scripts:  27 of 27 run, 0 with failures
    short:    0 ran fewer checks than they declare
    checks:   646 in total
              646 passed
              0 failed

| script | expected | passed | failed | time |
|---|---|---|---|---|
| 00-setup | 1 | 1 | 0 | 0m 56s (0m 09s) |
| 01-launch | 9 | 9 | 0 | 0m 01s |
| 02-menu-bar | 10 | 10 | 0 | 0m 05s |
| 03-settings-window | 26 | 26 | 0 | 0m 22s |
| 04-categories | 96 | 96 | 0 | 1m 46s |
| 05-faces-timing | 19 | 19 | 0 | 0m 26s |
| 06-time-entries | 12 | 12 | 0 | 0m 18s |
| 07-history-timer | 8 | 8 | 0 | 1m 05s |
| 08-app-settings | 31 | 31 | 0 | 0m 27s |
| 09-report | 22 | 22 | 0 | 0m 17s |
| 10-google-calendar | 10 | 10 | 0 | 0m 16s |
| 11-google-reconnect | 17 | 17 | 0 | 0m 15s (6m 21s) |
| 12-daily-limit | 34 | 34 | 0 | 1m 38s |
| 13-device-tab | 27 | 27 | 0 | 0m 22s |
| 50-device-scan | 15 | 15 | 0 | 0m 23s |
| 51-device-connect | 41 | 41 | 0 | 0m 15s |
| 52-device-reset | 33 | 33 | 0 | 0m 47s |
| 53-device-reconnect | 23 | 23 | 0 | 0m 43s |
| 54-device-battery | 10 | 10 | 0 | 0m 27s |
| 55-device-face | 47 | 47 | 0 | 0m 53s (0m 22s) |
| 56-manual-mode | 30 | 30 | 0 | 1m 40s (0m 18s) |
| 57-cube-pause | 38 | 38 | 0 | 0m 53s (1m 33s) |
| 58-wrong-pin | 21 | 21 | 0 | 1m 09s |
| 59-double-tap | 18 | 18 | 0 | 0m 35s |
| 60-device-backlog | 21 | 21 | 0 | 0m 33s (0m 25s) |
| 61-lock-without-pause | 13 | 13 | 0 | 0m 16s |
| 99-quit | 14 | 14 | 0 | 1m 04s |
| **total** | **646** | **646** | **0** | **17m 52s (9m 08s)** |

A bracketed figure is time the script spent waiting for a person, already taken out of the time beside it.

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
