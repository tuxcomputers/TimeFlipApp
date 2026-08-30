# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   chore/docCleanup
    commit:   2ccff70d1d865d20d90c83a86d2dc8be612e83b9
    tree:     clean
    database: rebuilt from the DDL
    started:  2026-08-30 11:29:46
    finished: 2026-08-30 11:53:38
    outcome:  passed
    scripts:  31 of 31 run, 0 with failures
    short:    0 ran fewer checks than they declare
    checks:   718 in total
              718 passed
              0 failed

| script | expected | passed | failed | time |
|---|---|---|---|---|
| 00-setup | 1 | 1 | 0 | 0m 58s (0m 05s) |
| 01-launch | 9 | 9 | 0 | 0m 02s |
| 02-menu-bar | 10 | 10 | 0 | 0m 04s |
| 03-settings-window | 26 | 26 | 0 | 0m 23s |
| 04-categories | 96 | 96 | 0 | 1m 46s |
| 05-faces-timing | 19 | 19 | 0 | 0m 26s |
| 06-time-entries | 12 | 12 | 0 | 0m 18s |
| 07-history-timer | 8 | 8 | 0 | 1m 05s |
| 08-app-settings | 31 | 31 | 0 | 0m 27s |
| 09-report | 22 | 22 | 0 | 0m 17s |
| 10-google-calendar | 10 | 10 | 0 | 0m 16s |
| 11-google-reconnect | 17 | 17 | 0 | 0m 13s (0m 11s) |
| 12-daily-limit | 34 | 34 | 0 | 1m 39s |
| 13-device-tab | 31 | 31 | 0 | 0m 22s |
| 50-device-scan | 15 | 15 | 0 | 0m 24s |
| 51-device-connect | 41 | 41 | 0 | 0m 26s |
| 52-device-reset | 32 | 32 | 0 | 0m 45s |
| 53-device-reconnect | 21 | 21 | 0 | 0m 53s |
| 54-device-battery | 9 | 9 | 0 | 0m 47s |
| 55-device-face | 46 | 46 | 0 | 1m 07s (0m 56s) |
| 56-manual-mode | 33 | 33 | 0 | 1m 45s (0m 41s) |
| 57-cube-pause | 38 | 38 | 0 | 0m 35s (0m 13s) |
| 58-wrong-pin | 20 | 20 | 0 | 0m 43s |
| 59-double-tap | 19 | 19 | 0 | 0m 11s |
| 60-device-backlog | 23 | 23 | 0 | 0m 22s (1m 05s) |
| 61-lock-without-pause | 13 | 13 | 0 | 0m 15s |
| 62-forced-pause | 20 | 20 | 0 | 0m 27s (0m 30s) |
| 63-led-settings | 18 | 18 | 0 | 0m 18s |
| 64-face-colours | 12 | 12 | 0 | 0m 28s |
| 65-auto-pause | 18 | 18 | 0 | 1m 30s (0m 17s) |
| 99-quit | 14 | 14 | 0 | 0m 40s |
| **total** | **718** | **718** | **0** | **19m 52s (3m 58s)** |

A bracketed figure is time the script spent waiting for a person, already taken out of the time beside it.

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
