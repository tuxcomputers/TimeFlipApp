# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   chore/testTweak
    commit:   f1893a6fb39665337a76008d3205c2eed8173adb
    tree:     dirty
    database: rebuilt from the DDL
    started:  2026-08-27 18:26:44
    finished: 2026-08-27 18:36:12
    outcome:  failed
    scripts:  17 of 27 run, 1 with failures
    short:    11 ran fewer checks than they declare
    checks:   408 in total
              407 passed
              1 failed

| script | expected | passed | failed | time |
|---|---|---|---|---|
| 00-setup | 1 | 1 | 0 | 0m 52s (0m 04s) |
| 01-launch | 9 | 9 | 0 | 0m 02s |
| 02-menu-bar | 10 | 10 | 0 | 0m 05s |
| 03-settings-window | 26 | 26 | 0 | 0m 22s |
| 04-categories | 96 | 96 | 0 | 1m 46s |
| 05-faces-timing | 19 | 19 | 0 | 0m 26s |
| 06-time-entries | 12 | 12 | 0 | 0m 19s |
| 07-history-timer | 8 | 8 | 0 | 1m 04s |
| 08-app-settings | 31 | 31 | 0 | 0m 27s |
| 09-report | 22 | 22 | 0 | 0m 17s |
| 10-google-calendar | 10 | 10 | 0 | 0m 16s |
| 11-google-reconnect | 17 | 17 | 0 | 0m 14s (0m 14s) |
| 12-daily-limit | 34 | 34 | 0 | 1m 38s |
| 13-device-tab | 27 | 27 | 0 | 0m 21s |
| 50-device-scan | 15 | 15 | 0 | 0m 24s |
| 51-device-connect | 41 | 41 | 0 | 0m 15s |
| 52-device-reset | 32 | 29 | 1 | 0m 22s |
| 53-device-reconnect | 21 | 0 | 0 | - |
| 54-device-battery | 9 | 0 | 0 | - |
| 55-device-face | 46 | 0 | 0 | - |
| 56-manual-mode | 28 | 0 | 0 | - |
| 57-cube-pause | 37 | 0 | 0 | - |
| 58-wrong-pin | 20 | 0 | 0 | - |
| 59-double-tap | 17 | 0 | 0 | - |
| 60-device-backlog | 21 | 0 | 0 | - |
| 61-lock-without-pause | 13 | 0 | 0 | - |
| 99-quit | 14 | 0 | 0 | - |
| **total** | **636** | **407** | **1** | **9m 10s (0m 18s)** |

A bracketed figure is time the script spent waiting for a person, already taken out of the time beside it.

> The working tree had uncommitted changes when this ran, so it is not evidence about the
> commit it names. CI refuses a stamp in this state.

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
