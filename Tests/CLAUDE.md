# Running the device tests

Read this entire file, `Methods.md`, and each relevant checklist/`README.md` all the way through
*before* taking the first action -- don't start executing (launching the app, quitting, ticking a
box) partway through discovering the rules. A rule further down (the live-app-interaction warning,
a run-order constraint, a step-sequencing requirement) still applies to the very first action
taken, so read first, then act.

Everything here is verified against a real, live run -- not guessed. When you discover something
new, add a **minimal** entry (the fact/command, not the discovery story -- that goes in
`README.md`). This suite runs repeatedly over time: treat friction (a retry, a workaround, an
ambiguity) as a gap in this file to fix now, not a one-off to shrug off. `Methods.md`, alongside
this file, holds the reusable step-execution techniques (clicking a menu item, editing a field,
reading debug output, ...) that a checklist step cites by name rather than re-describing.

When asked to run the device tests, work through the on-device checklists under `Tests/` -- **not**
`swift test` (the hermetic unit suite, no device). Two phases, in order:

1. **Bench** (`Tests/Bench/<NN>b-*-checklist.md`) -- entirely Claude-driven, no actor labels.
2. **Interactive** (`Tests/Interactive/<NN>i-*-checklist.md`) -- steps needing a person (physical
   cube action, sustained press-hold, an unscriptable gesture, or multi-element lockstep
   confirmation). `(Claude)`/`(You)` labels.

Each folder's own `README.md` describes just that suite.

## Rules

- Finish the entire Bench phase (every checklist) before starting any Interactive checklist.
- Each numbered checklist has a file in both folders; a side with no work is a stub (`Nothing
  needed`).
- Go top to bottom -- later steps depend on state earlier ones establish.

## File naming

- `<NN>b-<feature>-checklist.md` in `Tests/Bench/`, `<NN>i-<feature>-checklist.md` in
  `Tests/Interactive/` -- same `<NN>` and `<feature>` in both, only the trailing `b`/`i` differs, so
  the two sides of one numbered pair are never identically named (a same-named pair used to be
  ambiguous to tell apart when both were open at once).
- Neither folder's `README.md` nor this file is a checklist -- CI never scans them.
- To insert one earlier: `git mv` every file numbered >= the target up by one (highest first), add
  the new file at that number in both folders, fix references to the old numbers.

## Format

- `Tests/Bench/`: no actor label, one plain instruction per line.
- `Tests/Interactive/`: `**(Claude)**` or `**(You)**` prefix per item, single ordered sequence
  (order matters).

## Scenario preconditions

Every `## Scenario` states its required device/app state as a `**Preconditions:**` line, then a
step that checks and resolves any mismatch before the real steps begin -- never assume a previous
scenario or session left the expected state (confirmed live: `Interactive/04` once found the device
locked *and* paused from a prior session's leftover state, not its own). Point back at an existing
resolution step instead of duplicating one.

## Driving the app directly

`Tests/Methods.md` holds the concrete "how" (build/launch/quit, clicking a menu/button/checkbox,
editing a field, reading debug output, switching databases, screenshot confirmation, etc.) as
individually-named methods. A checklist step needing one of these techniques says `Method: <name>`
and points there instead of re-describing the mechanics -- read that file for the actual commands.
What's below is background behavior/facts, not technique:

- Any script-driven click mutates real state like a human click would -- run against the test DB
  (`Method: Switch to the test database`), and follow the root `CLAUDE.md`'s live-app-interaction
  ritual. Exception: `02b-reset-device-checklist.md`'s factory reset doesn't need a live
  pause-and-confirm -- the test-DB pre-flight (in `01b-history-refresh-checklist.md`'s Setup,
  which runs first) already syncs real history first, so nothing is at risk.
- A factory reset ends with the device **forgotten / "Not paired"**, not reconnected:
  `factoryReset()` just sends 0xFF (no usable ack, device reboots), the app drops the connection,
  and a successful default-password relogin confirms the wipe (deliberately not treated as a
  pairing). Expect **"Resetting..." -> "Not paired"**, not "Reconnecting..." -> "Connected"; needs a
  fresh Scan/re-pair after. The first reconnect can still accept the OLD password briefly (reset not
  yet applied) -- confirmation is gated on the *default* password specifically.
- The device correctly rejects a wrong password (explicit `0x01`, not silently accepted) -- no
  security concern there.

## Running a checklist

1. Top to bottom. In `Tests/Bench/`, do each step and check the box, no asking. In
   `Tests/Interactive/`, do each `(Claude)` step the same way; for `(You)`, ask the user, wait for
   confirmation, then check the box.
2. Don't skip ahead -- later steps often depend on state a prior step established.
3. Anything the user has to do -- a `(You)` step, or an ad hoc mid-run request not in the checklist
   text at all (e.g. "turn off Bluetooth") -- gets a large heading (e.g. `## Action needed`), not a
   plain sentence among ordinary replies.
4. Only put things the user actually has to do under that heading -- not a `(Claude)` step, even one
   involving a setting the user could technically change themselves. Don't ask the user to "confirm"
   something Claude already did/verified, just to pad out a list.
5. When a feature has more than one trigger (a menu item vs. a gesture), give each its own
   scenario/steps -- don't fold both into one step, so a bug in one path can't hide behind the
   other having been exercised instead.
6. A checkbox tick is the record a step happened -- don't add a note just to say so (e.g. bare
   "Confirmed."). Only add one when it carries real evidence the tick alone doesn't (a queried
   value, an exact log line), in parentheses at the end of the same item:
   ```markdown
   - [x] Query `debug_log` for recent `battery` rows and note the live level's natural fluctuation
         range. (Confirmed: flaps between 26% (lower) and 27% (higher).)
   ```
