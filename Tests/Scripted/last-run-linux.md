# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   feature/linuxPort
    commit:   f70be11e3aae776f3dd91646b3bcc612ba69fc8f
    tree:     dirty
    database: rebuilt from the DDL
    started:  2026-09-20 13:20:38
    finished: 2026-09-20 13:24:54
    outcome:  failed
    scripts:  5 of 32 run, 1 with failures
    short:    28 ran fewer checks than they declare
    checks:   129 in total
              128 passed
              1 failed

| script | expected | passed | failed | time |
|---|---|---|---|---|
| 00-setup | 1 | 1 | 0 | 1m 26s |
| 01-launch | 9 | 9 | 0 | 0m 02s |
| 02-menu-bar | 9 | 9 | 0 | 0m 08s |
| 03-settings-window | 32 | 32 | 0 | 0m 36s |
| 04-categories | 101 | 77 | 1 | 2m 04s |
| 05-faces-timing | 28 | 0 | 0 | - |
| 06-time-entries | 12 | 0 | 0 | - |
| 07-history-timer | 8 | 0 | 0 | - |
| 08-app-settings | 44 | 0 | 0 | - |
| 09-report | 22 | 0 | 0 | - |
| 10-google-calendar | 10 | 0 | 0 | - |
| 11-google-reconnect | 17 | 0 | 0 | - |
| 12-daily-limit | 34 | 0 | 0 | - |
| 13-device-tab | 40 | 0 | 0 | - |
| 50-device-scan | 15 | 0 | 0 | - |
| 51-device-connect | 41 | 0 | 0 | - |
| 52-device-reset | 32 | 0 | 0 | - |
| 53-device-reconnect | 26 | 0 | 0 | - |
| 54-device-battery | 12 | 0 | 0 | - |
| 55-device-face | 46 | 0 | 0 | - |
| 56-manual-mode | 37 | 0 | 0 | - |
| 57-cube-pause | 39 | 0 | 0 | - |
| 58-wrong-pin | 22 | 0 | 0 | - |
| 59-double-tap | 4 | 0 | 0 | - |
| 60-device-backlog | 23 | 0 | 0 | - |
| 61-lock-without-pause | 25 | 0 | 0 | - |
| 62-forced-pause | 20 | 0 | 0 | - |
| 63-led-settings | 18 | 0 | 0 | - |
| 64-face-colours | 12 | 0 | 0 | - |
| 65-auto-pause | 19 | 0 | 0 | - |
| 66-device-rename | 22 | 0 | 0 | - |
| 99-quit | 14 | 0 | 0 | - |
| **total** | **794** | **128** | **1** | **4m 16s** |

> The working tree had uncommitted changes when this ran, so it is not evidence about the
> commit it names. CI refuses a stamp in this state.

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
