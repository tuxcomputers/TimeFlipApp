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

`run_tests.sh` also **rebuilds the app** before every run (`swift-bundler bundle TimeFlip`, via
mint, matching `scripts/run.sh`) and aborts if the build fails -- so the checklists never launch a
stale binary. The build is incremental (near-instant when nothing changed); it prints the built
binary's size/mtime so the run's output shows exactly which build ran.

## Before anything runs

**First, before any prompt**, a safety gate (`ensure_not_timing_on_production`) checks
whether we're still on the production database with the device **mid-timing** a real
activity -- i.e. the most recent `device_event` isn't a pause. If so it aborts right away
and tells you to pause the device first, rather than making you answer the rerun/resume and
confirmation prompts below only to bail afterward. The run switches to the test database
and factory-resets the device at the end, so it would otherwise interrupt that live timing
event. On the test database (nothing real to protect) it's a no-op.

Every invocation then prints a warning that this manipulates the real, physical device (and
specifically calls out that `02b`/`02i` itself also does a mid-run reset, on top of the
end-of-run cleanup reset described below), and blocks on typed input -- type `I
understand` to proceed or `Not yet` to abort; anything else re-prompts instead of being
treated as a no, so a typo can't accidentally abort or accidentally proceed. There's no
way to skip this interactively; pass `--yes` only for CI/non-interactive runs (it still
prints the warning, just doesn't wait for input).

The warning's own wording is deliberately reassuring about production history: the
test-database switch only happens once a completed history fetch against production is
confirmed, so nothing real is ever at risk, regardless of what the test session does to
the device afterward.

Once confirmed, the supervisor **always runs `Tests/00-test-setup.md` first** -- a shared
setup checklist (common to Bench and Interactive), run fresh (its boxes are cleared) no
matter which subset was requested, even an Interactive-only or single-file run. It is the
**one and only** place the test database is switched/rebuilt. Its `toml` steps: check which DB
is active and decide whether to record production history (on production it records; otherwise
it asks whether to switch to production and record first, or skip straight to test -- so a run
started off-production doesn't hard-fail); when recording, capture production's max
`debug_log_id`, restart the app to force a fresh history fetch and confirm
`"history fetch complete: trigger=startup"` (so all real history is recorded before switching --
the end-of-run factory reset later wipes the device's own counter); then `use-test-database.sh`,
relaunch, confirm reconnect, and confirm `db_type` is now `test`. If any setup step fails the
whole run aborts before any feature checklist. (`session_setup.py` no longer switches; it just
holds the warning and mid-timing gates and the end-of-run reset/restore.)

The full set of start test conditions, and the path from any current state (which DB, app
up/down, device paired/timing/paused) to them, is documented in
[`START-STATES.md`](START-STATES.md).

Because `00-test-setup.md` performs the switch, the feature checklists no longer repeat it:
their `## Setup` sections hold only their own preconditions (e.g. `01b` checks the test DB
pulled in enough real history; `03b`/`05b`/`06b` verify `db_type=test` and open the right
Settings tab), all as real `toml`. There are no auto-ticked "setup was done elsewhere" steps.

A step with no `toml` (e.g. a screenshot/visual confirmation in `04b`/`07b`/`07i`) is one the
script can't automate, so it **asks you** -- prints the step and waits for a `y/n` -- and
ticks or fails on your answer. It is never silently
skipped, regardless of whether it's a Bench or Interactive checklist. The one exception is
`--yes`/non-interactive mode: with no human to ask, such a step is recorded as a skip (and
the run ends non-zero). Contrast the AI-driven path (see `../../Tests/CLAUDE.md`): when
Claude runs the Bench suite it automates these itself (doing the screenshot/visual check
via its own tooling) rather than asking.

Every step queries the `appdata.sqlite` **symlink**. `00-test-setup.md` repoints it (the one
switch) as an ordered step, and all steps run sequentially, so following the symlink is
correct -- a step only ever runs after the previous one finished, so there's no in-flight
check for a mid-run repoint to disturb. (`debug_log_id` is still per-file: after the switch,
`test.sqlite` starts its own id sequence, so 00-test-setup's post-switch "reconnect" wait
looks for any recent `Login accepted` in the fresh file rather than filtering on a
production-era id.)

For the underlying mechanics -- exactly which tables and `debug_log` markers the runner
queries to detect each piece of state (active database, paused vs timing, reconnect,
history-fetch completion, factory reset), and the `since_id`/per-file pitfalls -- see
[`DETECTION.md`](DETECTION.md).

## After everything runs

Once every requested checklist has finished (pass or fail), the supervisor factory-resets
the device and asks you to re-pair it (one click, can't be scripted) -- this wipes the
whole session's test activity from the device's own onboard counter, so none of it gets
mistaken for real history. It then asks (`y/n`) whether to switch the app back to the
production database now -- say `n` if you're about to run more tests, since switching to
production and back to test every run is wasted effort (`use-test-database.sh` rebuilds
`test.sqlite` from scratch each time). `y` repoints `appdata.sqlite` back at
`production.sqlite` itself (`scripts/use-production-database.sh`, quit/relaunch included)
and confirms the app reconnects against it. `--yes` answers `y` automatically, for
CI/non-interactive use. If either the cleanup reset or (when requested) the database
restore can't complete for some reason, the run prints a clear warning and the log
records it -- resolve that manually (reset/pair the device, and/or run
`scripts/use-production-database.sh` yourself) before trusting production history in
that case.

## Answering a question mid-run

Two prompts, same loop-until-valid shape, different accepted words. Input is lowercased
before comparison in both, so any casing works:
- **The initial acknowledgment** (above) requires the full phrase `I understand` or `Not
  yet` (any case), re-prompting on anything else.
- **Every other yes/no question** (an `ask_user` step, e.g. "did the device refuse the
  flip while locked?") wants a single `y` or `n` (either case -- `Y`/`N` are fine too).
  Anything else (a stray keystroke, a blank Enter) re-prompts instead of being silently
  counted as an answer, so an accidental key can't flip the result either way.

## Steps run without confirmation

Steps run straight through -- the runner prints each step's result and moves on, with no
per-step y/n gate. One line names the step, one reports the result:

```
(00 Test setup) Setup - Step 1: Check which database is active.
-> PASS: production
```

The step line is `(<checklist>) [<actor>] <section> - Step <n>: <instruction>`, where the
instruction is the step's **first line** in the `.md` -- so write that line as the short
imperative sentence and put the rationale/caveats on the wrapped lines under it (see
`Tests/00-test-setup.md` for the shape). `(You)` appears for a `**(You)**` step.

The result line reports only what the step **read**, so a pass stays scannable:

```
-> PASS: 2059          a value it read (a single-key JSON object is unwrapped: {"type":"test"} -> test)
-> PASS                a step that just *does* something -- a click, a quit, a sleep
-> SKIP: not needed (when $want_switch == y)
```

A failure splits the comparison over its own lines, which is what you actually want to read:

```
-> FAIL:
Expected: 67
Result: Yep
```

A failure with nothing to compare (a shell command's non-zero exit, an exception) has no
`Expected`, so it reports what came back inline instead: `-> FAIL: exit=1`.

The only questions asked mid-checklist are the ones a step genuinely needs a human for: an
`ask_user` step, and a documentation-only step with no ` ```toml step ` block (which the runner
asks you to verify against the app/device rather than guess at). Both announce themselves with
a boxed banner, so the point where the run is waiting on you can't be missed in the scroll:

```
**********************************************************************
*                          Action required                           *
**********************************************************************
>>> ACTION NEEDED: Flip the cube to the Break face.
```

The nudge is printed **once**, when the grace period runs out. A wait can last minutes (an
indefinite one until you act), and repeating the banner would only push the step it is asking
about off the screen.

**Any failure stops the run** (see "Failure handling and logs" below). There is no flag for it and
no way to carry on.

Between every step (whatever the mode) the runner pauses `STEP_PAUSE_SECONDS` (2s) -- a beat
for the app/device to settle before the next step, even after a step that already waited on
the DB.

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

### Shared bodies: `use = "method-N"`

A body used by many steps (launching the app, quitting it, confirming the device reconnected,
clicking a menu item, reading a setting) is written **once** in `Tests/Methods.md`, inside the
`## Method N` section that already documents the technique in prose, as a ` ```toml method ` fence.
A step then names it instead of repeating it:

```markdown
- [ ] Step 2: Quit the app. [Method: Number 3](../Methods.md#method-3).
\`\`\`toml step
use = "method-3"
\`\`\`
```

So the Method link a step already cites *is* the thing it runs -- the prose and the behaviour can't
drift, and changing how the app is launched is one edit rather than fifteen copies of a `nohup`
command. `scripts/testrunner/methods.py` resolves it; the table is loaded once at the start of a run,
so a typo in `Methods.md` fails immediately rather than mid-device-test.

The step's other keys do two jobs -- they fill the method's `$placeholders` **and** override or
extend its keys:

```markdown
\`\`\`toml step
use = "method-24.a"        # Method 24's sub-block a: read a setting
setting = "db_type"        # fills the method's $setting
expect = "{\"type\":\"test\"}"   # the step's own assertion, on top
\`\`\`
```

That is also how one shared query serves both an immediate read and a poll -- `action` is just
another key to override:

```markdown
\`\`\`toml step
use = "method-24.d"           # reads the latest debug_log row for a tag
action = "wait_for_sql"       # ... but wait for it rather than read once
tag = "battery"
expect_contains = "isLowBattery=false"
\`\`\`
```

A method covering many variants of one technique holds them as lettered sub-blocks rather than
burning a method number on each, named with a dot: **Method 24** ("Query the DB") is the DB reads
and writes checklists make over and over, so `use = "method-24.b"` is the max-`debug_log_id`
baseline. `use = 3` and `use = "3"` also work; `use` is valid at step level and inside an
`[[actions]]` entry, so a step can mix shared and bespoke actions.

Currently 203 of the 328 actions across the checklists are shared this way, over 18 bodies.

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
in the same run via `$some_name` inside `query`/`command`/`script`/`expect`/`expect_contains`
(Python `string.Template`, so literal JSON braces in a query don't clash).

**`current_log_id` (runner-maintained).** The runner refreshes `current_log_id` to the live
`MAX(debug_log_id)` **before every step** -- you don't capture it, you just read `$current_log_id`.
Scope a step's detection on `debug_log_id > $current_log_id` to mean "a row **this step** produced".
Because it's re-read every step, a later step can never match a stale row from earlier in the run,
and no per-step `SELECT MAX(debug_log_id)` capture is needed. It's re-read, **not** carried across a
database switch: `debug_log_id` is per-file, so when a run switches to a fresh `test.sqlite` (ids
restart at 1) `current_log_id` resets to that file's small max -- it does not keep the old file's
large id (e.g. production's ~34k), which the new sequence would take ages to exceed.

It's only good for *same-step* detection, though. If a scenario needs a baseline that spans
**several** steps -- detect, a few steps later, a row relative to a point further back -- capture
your **own** descriptively-named var at that point (`before_reset_id`, `confirmed_id`,
`prod_before_id`, ...); it coexists with `current_log_id`, which keeps advancing underneath it. Rule
of thumb: same-step → `$current_log_id`; spans steps → give it a name.

**Remembering captured values (`logs/00-remembered.json`).** Every `capture =` value is also
mirrored into `logs/00-remembered.json`, as a tree **run -> test -> scenario -> {capture:
value}**: the top key is the run's log-file stamp (the same `YYYY-MM-DD_hh.mm.ss` as the `.txt`
transcript), then the checklist filename, then the `##` scenario, then that scenario's captures
by name. The file is rewritten after every capture and accumulates runs (each new run adds its
own top-level key).

Its main job is **cross-scenario resume**: a value a scenario captures (e.g. `07b` Scenario A's
`threshold_original`) is needed by a later scenario (Scenario C restores it). On a
restart-from-scenario resume the earlier scenario is skipped, so its `$var` isn't in the live
context -- before each step the runner looks up any missing `$var` it references in this tree
(newest run first, then that test's scenarios) and supplies the previous scenario's value. A var
nothing ever recorded stays unresolved, exactly as before. (JSON-path `$.field` tokens in SQL
aren't treated as vars.) So a checklist can restore a setting in a later scenario without
re-running the scenario that first noted it; keep such captures under a scenario that actually
runs, or resume from the top.

**Conditional steps/actions (`when`).** A `when = "$var <op> N"` guard (e.g.
`when = "$start_event_id < 10"`) runs the step -- or an individual action inside an
`[[actions]]` block -- only if the comparison holds. Operators: `<`, `<=`, `>`, `>=`, `==`,
`!=`; numeric if both sides are numbers, else a string compare. If the guard isn't met, a
whole step is ticked and skipped without running or asking, and an action inside a sequence
is a no-op. Use `$var` (a captured value); a guard that can't be parsed is treated as met, so
a typo never silently skips a step. See `01b`'s Setup: the flip prompt/monitor/stop steps are
each `when = "$start_event_id < 10"`, so a device that already has enough history skips them.

## Action vocabulary (`actions.py`)

| action | purpose |
|---|---|
| `shell` | run a shell command (`command`) |
| `applescript` | run an AppleScript (`script`), optionally assert its output (`expect`/`expect_contains`) or `capture` it |
| `sql_query` | run a `SELECT` (`query`), optionally assert (`expect`/`expect_contains`) or `capture` the result |
| `sql_exec` | run an `INSERT`/`UPDATE` (`query`), no assertion |
| `wait_for_sql` | poll a `SELECT` until it matches `expect`/`expect_contains` or `timeout_seconds` elapses (`poll_interval`, default 2s). `timeout_seconds = 0` waits **indefinitely** -- for a step gated on a human action (toggle Bluetooth, flip the cube) where a distraction shouldn't fail the run; it re-shows the nudge each minute. Optional `prompt` is printed as an "ACTION NEEDED" nudge only if the condition isn't already met when polling starts |
| `cgevent_click` | a real synthetic click/double-click/held-press at a named `target` (see `locators.py`), via `CGEventPost` with `kCGMouseEventClickState` set -- see "Simulate a real click..." in `../../Tests/Methods.md` for why this works where AppleScript's `click` doesn't |
| `cgevent_click_element` | same real CGEvent click, but at the live centre of an accessibility `element` (reads its `position`+`size` first) rather than a fixed `locators.py` target -- for dynamic controls like the discovered-device pairing row (a `Text`+`.onTapGesture` an AX press won't actuate) |
| `cgevent_key` | post a raw keydown/keyup for `keycode` (default `53` = Escape) via `CGEventPost` -- e.g. to dismiss a modal status-item dropdown a synthetic click opened, without an osascript call that would collide with the open menu (see Method 6) |
| `click_menu_item` | open the status-item menu and click `item` by name |
| `ensure_unlocked_unpaused` | idempotent precondition resolver: **polls** the menu over a settle window, clicking Unlock/Resume whenever they appear (the device's lock/pause state can land a couple seconds after login, so a single read would miss it) -- declares clean only after the menu stays clear for `clean_confirm_seconds` |
| `ask_user` | print `prompt`, block for a y/n -- a gate by default (`n` fails the step); with `capture`, a *branch* instead (stores `y`/`n` in that var, always succeeds, for a later `when` to read -- see `00-test-setup.md`'s record-history choice) |
| `ask_user_or_detect` | print `prompt`, then poll `detect_query` for a change instead of waiting on Enter -- see "Detect a physical action instead of asking" in `Methods.md`. `timeout_seconds = 0` waits indefinitely (same rationale as `wait_for_sql`), re-nudging each minute |

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
waits here are deterministic (a device round-trip, a debounce timer), but `07b`'s hysteresis
check (waiting for the live battery reading to naturally flap up 1-2%) depends on genuine,
unpredictable analog battery behavior -- confirmed live to sometimes not happen within 5
minutes at all. A long timeout doesn't fix non-determinism it just papers over it; that
step can legitimately need re-running, same as the original human-driven checklist did.

## Rerun / resume behavior

Before anything else (even the device-manipulation warning), the supervisor checks the
progress of every checklist about to run, as one whole-batch decision -- not per file:

- **All of them already fully checked** -- prints one line saying so, then asks `y/n`:
  clear their results and run again? `n` exits with nothing run.
- **Any of them not fully checked** (partially or entirely unticked) -- prints only where
  the batch is up to, not the whole list, e.g. `The test run did not complete, '01b history
  refresh checklist' the test is up to 'Scenario B Step 4' which is '<full step text>'`, then
  asks `[t/s]`: restart from the **[t]op** or from the current **[s]cenario**?
  - **`t`** clears every requested checklist and runs the whole batch again from the top.
  - **`s`** keeps every completed scenario (and every earlier checklist) ticked, clears the
    current scenario's steps and everything after them, and re-enters at that scenario's first
    step. A scenario is the atomic resume unit: you never resume *mid*-scenario, because a
    scenario's steps assume state its preconditions + earlier steps established (Step 1 relies
    on the preconditions; Step 25 relies on Steps 1-24), so the whole scenario is re-run.

  (A completely fresh batch -- nothing ticked anywhere -- skips this prompt; there's nothing to
  keep.)

  On **`s`** the shared setup runs in *keep* mode: it does **not** wipe the test DB
  (`use-test-database.sh keep` preserves the existing `test.sqlite`) and skips the
  production-history round-trip, so the state the kept-ticked earlier scenarios built survives
  into the resumed one. It still quits and relaunches the app, so a rebuilt binary is picked up.
  A **`t`** / fresh run rebuilds `test.sqlite` from scratch as before. (`main()` derives this from
  the rerun decision and passes `resume`/`db_mode` into the setup run's `initial_vars`.)

`--yes` answers both automatically (clear-and-rerun; and, mid-run, restart from the top) without
blocking, for CI/non-interactive use.

Restart-from-scenario keeps earlier scenarios' checkboxes but not their live `$vars` (each
checklist run starts with a fresh var context). That's fine: a value a *previous* scenario
captured is recovered from `logs/00-remembered.json` when a later scenario references it -- see
"Remembering captured values" below.

### What's recorded where

A checklist step's only in-file record is its **checkbox tick** -- the runner no longer
writes `(Automated: ...)` notes back into the `.md`. The run log is written to be scannable:
a `=== <folder>/<file> ===` heading (path relative to `Tests/`, not the full path), each
section name as a sub-heading, then one line per step:

```
=== Bench/01b-history-refresh-checklist.md ===

Setup
Step 1: PASS - Confirm the latest device_event row is open.

Scenario A
Step 1: PASS - Note the open row's event_number and duration.
Step 2: SKIP - Build history. (when $needs_history == y not met)
Step 3: FAIL - Query debug_log for the unchanged marker.
  - Expected: contains history fetch: device max_event_number=13 unchanged
  - Result: (no rows) (still, after waiting 15s)
```

The step text is the step's first line in the `.md`, same as the console. A **PASS** that got
what it expected records no detail -- the tick is enough. A **FAIL** records the comparison as
`  - Expected:` / `  - Result:` lines, or a single `  - Result:` when there was nothing to
compare (a shell command's non-zero exit, an exception). A **SKIP** shows why (an unmet `when`
guard, or a human step under `--yes`). Captured values are **not** logged here -- they go to
`logs/00-remembered.json` (see `remember`/`restores` above). A failure also adds a
`FAILURE LOGGED` line, keyed by the `T<checklist>-<section>-St<n>` id.

## Failure handling and logs

**A failed step stops the whole run.** Not just the scenario, and not just the checklist: nothing
after it runs, in any checklist. Later steps lean on what earlier ones established (step 1 on the
scenario's preconditions, step 25 on steps 1-24, a later checklist on the state an earlier one
left), so carrying on past a failure produces results that can't be trusted anyway, and it does it
while churning away the device state that caused the failure. Halting leaves that state intact.

The failed step is logged `FAILURE LOGGED` and left unticked, as is everything after it, so a
resume picks up from the failure. End-of-run cleanup (the device factory reset, the switch back to
production) is deliberately **skipped** on a halt, so the device is not reset out from under the
investigation -- the run says so, and reminds you that you are probably still on the test database.
Exit code is 2.

Before each feature checklist the runner also checks the device is actually connected (a
recent heartbeat -- `battery`/`hist-*` rows land every ~10s while connected; see
`device_appears_connected`). If it isn't -- e.g. a failed re-pair in 02b left it forgotten --
the run stops rather than churning the remaining checklists' device-independent steps against
a device that isn't there.

Every run writes `logs/YYYY-MM-DD_hh.mm.ss.txt` (gitignored -- these are run artifacts,
not source) with a full transcript, and the process exits non-zero if anything failed or
was skipped. Attach that file when filing an issue, or point CI at it as a build artifact.
Alongside it, `logs/00-remembered.json` records the values each run read and changed (see
`remember`/`restores` above) under that same timestamp key.
