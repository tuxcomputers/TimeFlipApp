# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   bugfix/lostConnection
    commit:   26f48c12d5511af11cd65603168d1819f39d5374
    tree:     dirty
    database: rebuilt from the DDL
    started:  2026-08-23 14:46:51
    finished: 2026-08-23 15:00:31
    outcome:  failed
    scripts:  23 run, 1 with failures
    checks:   552 in total
              551 passed
              1 failed
              0 skipped

| script | expected | passed | failed |
|---|---|---|---|
| 00-setup | 1 | 1 | 0 |
| 01-launch | 9 | 9 | 0 |
| 02-menu-bar | 10 | 10 | 0 |
| 03-settings-window | 26 | 26 | 0 |
| 04-categories | 96 | 96 | 0 |
| 05-faces-timing | 17 | 17 | 0 |
| 06-time-entries | 12 | 12 | 0 |
| 07-history-timer | 8 | 8 | 0 |
| 08-app-settings | 31 | 31 | 0 |
| 09-report | 22 | 22 | 0 |
| 10-google-calendar | 10 | 10 | 0 |
| 11-google-reconnect | 17 | 17 | 0 |
| 12-daily-limit | 32 | 32 | 0 |
| 13-device-tab | 27 | 27 | 0 |
| 50-device-scan | 15 | 15 | 0 |
| 51-device-connect | 41 | 41 | 0 |
| 52-device-reset | 33 | 33 | 0 |
| 53-device-reconnect | 23 | 23 | 0 |
| 54-device-battery | 10 | 10 | 0 |
| 55-device-face | 43 | 43 | 0 |
| 56-manual-mode | 30 | 30 | 0 |
| 57-cube-pause | 38 | 38 | 0 |
| 58-wrong-pin | 20 | 0 | 1 |
| **total** | **571** | **551** | **1** |

> The working tree had uncommitted changes when this ran, so it is not evidence about the
> commit it names. CI refuses a stamp in this state.

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
