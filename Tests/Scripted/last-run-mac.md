# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   feature/linuxPort
    commit:   c3b2ec25f7ce2e05ddfd1ced28028f6decc9eea0
    tree:     clean
    database: rebuilt from the DDL
    started:  2026-09-08 20:10:10
    finished: 2026-09-08 20:49:16
    outcome:  passed
    scripts:  32 of 32 run, 0 with failures
    short:    0 ran fewer checks than they declare
    checks:   812 in total
              812 passed
              0 failed

| script | expected | passed | failed | time |
|---|---|---|---|---|
| 00-setup | 1 | 1 | 0 | 1m 01s (1m 58s) |
| 01-launch | 9 | 9 | 0 | 0m 01s |
| 02-menu-bar | 9 | 9 | 0 | 0m 05s |
| 03-settings-window | 32 | 32 | 0 | 0m 24s |
| 04-categories | 101 | 101 | 0 | 1m 52s |
| 05-faces-timing | 28 | 28 | 0 | 0m 35s |
| 06-time-entries | 12 | 12 | 0 | 0m 18s |
| 07-history-timer | 8 | 8 | 0 | 1m 05s |
| 08-app-settings | 44 | 44 | 0 | 0m 33s |
| 09-report | 22 | 22 | 0 | 0m 17s |
| 10-google-calendar | 10 | 10 | 0 | 0m 16s |
| 11-google-reconnect | 17 | 17 | 0 | 0m 14s (2m 30s) |
| 12-daily-limit | 34 | 34 | 0 | 1m 38s |
| 13-device-tab | 45 | 45 | 0 | 0m 29s |
| 50-device-scan | 15 | 15 | 0 | 0m 29s |
| 51-device-connect | 41 | 41 | 0 | 0m 24s |
| 52-device-reset | 32 | 32 | 0 | 0m 45s |
| 53-device-reconnect | 26 | 26 | 0 | 0m 55s |
| 54-device-battery | 12 | 12 | 0 | 0m 50s |
| 55-device-face | 46 | 46 | 0 | 1m 13s (1m 41s) |
| 56-manual-mode | 37 | 37 | 0 | 1m 51s (1m 03s) |
| 57-cube-pause | 39 | 39 | 0 | 0m 35s (0m 25s) |
| 58-wrong-pin | 22 | 22 | 0 | 0m 43s |
| 59-double-tap | 19 | 19 | 0 | 0m 12s |
| 60-device-backlog | 23 | 23 | 0 | 0m 36s (3m 00s) |
| 61-lock-without-pause | 25 | 25 | 0 | 0m 26s |
| 62-forced-pause | 20 | 20 | 0 | 0m 30s (5m 14s) |
| 63-led-settings | 18 | 18 | 0 | 0m 18s |
| 64-face-colours | 12 | 12 | 0 | 0m 28s |
| 65-auto-pause | 18 | 18 | 0 | 1m 25s (1m 34s) |
| 66-device-rename | 21 | 21 | 0 | 0m 31s |
| 99-quit | 14 | 14 | 0 | 0m 41s |
| **total** | **812** | **812** | **0** | **21m 40s (17m 25s)** |

A bracketed figure is time the script spent waiting for a person, already taken out of the time beside it.

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
