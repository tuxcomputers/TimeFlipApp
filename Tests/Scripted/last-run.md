# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   feature/autoPause
    commit:   e3a30da460c50ca4460f333f742b339f1a9d8f81
    tree:     clean
    database: kept (--keep)
    started:  2026-08-27 20:47:46
    finished: 2026-08-27 20:47:47
    outcome:  failed
    scripts:  1 of 1 run, 0 with failures
    short:    1 ran fewer checks than they declare
    filter:   62
    checks:   0 in total
              0 passed
              0 failed

| script | expected | passed | failed | time |
|---|---|---|---|---|
| 62-forced-pause | 13 | 0 | 0 | 0m 00s |
| **total** | **13** | **0** | **0** | **0m 00s** |

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
