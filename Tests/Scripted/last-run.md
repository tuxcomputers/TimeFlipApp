# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   feature/colourScheme
    commit:   143edec06f008a2f5906b9d0968689873a9266da
    tree:     clean
    database: rebuilt from the DDL
    started:  2026-08-25 23:48:06
    finished: 2026-08-26 00:07:12
    outcome:  passed
    scripts:  26 of 26 run, 0 with failures
    short:    0 ran fewer checks than they declare
    checks:   633 in total
              633 passed
              0 failed

| script | expected | passed | failed | time |
|---|---|---|---|---|
| 00-setup | 1 | 1 | 0 | 0m 58s |
| 01-launch | 9 | 9 | 0 | 0m 02s |
| 02-menu-bar | 10 | 10 | 0 | 0m 05s |
| 03-settings-window | 26 | 26 | 0 | 0m 22s |
| 04-categories | 96 | 96 | 0 | 1m 47s |
| 05-faces-timing | 19 | 19 | 0 | 0m 26s |
| 06-time-entries | 12 | 12 | 0 | 0m 19s |
| 07-history-timer | 8 | 8 | 0 | 1m 04s |
| 08-app-settings | 31 | 31 | 0 | 0m 27s |
| 09-report | 22 | 22 | 0 | 0m 17s |
| 10-google-calendar | 10 | 10 | 0 | 0m 16s |
| 11-google-reconnect | 17 | 17 | 0 | 0m 26s |
| 12-daily-limit | 34 | 34 | 0 | 1m 39s |
| 13-device-tab | 27 | 27 | 0 | 0m 21s |
| 50-device-scan | 15 | 15 | 0 | 0m 23s |
| 51-device-connect | 41 | 41 | 0 | 0m 14s |
| 52-device-reset | 33 | 33 | 0 | 0m 43s |
| 53-device-reconnect | 23 | 23 | 0 | 0m 43s |
| 54-device-battery | 10 | 10 | 0 | 0m 26s |
| 55-device-face | 47 | 47 | 0 | 1m 06s |
| 56-manual-mode | 30 | 30 | 0 | 2m 06s |
| 57-cube-pause | 38 | 38 | 0 | 0m 59s |
| 58-wrong-pin | 21 | 21 | 0 | 1m 08s |
| 59-double-tap | 18 | 18 | 0 | 0m 33s |
| 60-device-backlog | 21 | 21 | 0 | 1m 15s |
| 99-quit | 14 | 14 | 0 | 1m 01s |
| **total** | **633** | **633** | **0** | **19m 06s** |

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
