# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   feature/linuxPort
    commit:   b9ef16a13b3b859c7a48b783d380e43a43784f0c
    tree:     clean
    database: rebuilt from the DDL
    started:  2026-09-18 18:50:08
    finished: 2026-09-18 19:30:04
    outcome:  failed
    scripts:  28 of 32 run, 1 with failures
    short:    5 ran fewer checks than they declare
    checks:   715 in total
              714 passed
              1 failed

| script | expected | passed | failed | time |
|---|---|---|---|---|
| 00-setup | 1 | 1 | 0 | 0m 55s (0m 49s) |
| 01-launch | 9 | 9 | 0 | 0m 02s |
| 02-menu-bar | 9 | 9 | 0 | 0m 04s |
| 03-settings-window | 32 | 32 | 0 | 0m 24s |
| 04-categories | 101 | 101 | 0 | 1m 52s |
| 05-faces-timing | 28 | 28 | 0 | 0m 35s |
| 06-time-entries | 12 | 12 | 0 | 0m 18s |
| 07-history-timer | 8 | 8 | 0 | 1m 05s |
| 08-app-settings | 44 | 44 | 0 | 0m 34s |
| 09-report | 22 | 22 | 0 | 0m 16s |
| 10-google-calendar | 10 | 10 | 0 | 0m 17s |
| 11-google-reconnect | 17 | 17 | 0 | 0m 15s (1m 03s) |
| 12-daily-limit | 34 | 34 | 0 | 1m 39s |
| 13-device-tab | 40 | 40 | 0 | 0m 26s |
| 50-device-scan | 15 | 15 | 0 | 0m 30s |
| 51-device-connect | 41 | 41 | 0 | 0m 26s |
| 52-device-reset | 32 | 32 | 0 | 0m 45s |
| 53-device-reconnect | 26 | 26 | 0 | 0m 57s |
| 54-device-battery | 12 | 12 | 0 | 0m 52s |
| 55-device-face | 46 | 46 | 0 | 1m 10s (3m 17s) |
| 56-manual-mode | 37 | 37 | 0 | 1m 54s (5m 16s) |
| 57-cube-pause | 39 | 39 | 0 | 0m 33s (3m 48s) |
| 58-wrong-pin | 22 | 22 | 0 | 0m 45s |
| 59-double-tap | 4 | 4 | 0 | 0m 13s |
| 60-device-backlog | 23 | 23 | 0 | 0m 22s (1m 05s) |
| 61-lock-without-pause | 25 | 25 | 0 | 0m 26s |
| 62-forced-pause | 20 | 20 | 0 | 0m 33s (5m 46s) |
| 63-led-settings | 18 | 5 | 1 | 0m 43s |
| 64-face-colours | 12 | 0 | 0 | - |
| 65-auto-pause | 19 | 0 | 0 | - |
| 66-device-rename | 22 | 0 | 0 | - |
| 99-quit | 14 | 0 | 0 | - |
| **total** | **794** | **714** | **1** | **18m 51s (21m 04s)** |

A bracketed figure is time the script spent waiting for a person, already taken out of the time beside it.

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
