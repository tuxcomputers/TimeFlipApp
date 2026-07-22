# Device-test runner (no Claude required)

Runs the `Tests/Bench/`/`Tests/Interactive/` checklists standalone: a bash entry point
(`run_tests.sh`) launches a Python supervisor that executes each checklist step, ticks
its checkbox on success, and writes a timestamped log -- for developers who don't have
an AI driving the checklist by hand.

## Usage

```
scripts/testrunner/run_tests.sh                        # everything: Bench (sorted), then Interactive (sorted)
scripts/testrunner/run_tests.sh -f Bench                # only that folder, sorted
scripts/testrunner/run_tests.sh -s 01                   # both folders, filenames containing "01" -- 01b then 01i
scripts/testrunner/run_tests.sh -s reset                # substring match works by name too, not just number
scripts/testrunner/run_tests.sh -f Bench -s reset       # combine both
scripts/testrunner/run_tests.sh Tests/Bench/04b-lock-and-pause-on-lock-checklist.md   # explicit paths, exact order
```

With no arguments (or just `-f`/`-s`), checklists are auto-discovered from
`Tests/Bench/`/`Tests/Interactive/` (matching `*-checklist.md`, sorted by filename --
the zero-padded `NN` prefix sorts correctly) and run Bench-then-Interactive automatically,
satisfying `Tests/CLAUDE.md`'s run-order rule without you having to list files yourself.
`-f`/`-s` only narrow that auto-discovery; they're mutually exclusive with passing
explicit file paths, which still run in the exact order given, bypassing discovery
entirely. Both flags accept the `--folder=Bench`/`--search=reset` equals-style form too.

Requires `pyobjc` (`pip3 install pyobjc-framework-Quartz`) for `cgevent_click` steps --
`run_tests.sh` checks for it up front. Everything else is Python 3.11+ stdlib.

## Before anything runs

