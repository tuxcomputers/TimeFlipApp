# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   chore/testTweak
    commit:   04afcbe4b191210e946c18c2c04fcdee990d2c34
    tree:     clean
    database: rebuilt from the DDL
    started:  2026-08-27 19:02:33
    finished: 2026-08-27 19:21:11
    outcome:  passed
    scripts:  27 of 27 run, 0 with failures
    short:    0 ran fewer checks than they declare
    checks:   636 in total
              636 passed
              0 failed

| script | expected | passed | failed | time |
|---|---|---|---|---|
| 00-setup | 1 | 1 | 0 | 0m 49s (0m 05s) |
| 01-launch | 9 | 9 | 0 | 0m 01s |
| 02-menu-bar | 10 | 10 | 0 | 0m 05s |
| 03-settings-window | 26 | 26 | 0 | 0m 23s |
| 04-categories | 96 | 96 | 0 | 1m 45s |
| 05-faces-timing | 19 | 19 | 0 | 0m 27s |
| 06-time-entries | 12 | 12 | 0 | 0m 18s |
| 07-history-timer | 8 | 8 | 0 | 1m 05s |
| 08-app-settings | 31 | 31 | 0 | 0m 27s |
| 09-report | 22 | 22 | 0 | 0m 16s |
| 10-google-calendar | 10 | 10 | 0 | 0m 16s |
| 11-google-reconnect | 17 | 17 | 0 | 0m 13s (0m 13s) |
| 12-daily-limit | 34 | 34 | 0 | 1m 38s |
| 13-device-tab | 27 | 27 | 0 | 0m 21s |
| 50-device-scan | 15 | 15 | 0 | 0m 26s |
| 51-device-connect | 41 | 41 | 0 | 0m 21s |
| 52-device-reset | 32 | 32 | 0 | 0m 40s |
| 53-device-reconnect | 21 | 21 | 0 | 0m 49s |
| 54-device-battery | 9 | 9 | 0 | 0m 40s |
| 55-device-face | 46 | 46 | 0 | 1m 09s (0m 32s) |
| 56-manual-mode | 28 | 28 | 0 | 1m 41s (0m 26s) |
| 57-cube-pause | 37 | 37 | 0 | 0m 36s (0m 04s) |
| 58-wrong-pin | 20 | 20 | 0 | 0m 40s |
| 59-double-tap | 17 | 17 | 0 | 0m 11s |
| 60-device-backlog | 21 | 21 | 0 | 0m 28s (0m 35s) |
| 61-lock-without-pause | 13 | 13 | 0 | 0m 15s |
| 99-quit | 14 | 14 | 0 | 0m 40s |
| **total** | **636** | **636** | **0** | **16m 40s (1m 55s)** |

A bracketed figure is time the script spent waiting for a person, already taken out of the time beside it.

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
