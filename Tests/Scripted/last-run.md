# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   feature/codeOverhaul
    commit:   8b2b3b099e5cd97e134e7de8437cf38de811cf9f
    tree:     dirty
    database: rebuilt from the DDL
    started:  2026-08-16 10:52:18
    finished: 2026-08-16 10:52:18
    outcome:  failed
    scripts:  2 run, 0 with failures
    checks:   6 passed, 0 failed, 2 skipped

| script | passed | failed | skipped |
|---|---|---|---|
| 00-setup | 6 | 0 | 2 |
| 01-launch | 0 | 0 | 0 |

> The working tree had uncommitted changes when this ran, so it is not evidence about the
> commit it names. CI refuses a stamp in this state.

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
