# Interactive Test Checklists

`swift test` can't exercise everything: real BLE hardware, app restarts, sleep/wake cycles, and
timing-dependent behavior need a human and a physical TimeFlip device in the loop. This directory
holds checklists for exactly that kind of test, run together (Claude + you) and committed as part
of the PR that needed them, so the PR record shows the manual verification actually happened.

## File naming

- `README.md` (this file) — the convention, not a checklist. Never scanned by CI.
- `<NN>-<feature>-checklist.md` -- one checklist per feature/behavior under test, numbered from
  `00` so they sort and list together instead of being interspersed alphabetically with each other
  or with `README.md`/`current_settings.json`. The number reflects sensible **run order**, not just
  creation order -- broader/foundational checks before narrower or independent ones (e.g.
  `00-history-refresh-checklist.md`, covering core data-flow correctness, before
  `01-battery-low-indicator-checklist.md`, a smaller, independent UI feature), and anything a later
  checklist's setup actually depends on before that checklist. When adding a new one, pick its
  number by where it belongs in that order, not by appending to the end.

  If it belongs earlier than the current last number, renumber to make room, rather than reusing
  or skipping a number:
  1. Decide the new file's correct position (call its target number `K`).
  2. For every existing file numbered `K` and above, rename it up by one (`git mv`), working from
     the *highest* number down so no rename overwrites another file still waiting to be moved.
  3. Add the new file as `K-<feature>-checklist.md`.
  4. Grep the repo for the old filenames (`grep -rn "NN-old-name"`) and fix any references (e.g. in
     this README's own examples above) to the new numbers.

  These are scanned by CI (see below) and must have every box checked before the PR can merge.

## Format

Each checklist is a GitHub-flavored Markdown task list. Every item is prefixed with who performs
it:

- `**(Claude)**` — something Claude does itself: query the DB, inspect a file, run a command.
- `**(You)**` — something that needs you physically: flip the device, quit/relaunch the app, turn
  Bluetooth off, wait out a timer, confirm what's on screen (a color, a blink, an icon).

Steps are ordered as a single sequence (not grouped by who does them), because order matters --
e.g. "note the current event number" has to happen before "flip the device."

```markdown
- [ ] **(Claude)** Query `device_events` for the current max event number; note it as N.
- [ ] **(You)** Flip the TimeFlip device to a new facet.
- [ ] **(Claude)** Confirm a new `device_events` row appeared with event number > N.
```

### Presenting durations

`duration_seconds` (and any other duration pulled from the DB) is stored/logged in raw seconds, but
when asking the user to confirm a duration on screen, convert it to `mm:ss` first (e.g. `624`
seconds -> `10:24`) -- that's the format the menu bar actually displays, and it's what the user can
compare at a glance.

### Reading debug output: use `debug_log`, not the terminal

Don't rely on reading a live terminal/console transcript for `(Claude)` steps -- there's usually no
reliable way to attach to whatever terminal/session the app happens to be running in. Instead,
every `DeveloperMode.debugPrint` call is also recorded to the `debug_log` table whenever Developer
Mode is on and the `debug` setting's `enabled` field is `true` (see `009_setting.sql`), specifically
so a test session can be inspected after the fact via a plain `sqlite3` query instead of a captured
console transcript. Query it directly, e.g.:

```
sqlite3 ~/Library/Application\ Support/TimeFlip/appdata.sqlite \
  "SELECT tag, message, logged_at FROM debug_log ORDER BY debug_log_id DESC LIMIT 20;"
```

`tag` matches the bracketed prefix from `DeveloperMode.DebugTag` (e.g. `history`, `battery`,
`TimeFlip`, `dev-check`), and `logged_at`/`logged_at_timezone` let you correlate against when a
`(You)` step happened.

### Temporarily changing a DB setting for a test

Some checklists need to change a `setting` row to make a slow/rare condition happen on demand (a
short `fetch_history_interval_seconds` instead of waiting out the real interval, a
`low_battery_level` at/above the current reading instead of waiting for the battery to actually
drain). Never do this without recording the full settings state first, in
`Tests/Interactive/current_settings.json` -- gitignored, not committed, since it only reflects
tests currently/previously in progress on this machine:

```json
{
  "settings_as_at": {
    "2026-07-18-11.00.51": [
      {"setting_name": "blip_time", "setting_value": "{\"seconds\":5}"},
      {"setting_name": "fetch_history_interval_seconds", "setting_value": "{\"seconds\":600}"}
    ]
  }
}
```

`settings_as_at` is the top-level key; each key under it is a `YYYY-MM-DD-hh.mi.ss` timestamp, and
its value is a full snapshot of **every** row in the `setting` table at that moment (not just the
ones about to change) -- `SELECT setting_name, setting_value FROM setting`. Workflow:

1. Take exactly **one** snapshot per testing session, right before the *first* setting change of
   that session -- not one per individual change. If you're about to change `low_battery_level`
   and then later, in the same session, also change `fetch_history_interval_seconds`, that's still
   only one snapshot total, taken before the first of the two.
2. Make whatever changes the session's checklist(s) need, in any order, without snapshotting again.
3. Once testing is complete, or the user says they're done, restore every row back to the values
   from the snapshot taken in step 1 for *this* session -- which, since each session adds its
   snapshot after any prior ones, is the **latest** (most recent) entry under `settings_as_at`, not
   the earliest.

The reason it has to be the latest, not the earliest: a setting's real, permanent value can
legitimately change between sessions for reasons that have nothing to do with testing -- e.g. it
was `1200` during an earlier session (snapshotted as `1200`), genuinely changed to `600` afterwards
outside of testing, and *today's* session snapshots it as `600`. Restoring to the oldest snapshot
would wrongly revert that real change back to `1200`; restoring to the latest correctly puts it
back to `600`, which is what was actually true immediately before today's testing started. Never
snapshot mid-session just because a value changed -- that's the state testing is *supposed* to
perturb, not something to preserve.

## Running a checklist

When asked to run through a checklist:

1. Go top to bottom. For a `(Claude)` step, do the thing, then check the box.
2. For a `(You)` step, ask the user to do it, wait for confirmation, then check the box.
3. Don't skip ahead — later steps often depend on the state a prior step established.
4. Anything the user needs to physically go do -- a `(You)` step, or an ad hoc request that comes
   up mid-run and isn't in the checklist text at all (e.g. "turn off Bluetooth") -- has to visually
   stand out from ordinary conversational replies, or it reads as just more chat and the user won't
   register that an action is expected of them. Use a large markdown heading (e.g. `## Action
   needed`) or comparably bold/distinct formatting, not a plain sentence sitting among other plain
   sentences.
5. Under that heading, match the format to the step count: a single action is just the plain
   instruction sentence; multiple actions (e.g. "turn off Bluetooth, then flip the device twice")
   are a numbered list, one action per line, not run together in prose -- so the user can tell at a
   glance how many things they need to do and check them off one at a time.

## Restarting

If asked to restart a checklist, clear every box in that file back to `- [ ]` (don't delete or
reorder the steps) and start again from the top. This is a deliberate reset, not a bug: it means
the checklist needs to be re-verified from scratch, e.g. against a code change made after the last
run.

## CI enforcement

`scripts/check_interactive_checklists.sh` (wired into `.github/workflows/tests.yml`) fails the
build if any `<feature>-checklist.md` file under this directory has an unchecked (`- [ ]`) item.
This means: if a PR adds or touches an interactive checklist, it must be fully ticked and committed
before the PR can merge -- the checklist itself is the evidence that the manual steps were done.
