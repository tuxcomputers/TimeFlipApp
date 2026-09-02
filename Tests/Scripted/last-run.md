# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   bugfix/missingDevice
    commit:   487b5b1f3aac829da8902df7f6018d75e4d4d6d0
    tree:     dirty
    database: rebuilt from the DDL
    started:  2026-09-02 20:19:44
    finished: 2026-09-02 21:10:21
    outcome:  passed
    scripts:  32 of 32 run, 0 with failures
    short:    0 ran fewer checks than they declare
    checks:   749 in total
              749 passed
              0 failed

| script | expected | passed | failed | time |
|---|---|---|---|---|
| 00-setup | 1 | 1 | 0 | 0m 52s (0m 03s) |
| 01-launch | 9 | 9 | 0 | 0m 02s |
| 02-menu-bar | 10 | 10 | 0 | 0m 05s |
| 03-settings-window | 26 | 26 | 0 | 0m 22s |
| 04-categories | 98 | 98 | 0 | 1m 50s |
| 05-faces-timing | 19 | 19 | 0 | 0m 26s |
| 06-time-entries | 12 | 12 | 0 | 0m 19s |
| 07-history-timer | 8 | 8 | 0 | 1m 05s |
| 08-app-settings | 31 | 31 | 0 | 0m 27s |
| 09-report | 22 | 22 | 0 | 0m 17s |
| 10-google-calendar | 10 | 10 | 0 | 0m 16s |
| 11-google-reconnect | 17 | 17 | 0 | 0m 14s (2m 51s) |
| 12-daily-limit | 34 | 34 | 0 | 1m 39s |
| 13-device-tab | 34 | 34 | 0 | 0m 23s |
| 50-device-scan | 15 | 15 | 0 | 0m 23s |
| 51-device-connect | 41 | 41 | 0 | 0m 27s |
| 52-device-reset | 32 | 32 | 0 | 0m 45s |
| 53-device-reconnect | 24 | 24 | 0 | 0m 53s |
| 54-device-battery | 9 | 9 | 0 | 0m 51s |
| 55-device-face | 46 | 46 | 0 | 1m 12s (2m 04s) |
| 56-manual-mode | 35 | 35 | 0 | 1m 48s (5m 36s) |
| 57-cube-pause | 38 | 38 | 0 | 0m 37s (5m 24s) |
| 58-wrong-pin | 20 | 20 | 0 | 0m 44s |
| 59-double-tap | 19 | 19 | 0 | 0m 11s |
| 60-device-backlog | 23 | 23 | 0 | 0m 38s (1m 57s) |
| 61-lock-without-pause | 13 | 13 | 0 | 0m 16s |
| 62-forced-pause | 20 | 20 | 0 | 0m 58s (9m 35s) |
| 63-led-settings | 18 | 18 | 0 | 0m 18s |
| 64-face-colours | 12 | 12 | 0 | 0m 28s |
| 65-auto-pause | 18 | 18 | 0 | 1m 29s (1m 42s) |
| 66-device-rename | 21 | 21 | 0 | 0m 32s |
| 99-quit | 14 | 14 | 0 | 0m 38s |
| **total** | **749** | **749** | **0** | **21m 25s (29m 12s)** |

A bracketed figure is time the script spent waiting for a person, already taken out of the time beside it.

> The working tree had uncommitted changes when this ran, so it is not evidence about the
> commit it names. CI refuses a stamp in this state.

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