7. Match the action-needed format to the step count: a single action is a plain sentence; multiple
   actions are a numbered list, one per line.
8. Announce finishing a scenario/section with a heading as big as `## Action needed` (e.g. `##
   Scenario A complete`) plus a one-line result, before starting the next.
9. Combine multiple conditions into one yes/no ask with a short lead-in plus a numbered list, not
   separate questions per condition. Anything other than a clean yes: ask which part didn't match,
   don't tick on an ambiguous or partial answer.
10. If the user did something unasked (an extra click, an early setting change), don't press on --
    work out what state that leaves things in, say so plainly, and give explicit steps back to the
    state the current step requires before re-asking for confirmation.
11. Always name which trigger an action-needed step means ("click the Lock **menu item**"), even if
    it seems obvious from context -- don't make the user infer which gesture/scenario applies.

## Last run tracking

Each checklist records when and on which branch it was last *actually run against the device*, as a
heading directly under the file's title (the first `#` heading), before any intro prose:

```markdown
# Reset Device Checklist

### Last run - 2026-07-20 on the branch 'feature/blahBlah'
```

Update it to today's date and the current branch **only when you actually run that checklist on this
branch** -- never when merely editing the file during development. Each checklist tracks its own last
run independently: running only `01` on a branch updates only `01`'s heading; every other checklist
keeps the date/branch from whenever *it* was last run (an earlier branch, or nothing at all --
checklists predating this convention simply won't have the line until their next run, and that's
expected).

## Bugs found and fixed

This section is **only** for a real bug found while *running the checklist against the device* --
never for changes made during normal development. If no bug surfaced during a test run, there's no
section.

Record such a bug right under the item that exposed it, and **name the branch in the heading** so
it's unambiguous which branch's testing found it:
```markdown
- [x] **(You)** Confirm the activity name is blinking red/white.
### Bugs found and fixed - branch 'feature/blahBlah'
2026-07-18 - The off flash was 0 so it looked like the icon was always red, fixed.
```
One line per bug, dated `YYYY-MM-DD`, terse -- the actual fix is in the commit/diff, don't
re-explain it here. Append further bugs found on later runs of the same checklist on the same
branch under the existing heading, rather than replacing it.

Clearing is per-checklist and tied to *actually running it*: when you re-run a checklist on a
different branch (the same run that updates its `### Last run` heading), clear its old Bugs found and
fixed first -- those bugs belonged to the previous branch, and the fresh run starts its own history.
But a checklist you **don't** run on the current branch keeps **both** its `### Last run` heading and
its Bugs found and fixed exactly as the previous branch left them -- untouched history for the branch
it was last run on. So a found-and-fixed (or Last run) whose branch doesn't match the current one is
never stale-to-delete on sight; it just means that test hasn't been re-run here yet.

## Restarting

Before clearing any checkboxes (single-file or the across-every-checklist form below), ask the
user first via AskUserQuestion -- it discards recorded evidence (confirmation notes, bug entries
tied to those ticks), so confirm the restart is actually wanted before running it.

To restart a checklist: clear every box in that file back to `- [ ]` (don't delete or reorder the
steps) and start again from the top. To do this across every checklist at once, match the literal
`[x]` token -- BSD `sed` doesn't support `\s`/`\S` in a bracket-free BRE (it silently matches
nothing, no error), so a fancier whitespace-aware pattern would no-op:
```
for f in Tests/Bench/*-checklist.md Tests/Interactive/*-checklist.md; do
  sed -i '' 's/\[x\]/[ ]/g' "$f"
done
```
Confirm with `grep -c '\[x\]' Tests/Bench/*-checklist.md Tests/Interactive/*-checklist.md` -- every
file should read `0`.

## CI enforcement

`scripts/check_interactive_checklists.sh` (wired into `.github/workflows/tests.yml`) fails the
build if any `<feature>-checklist.md` under either `Tests/Bench/` or `Tests/Interactive/` has an
unchecked (`- [ ]`) item. A PR touching either folder must have it fully ticked before merging.
