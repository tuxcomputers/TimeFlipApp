# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   feature/debugRecord
    commit:   497029cfed2f6b0c59a7644db76e39b3b80de2b9
    tree:     clean
    database: rebuilt from the DDL
    started:  2026-09-04 10:13:20
    finished: 2026-09-04 10:31:10
    outcome:  failed
    scripts:  23 of 32 run, 1 with failures
    short:    10 ran fewer checks than they declare
    checks:   621 in total
              620 passed
              1 failed

| script | expected | passed | failed | time |
|---|---|---|---|---|
| 00-setup | 1 | 1 | 0 | 0m 52s (0m 04s) |
| 01-launch | 9 | 9 | 0 | 0m 02s |
| 02-menu-bar | 9 | 9 | 0 | 0m 05s |
| 03-settings-window | 26 | 26 | 0 | 0m 22s |
| 04-categories | 98 | 98 | 0 | 1m 50s |
| 05-faces-timing | 19 | 19 | 0 | 0m 27s |
| 06-time-entries | 12 | 12 | 0 | 0m 18s |
| 07-history-timer | 8 | 8 | 0 | 1m 05s |
| 08-app-settings | 44 | 44 | 0 | 0m 34s |
| 09-report | 22 | 22 | 0 | 0m 17s |
| 10-google-calendar | 10 | 10 | 0 | 0m 16s |
| 11-google-reconnect | 17 | 17 | 0 | 0m 13s (0m 15s) |
| 12-daily-limit | 34 | 34 | 0 | 1m 38s |
| 13-device-tab | 45 | 45 | 0 | 0m 29s |
| 50-device-scan | 15 | 15 | 0 | 0m 27s |
| 51-device-connect | 41 | 41 | 0 | 0m 26s |
| 52-device-reset | 32 | 32 | 0 | 0m 46s |
| 53-device-reconnect | 24 | 24 | 0 | 0m 57s |
| 54-device-battery | 12 | 12 | 0 | 0m 49s |
| 55-device-face | 46 | 46 | 0 | 1m 17s (0m 59s) |
| 56-manual-mode | 37 | 37 | 0 | 1m 52s (0m 13s) |
| 57-cube-pause | 39 | 39 | 0 | 0m 35s (0m 05s) |
| 58-wrong-pin | 22 | 20 | 1 | 0m 36s |
| 59-double-tap | 19 | 0 | 0 | - |
| 60-device-backlog | 23 | 0 | 0 | - |
| 61-lock-without-pause | 25 | 0 | 0 | - |
| 62-forced-pause | 20 | 0 | 0 | - |
| 63-led-settings | 18 | 0 | 0 | - |
| 64-face-colours | 12 | 0 | 0 | - |
| 65-auto-pause | 18 | 0 | 0 | - |
| 66-device-rename | 21 | 0 | 0 | - |
| 99-quit | 14 | 0 | 0 | - |
| **total** | **792** | **620** | **1** | **16m 13s (1m 36s)** |

A bracketed figure is time the script spent waiting for a person, already taken out of the time beside it.

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
