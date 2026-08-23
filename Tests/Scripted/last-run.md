# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   chore/singleMode
    commit:   a02a18af1d97852f7f22b558ac50b873d6112168
    tree:     dirty
    database: rebuilt from the DDL
    started:  2026-08-23 20:29:55
    finished: 2026-08-23 20:33:33
    outcome:  failed
    scripts:  2 of 24 run, 1 with failures
    short:    23 ran fewer checks than they declare
    checks:   3 in total
              2 passed
              1 failed

| script | expected | passed | failed |
|---|---|---|---|
| 00-setup | 1 | 1 | 0 |
| 01-launch | 9 | 1 | 1 |
| 02-menu-bar | 10 | 0 | 0 |
| 03-settings-window | 26 | 0 | 0 |
| 04-categories | 96 | 0 | 0 |
| 05-faces-timing | 17 | 0 | 0 |
| 06-time-entries | 12 | 0 | 0 |
| 07-history-timer | 8 | 0 | 0 |
| 08-app-settings | 31 | 0 | 0 |
| 09-report | 22 | 0 | 0 |
| 10-google-calendar | 10 | 0 | 0 |
| 11-google-reconnect | 17 | 0 | 0 |
| 12-daily-limit | 32 | 0 | 0 |
| 13-device-tab | 27 | 0 | 0 |
| 50-device-scan | 15 | 0 | 0 |
| 51-device-connect | 41 | 0 | 0 |
| 52-device-reset | 33 | 0 | 0 |
| 53-device-reconnect | 23 | 0 | 0 |
| 54-device-battery | 10 | 0 | 0 |
| 55-device-face | 43 | 0 | 0 |
| 56-manual-mode | 29 | 0 | 0 |
| 57-cube-pause | 38 | 0 | 0 |
| 58-wrong-pin | 21 | 0 | 0 |
| 99-quit | 13 | 0 | 0 |
| **total** | **584** | **2** | **1** |

> The working tree had uncommitted changes when this ran, so it is not evidence about the
> commit it names. CI refuses a stamp in this state.

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
