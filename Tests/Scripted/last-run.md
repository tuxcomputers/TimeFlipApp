# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   chore/movePauseLock
    commit:   423918f3ec428ced0ba30eee34f7feae63cadabe
    tree:     clean
    database: rebuilt from the DDL
    started:  2026-09-03 20:10:23
    finished: 2026-09-03 20:37:27
    outcome:  passed
    scripts:  32 of 32 run, 0 with failures
    short:    0 ran fewer checks than they declare
    checks:   776 in total
              776 passed
              0 failed

| script | expected | passed | failed | time |
|---|---|---|---|---|
| 00-setup | 1 | 1 | 0 | 0m 55s (1m 23s) |
| 01-launch | 9 | 9 | 0 | 0m 01s |
| 02-menu-bar | 10 | 10 | 0 | 0m 05s |
| 03-settings-window | 26 | 26 | 0 | 0m 24s |
| 04-categories | 98 | 98 | 0 | 1m 52s |
| 05-faces-timing | 19 | 19 | 0 | 0m 26s |
| 06-time-entries | 12 | 12 | 0 | 0m 19s |
| 07-history-timer | 8 | 8 | 0 | 1m 05s |
| 08-app-settings | 29 | 29 | 0 | 0m 22s |
| 09-report | 22 | 22 | 0 | 0m 17s |
| 10-google-calendar | 10 | 10 | 0 | 0m 17s |
| 11-google-reconnect | 17 | 17 | 0 | 0m 12s (0m 23s) |
| 12-daily-limit | 34 | 34 | 0 | 1m 39s |
| 13-device-tab | 45 | 45 | 0 | 0m 29s |
| 50-device-scan | 15 | 15 | 0 | 0m 25s |
| 51-device-connect | 41 | 41 | 0 | 0m 27s |
| 52-device-reset | 32 | 32 | 0 | 0m 41s |
| 53-device-reconnect | 24 | 24 | 0 | 0m 55s |
| 54-device-battery | 12 | 12 | 0 | 0m 51s |
| 55-device-face | 46 | 46 | 0 | 1m 06s (0m 14s) |
| 56-manual-mode | 37 | 37 | 0 | 1m 51s (0m 21s) |
| 57-cube-pause | 39 | 39 | 0 | 0m 34s (0m 08s) |
| 58-wrong-pin | 20 | 20 | 0 | 0m 43s |
| 59-double-tap | 19 | 19 | 0 | 0m 12s |
| 60-device-backlog | 23 | 23 | 0 | 0m 31s (0m 25s) |
| 61-lock-without-pause | 25 | 25 | 0 | 0m 26s |
| 62-forced-pause | 20 | 20 | 0 | 0m 32s (0m 25s) |
| 63-led-settings | 18 | 18 | 0 | 0m 18s |
| 64-face-colours | 12 | 12 | 0 | 0m 30s |
| 65-auto-pause | 18 | 18 | 0 | 1m 33s (2m 33s) |
| 66-device-rename | 21 | 21 | 0 | 0m 32s |
| 99-quit | 14 | 14 | 0 | 0m 41s |
| **total** | **776** | **776** | **0** | **21m 11s (5m 52s)** |

A bracketed figure is time the script spent waiting for a person, already taken out of the time beside it.

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
