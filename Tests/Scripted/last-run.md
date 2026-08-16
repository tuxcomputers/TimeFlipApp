# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   feature/codeOverhaul
    commit:   1e97bc5d18ceddad5c8136997b7cbbfe7ffa2ee1
    tree:     clean
    database: rebuilt from the DDL
    started:  2026-08-16 11:57:14
    finished: 2026-08-16 12:01:23
    outcome:  failed
    scripts:  11 run, 1 with failures
    checks:   198 passed, 1 failed, 0 skipped

| script | passed | failed | skipped |
|---|---|---|---|
| 00-setup | 6 | 0 | 0 |
| 01-launch | 9 | 0 | 0 |
| 02-menu-bar | 10 | 0 | 0 |
| 03-settings-window | 15 | 0 | 0 |
| 04-categories | 84 | 0 | 0 |
| 05-faces-timing | 14 | 0 | 0 |
| 06-time-entries | 12 | 0 | 0 |
| 07-history-timer | 8 | 0 | 0 |
| 08-app-settings | 15 | 0 | 0 |
| 09-report | 22 | 0 | 0 |
| 10-google-calendar | 3 | 1 | 0 |

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
