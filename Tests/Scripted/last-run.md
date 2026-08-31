# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   feature/gapClosure
    commit:   61488eb47547e9c7f0cfff5b0537dc9f50e85ed4
    tree:     dirty
    database: rebuilt from the DDL
    started:  2026-08-31 18:40:25
    finished: 2026-08-31 19:20:05
    outcome:  passed
    scripts:  32 of 32 run, 0 with failures
    short:    0 ran fewer checks than they declare
    checks:   748 in total
              748 passed
              0 failed

| script | expected | passed | failed | time |
|---|---|---|---|---|
| 00-setup | 1 | 1 | 0 | 0m 54s (0m 50s) |
| 01-launch | 9 | 9 | 0 | 0m 02s |
| 02-menu-bar | 10 | 10 | 0 | 0m 04s |
| 03-settings-window | 26 | 26 | 0 | 0m 23s |
| 04-categories | 98 | 98 | 0 | 1m 49s |
| 05-faces-timing | 19 | 19 | 0 | 0m 26s |
| 06-time-entries | 12 | 12 | 0 | 0m 18s |
| 07-history-timer | 8 | 8 | 0 | 1m 05s |
| 08-app-settings | 31 | 31 | 0 | 0m 27s |
| 09-report | 22 | 22 | 0 | 0m 16s |
| 10-google-calendar | 10 | 10 | 0 | 0m 16s |
| 11-google-reconnect | 17 | 17 | 0 | 0m 14s (0m 24s) |
| 12-daily-limit | 34 | 34 | 0 | 1m 38s |
| 13-device-tab | 34 | 34 | 0 | 0m 24s |
| 50-device-scan | 15 | 15 | 0 | 0m 27s |
| 51-device-connect | 41 | 41 | 0 | 0m 25s |
| 52-device-reset | 32 | 32 | 0 | 0m 42s |
| 53-device-reconnect | 24 | 24 | 0 | 0m 56s |
| 54-device-battery | 9 | 9 | 0 | 0m 46s |
| 55-device-face | 46 | 46 | 0 | 1m 15s (0m 19s) |
| 56-manual-mode | 33 | 33 | 0 | 1m 47s (5m 48s) |
| 57-cube-pause | 38 | 38 | 0 | 0m 35s (1m 06s) |
| 58-wrong-pin | 21 | 21 | 0 | 0m 44s |
| 59-double-tap | 19 | 19 | 0 | 0m 12s |
| 60-device-backlog | 23 | 23 | 0 | 0m 35s (1m 40s) |
| 61-lock-without-pause | 13 | 13 | 0 | 0m 15s |
| 62-forced-pause | 20 | 20 | 0 | 0m 21s (8m 06s) |
| 63-led-settings | 18 | 18 | 0 | 0m 18s |
| 64-face-colours | 12 | 12 | 0 | 0m 30s |
| 65-auto-pause | 18 | 18 | 0 | 1m 35s (0m 32s) |
| 66-device-rename | 21 | 21 | 0 | 0m 33s |
| 99-quit | 14 | 14 | 0 | 0m 41s |
| **total** | **748** | **748** | **0** | **20m 53s (18m 45s)** |

A bracketed figure is time the script spent waiting for a person, already taken out of the time beside it.

> The working tree had uncommitted changes when this ran, so it is not evidence about the
> commit it names. CI refuses a stamp in this state.

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
