# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   feature/linuxPort
    commit:   58459e70c3b0f2cb12c5d786f969ca620ed5b23c
    tree:     dirty
    database: kept (--keep)
    started:  2026-09-20 10:10:38
    finished: 2026-09-20 10:10:40
    outcome:  passed
    scripts:  1 of 1 run, 0 with failures
    short:    0 ran fewer checks than they declare
    filter:   01
    checks:   9 in total
              9 passed
              0 failed

| script | expected | passed | failed | time |
|---|---|---|---|---|
| 01-launch | 9 | 9 | 0 | 0m 02s |
| **total** | **9** | **9** | **0** | **0m 02s** |

> The working tree had uncommitted changes when this ran, so it is not evidence about the
> commit it names. CI refuses a stamp in this state.

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