Every invocation prints a warning that this manipulates the real, physical device (and
specifically calls out that `02b`/`02i` itself also does a mid-run reset, on top of the
end-of-run cleanup reset described below), and blocks on typed input -- type `I
understand` to proceed or `Not yet` to abort; anything else re-prompts instead of being
treated as a no, so a typo can't accidentally abort or accidentally proceed. There's no
way to skip this interactively; pass `--yes` only for CI/non-interactive runs (it still
prints the warning, just doesn't wait for input).

The warning's own wording is deliberately reassuring about production history: the
test-database switch only happens once a completed sync against production is confirmed,
so nothing real is ever at risk, regardless of what the test session does to the device
afterward.

Once confirmed, `session_setup.py` establishes the known state every checklist assumes,
mirroring "Switch to the test database" in `../../Tests/Methods.md`: confirms/switches to
the test database (quitting, running `use-test-database.sh`, relaunching, and waiting for
a **fresh** post-relaunch reconnect -- not a stale pre-relaunch row, since `debug_log`
persists across restarts) if currently on production, or just confirms the device is
connected if the test database is already active. This runs once per invocation, not once
per checklist file.

## After everything runs

Once every requested checklist has finished (pass or fail), the supervisor factory-resets
the device and asks you to re-pair it (one click, can't be scripted) -- this wipes the
whole session's test activity from the device's own onboard counter, so none of it gets
mistaken for real history. It then repoints `appdata.sqlite` back at `production.sqlite`
itself (`scripts/use-production-database.sh`, quit/relaunch included) and confirms the
app reconnects against it -- you don't need to remember to do this by hand. If either the
cleanup reset or the database restore can't complete for some reason, the run prints a
clear warning and the log records it -- resolve that manually (reset/pair the device,
and/or run `scripts/use-production-database.sh` yourself) before trusting production
history in that case.

## Answering a question mid-run

Two prompts, same loop-until-valid shape, different accepted words:
- **The initial acknowledgment** (above) requires the full phrase `I understand` or `Not
  yet`, re-prompting on anything else.
- **Every other yes/no question** (an `ask_user` step, e.g. "did the device refuse the
  flip while locked?") wants a single `y` or `n` -- lowercase, exact. Anything else (a
  stray keystroke, wrong case, a blank Enter) re-prompts instead of being silently
  counted as an answer, so an accidental key can't flip the result either way.

## How a checklist step becomes runnable

A step is a normal `- [ ]`/`- [x]` checklist line, same as any other -- the human-readable
`.md` doesn't change. What makes it *runnable* is a fenced ` ```toml step ` block placed
directly under it, holding that step's action(s). A step with no such block is
documentation-only (a Preconditions note, a not-yet-converted step) and the runner skips
it with a visible `SKIP` line rather than guessing.

```markdown
- [ ] Click the "Lock" menu item.
\`\`\`toml step
action = "click_menu_item"
item = "Lock"
\`\`\`
```

A step needing more than one action (e.g. "click, then confirm via `debug_log`") uses an
array of actions, run in order, stopping at the first failure:

```markdown
- [ ] Double-click the right half of the status icon; confirm it locked.
\`\`\`toml step
[[actions]]
action = "cgevent_click"
target = "status_item_right"
mode = "double"

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Lock verification confirmed: requested=ON actual=ON"
timeout_seconds = 10
\`\`\`
```

A value captured by one step (`capture = "some_name"`) is available to every later step
in the same run via `{some_name}` inside `query`/`command`/`script`/`expect`/`expect_contains`
(Python `str.format`).

## Action vocabulary (`actions.py`)

| action | purpose |
|---|---|
| `shell` | run a shell command (`command`) |
| `applescript` | run an AppleScript (`script`), optionally assert its output (`expect`/`expect_contains`) or `capture` it |
| `sql_query` | run a `SELECT` (`query`), optionally assert (`expect`/`expect_contains`) or `capture` the result |
| `sql_exec` | run an `INSERT`/`UPDATE` (`query`), no assertion |
| `wait_for_sql` | poll a `SELECT` until it matches `expect`/`expect_contains` or `timeout_seconds` elapses (`poll_interval`, default 2s) |
| `cgevent_click` | a real synthetic click/double-click/held-press at a named `target` (see `locators.py`), via `CGEventPost` with `kCGMouseEventClickState` set -- see "Simulate a real click..." in `../../Tests/Methods.md` for why this works where AppleScript's `click` doesn't |
| `click_menu_item` | open the status-item menu and click `item` by name |
| `ensure_unlocked_unpaused` | idempotent precondition resolver: clicks Unlock/Resume only if the menu currently shows them |
| `ask_user` | print `prompt`, block on Enter -- for a step that genuinely needs a human (a physical flip) |
| `ask_user_or_detect` | print `prompt`, then poll `detect_query` for a change instead of waiting on Enter -- see "Detect a physical action instead of asking" in `Methods.md` |

`locators.py` resolves named on-screen targets (currently `status_item_left`/`status_item_right`)
fresh via accessibility on every call, since the status item's width shifts with its
content. Add a new named target there before referencing it from a `cgevent_click` step.

## What this can't do (yet)

Several existing checklist lines are pure visual confirmations ("Screenshot the menu bar;
confirm the red lock badge is visible") with no accessibility or DB equivalent -- a script
can't see an image. These are left without a `toml step` block (skipped, visibly) rather
than faked. A future action type could sample specific pixels/crops via `screencapture` +
simple color/template checks; not implemented here.

A `wait_for_sql` step is only as reliable as the real-world event it's waiting for. Most
waits here are deterministic (a device round-trip, a debounce timer), but `03b`'s hysteresis
check (waiting for the live battery reading to naturally flap up 1-2%) depends on genuine,
unpredictable analog battery behavior -- confirmed live to sometimes not happen within 5
minutes at all. A long timeout doesn't fix non-determinism it just papers over it; that
step can legitimately need re-running, same as the original human-driven checklist did.

## Rerun / resume behavior

Before anything else (even the device-manipulation warning), the supervisor checks the
progress of every checklist about to run, as one whole-batch decision -- not per file:

- **All of them already fully checked** -- asks `y/n`: clear their results and run again?
  `n` exits with nothing run.
- **Any of them not fully checked** (partially or entirely unticked) -- asks `y/n`: resume
  from where things left off? `y` continues each checklist from its first unchecked step,
  same as always. `n` clears every requested checklist's results (checkboxes and any
  `(Automated: ...)`/`(AUTOMATED FAILURE: ...)` notes from the previous run) and starts
  the whole batch over from the top.

`--yes` answers both automatically (clear-and-rerun, and resume, respectively) without
blocking, for CI/non-interactive use.

## Failure handling and logs

On a step's failure, that checklist stops immediately (later steps assume earlier ones
left the state they need) -- other checklists passed on the command line still run.
Every run writes `logs/YYYY-MM-DD_hh.mm.ss.txt` (gitignored -- these are run artifacts,
not source) with a full transcript, and the process exits non-zero if anything failed or
was skipped. Attach that file when filing an issue, or point CI at it as a build artifact.
