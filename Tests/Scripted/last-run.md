# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   docs/cleanup
    commit:   fc909dd02b61681db0d74810302c97ffbf4c6a8c
    tree:     clean
    database: rebuilt from the DDL
    started:  2026-09-05 12:21:31
    finished: 2026-09-05 13:13:22
    outcome:  passed
    scripts:  32 of 32 run, 0 with failures
    short:    0 ran fewer checks than they declare
    checks:   810 in total
              810 passed
              0 failed

| script | expected | passed | failed | time |
|---|---|---|---|---|
| 00-setup | 1 | 1 | 0 | 0m 58s (0m 10s) |
| 01-launch | 9 | 9 | 0 | 0m 02s |
| 02-menu-bar | 9 | 9 | 0 | 0m 04s |
| 03-settings-window | 32 | 32 | 0 | 0m 23s |
| 04-categories | 101 | 101 | 0 | 1m 52s |
| 05-faces-timing | 28 | 28 | 0 | 0m 35s |
| 06-time-entries | 12 | 12 | 0 | 0m 19s |
| 07-history-timer | 8 | 8 | 0 | 1m 04s |
| 08-app-settings | 44 | 44 | 0 | 0m 34s |
| 09-report | 22 | 22 | 0 | 0m 16s |
| 10-google-calendar | 10 | 10 | 0 | 0m 17s |
| 11-google-reconnect | 17 | 17 | 0 | 0m 14s (12m 35s) |
| 12-daily-limit | 34 | 34 | 0 | 1m 39s |
| 13-device-tab | 45 | 45 | 0 | 0m 28s |
| 50-device-scan | 15 | 15 | 0 | 0m 26s |
| 51-device-connect | 41 | 41 | 0 | 0m 27s |
| 52-device-reset | 32 | 32 | 0 | 0m 44s |
| 53-device-reconnect | 24 | 24 | 0 | 0m 53s |
| 54-device-battery | 12 | 12 | 0 | 0m 52s |
| 55-device-face | 46 | 46 | 0 | 1m 13s (3m 22s) |
| 56-manual-mode | 37 | 37 | 0 | 1m 47s (7m 10s) |
| 57-cube-pause | 39 | 39 | 0 | 0m 35s (0m 05s) |
| 58-wrong-pin | 22 | 22 | 0 | 0m 43s |
| 59-double-tap | 19 | 19 | 0 | 0m 11s |
| 60-device-backlog | 23 | 23 | 0 | 0m 19s (4m 40s) |
| 61-lock-without-pause | 25 | 25 | 0 | 0m 25s |
| 62-forced-pause | 20 | 20 | 0 | 0m 31s (2m 31s) |
| 63-led-settings | 18 | 18 | 0 | 0m 18s |
| 64-face-colours | 12 | 12 | 0 | 0m 28s |
| 65-auto-pause | 18 | 18 | 0 | 1m 24s (0m 04s) |
| 66-device-rename | 21 | 21 | 0 | 0m 31s |
| 99-quit | 14 | 14 | 0 | 0m 40s |
| **total** | **810** | **810** | **0** | **21m 12s (30m 37s)** |

A bracketed figure is time the script spent waiting for a person, already taken out of the time beside it.

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
