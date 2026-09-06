# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   feature/linuxPort
    commit:   62d7e6d95e0535a36df9ee7a5f74f8969a1dd11e
    tree:     clean
    database: rebuilt from the DDL
    started:  2026-09-07 08:22:12
    finished: 2026-09-07 08:44:00
    outcome:  failed
    scripts:  23 of 32 run, 1 with failures
    short:    10 ran fewer checks than they declare
    checks:   625 in total
              624 passed
              1 failed

| script | expected | passed | failed | time |
|---|---|---|---|---|
| 00-setup | 1 | 1 | 0 | 1m 00s (0m 15s) |
| 01-launch | 9 | 9 | 0 | 0m 01s |
| 02-menu-bar | 9 | 9 | 0 | 0m 05s |
| 03-settings-window | 32 | 32 | 0 | 0m 24s |
| 04-categories | 101 | 101 | 0 | 1m 52s |
| 05-faces-timing | 28 | 28 | 0 | 0m 36s |
| 06-time-entries | 12 | 12 | 0 | 0m 19s |
| 07-history-timer | 8 | 8 | 0 | 1m 05s |
| 08-app-settings | 44 | 44 | 0 | 0m 33s |
| 09-report | 22 | 22 | 0 | 0m 17s |
| 10-google-calendar | 10 | 10 | 0 | 0m 16s |
| 11-google-reconnect | 17 | 17 | 0 | 0m 15s (3m 49s) |
| 12-daily-limit | 34 | 34 | 0 | 1m 39s |
| 13-device-tab | 45 | 45 | 0 | 0m 29s |
| 50-device-scan | 15 | 15 | 0 | 0m 23s |
| 51-device-connect | 41 | 41 | 0 | 0m 26s |
| 52-device-reset | 32 | 32 | 0 | 0m 45s |
| 53-device-reconnect | 26 | 26 | 0 | 1m 02s |
| 54-device-battery | 12 | 12 | 0 | 0m 54s |
| 55-device-face | 46 | 46 | 0 | 1m 15s (0m 07s) |
| 56-manual-mode | 37 | 37 | 0 | 1m 49s (0m 18s) |
| 57-cube-pause | 39 | 39 | 0 | 0m 35s (0m 05s) |
| 58-wrong-pin | 22 | 4 | 1 | 1m 14s |
| 59-double-tap | 19 | 0 | 0 | - |
| 60-device-backlog | 23 | 0 | 0 | - |
| 61-lock-without-pause | 25 | 0 | 0 | - |
| 62-forced-pause | 20 | 0 | 0 | - |
| 63-led-settings | 18 | 0 | 0 | - |
| 64-face-colours | 12 | 0 | 0 | - |
| 65-auto-pause | 18 | 0 | 0 | - |
| 66-device-rename | 21 | 0 | 0 | - |
| 99-quit | 14 | 0 | 0 | - |
| **total** | **812** | **624** | **1** | **17m 14s (4m 34s)** |

A bracketed figure is time the script spent waiting for a person, already taken out of the time beside it.

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
