# Scripted suite: last run

Written by `Tests/Scripted/run.sh` at the end of every run, and committed.
**Do not edit it by hand.** CI reads it to decide whether this branch's checks were actually
run, and a stamp that does not describe a real run is worse than no stamp at all.

    branch:   feature/linuxPort
    commit:   cd971a1a5de6cb6e9904fc429d112b9f0c0ea2f3
    tree:     dirty
    database: kept (--keep)
    started:  2026-09-20 12:40:29
    finished: 2026-09-20 12:40:34
    outcome:  passed
    scripts:  1 of 1 run, 0 with failures
    short:    0 ran fewer checks than they declare
    filter:   02
    checks:   9 in total
              9 passed
              0 failed

| script | expected | passed | failed | time |
|---|---|---|---|---|
| 02-menu-bar | 9 | 9 | 0 | 0m 03s |
| **total** | **9** | **9** | **0** | **0m 03s** |

> The working tree had uncommitted changes when this ran, so it is not evidence about the
> commit it names. CI refuses a stamp in this state.

The full record, including the app's own log rows and the accessibility tree at each failure,
is in `logs/testlog.sqlite` on the machine that ran it. That file is not in the repository.
