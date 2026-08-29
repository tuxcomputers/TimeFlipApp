# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   feature/autoState
    commit:   7084da7c4a093e3812081287f79d01e7f855e3e7
    tree:     dirty
    database: rebuilt from the DDL
    started:  2026-08-29 21:05:34
    finished: 2026-08-29 21:08:23
    outcome:  failed
    scripts:  1 of 31 run, 1 with failures
    short:    31 ran fewer checks than they declare
    checks:   1 in total
              0 passed
              1 failed

| script | expected | passed | failed | time |
|---|---|---|---|---|
| 00-setup | 1 | 0 | 1 | 1m 17s (1m 32s) |
| 01-launch | 9 | 0 | 0 | - |
| 02-menu-bar | 10 | 0 | 0 | - |
| 03-settings-window | 26 | 0 | 0 | - |
| 04-categories | 96 | 0 | 0 | - |
| 05-faces-timing | 19 | 0 | 0 | - |
| 06-time-entries | 12 | 0 | 0 | - |
| 07-history-timer | 8 | 0 | 0 | - |
| 08-app-settings | 31 | 0 | 0 | - |
| 09-report | 22 | 0 | 0 | - |
| 10-google-calendar | 10 | 0 | 0 | - |
| 11-google-reconnect | 17 | 0 | 0 | - |
| 12-daily-limit | 34 | 0 | 0 | - |
| 13-device-tab | 31 | 0 | 0 | - |
| 50-device-scan | 15 | 0 | 0 | - |
| 51-device-connect | 41 | 0 | 0 | - |
| 52-device-reset | 32 | 0 | 0 | - |
| 53-device-reconnect | 21 | 0 | 0 | - |
| 54-device-battery | 9 | 0 | 0 | - |
| 55-device-face | 46 | 0 | 0 | - |
| 56-manual-mode | 33 | 0 | 0 | - |
| 57-cube-pause | 38 | 0 | 0 | - |
| 58-wrong-pin | 20 | 0 | 0 | - |
| 59-double-tap | 19 | 0 | 0 | - |
| 60-device-backlog | 23 | 0 | 0 | - |
| 61-lock-without-pause | 13 | 0 | 0 | - |
| 62-forced-pause | 20 | 0 | 0 | - |
| 63-led-settings | 18 | 0 | 0 | - |
| 64-face-colours | 12 | 0 | 0 | - |
| 65-auto-pause | 18 | 0 | 0 | - |
| 99-quit | 14 | 0 | 0 | - |
| **total** | **718** | **0** | **1** | **1m 17s (1m 32s)** |

A bracketed figure is time the script spent waiting for a person, already taken out of the time beside it.

> The working tree had uncommitted changes when this ran, so it is not evidence about the
> commit it names. CI refuses a stamp in this state.

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
