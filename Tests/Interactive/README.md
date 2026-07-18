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

Always make sure the `display_seconds` setting is enabled (`{"enabled":true}`) at the start of a
testing session -- check it as part of Setup, same as any other DB setting. With it on, the menu
bar shows to-the-second granularity, which is what makes "is the time increasing or static" (see
below) something the user can actually judge over a short glance instead of needing to wait out a
whole displayed minute to see the number move.

To confirm whether the device is currently running or paused, don't ask "is it paused?" -- ask "is
the time increasing?" as a plain yes/no over a couple of seconds of watching (yes = running, no =
paused). That's a concrete, directly-observable thing to check; "paused" is a state name the user
would otherwise have to infer.

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

### Suppressing incidental physical double-taps during a test session

The TimeFlip2 device pauses itself whenever it detects a physical double-tap -- this is
unconditional firmware behavior (see `docs/TimeFlip2 BLE Protocol v4.3.md`'s double-tap notify
description) with **no BLE command to disable it outright**. The only adjustable lever is
accelerometer click-detection *sensitivity* (commands `0x16` write / `0x17` read -- `clickThreshold`,
`limit`, `latency`, `window`, each a `UInt8` 0-255), exposed through the app's own Double Tap
section in Settings, not a `setting` DB row (the `double_tap_settings` DB row exists but nothing in
the app reads it -- it's dead seed data, don't rely on it).

Since an accidental double-tap mid-test can otherwise look like a confusing, unexplained state
change, suppress it for the duration of a testing session:

1. At the very start of the session (same one-snapshot rule as DB settings above), ask the user to
   expand the Advanced section (click the "Advanced" label or its arrow) in Settings, then click
   "Sync from device" under Double-tap sensitivity and report the four current values. Record them
   in `current_settings.json` under a `double_tap_params_as_at` key (same timestamp-keyed structure
   as `settings_as_at`) -- this is a device hardware register, not a DB row, so it can't be read via
   `sqlite3`.
2. Ask the user to set `window` (`TIME_WINDOW`) to `0` and click "Apply". `window` is the maximum
   time the accelerometer allows between the first and second tap for it to still count as one
   double-tap -- `0` structurally guarantees no double-tap can ever complete, a stronger guarantee
   than raising `clickThreshold` (which only requires more force, not zero opportunity). Leave
   `clickThreshold`/`limit`/`latency` alone; this doesn't touch the separate facet-flip/orientation
   detection either way.
3. Run the session's checklist(s) as normal.
4. Once testing is complete, ask the user to re-enter the original values from step 1 and click
   "Apply" again -- restoring from the latest snapshot, same rule as DB settings.

If a checklist scenario is specifically testing double-tap-to-pause behavior itself, that scenario
needs the real sensitivity active -- temporarily restore the original values for just that scenario,
then re-suppress before continuing with anything else in the session.

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
5. Only put things under that heading that the user actually has to do. A `(Claude)` step --
   including one that happens to involve a setting the user can't practically change themselves,
   like a DB value -- is not an action-needed item; do it, then move straight to whatever the next
   real `(You)` step is. Don't ask the user to "confirm" something Claude already did/verified
   itself just to pad out a list.
6. When a feature can be triggered more than one way (e.g. a menu item vs. an equivalent
   click/gesture on the status icon), don't fold both into a single step ("click X, or do gesture
   Y") -- give each its own scenario/steps so a bug in one path isn't masked by the other having
   been exercised instead.
7. The checkbox tick is the record that a step happened -- don't add a note underneath just to say
   so (e.g. a bare "Confirmed."). Only add a note when it carries actual evidence the tick alone
   doesn't: a queried value, an exact log line, a reading -- something a future reader of the
   checklist would want to see without re-running the test themselves. When there is such a value,
   put it in parentheses at the end of the same list item (wrapped/indented like the rest of the
   item's text), not as a separate paragraph underneath:
   ```markdown
   - [x] **(Claude)** Query `debug_log` for recent `battery` rows and note the live level's natural
         fluctuation range (its lower and higher reading). (Confirmed: flaps between 26% (lower)
         and 27% (higher).)
   ```
8. Under that heading, match the format to the step count: a single action is just the plain
   instruction sentence; multiple actions (e.g. "turn off Bluetooth, then flip the device twice")
   are a numbered list, one action per line, not run together in prose -- so the user can tell at a
   glance how many things they need to do and check them off one at a time.
9. When finishing one scenario/section and moving to the next, say so with a heading as visually
   big as `## Action needed` -- e.g. `## Scenario A complete`, followed by a one-line result (all
   passed, or what was found and fixed) -- before starting the next one. This keeps the user
   oriented on where the run is up to without having to scroll back through the file themselves.
10. When a single confirmation step covers several conditions at once (e.g. "lock badge shown, menu
    reads Unlock, Pause disabled"), phrase it as one combined yes/no ask -- a short lead-in sentence
    plus a numbered list of the conditions -- so the user can answer with one word instead of
    individually addressing each item:
    ```markdown
    Confirm the following with a single yes or no:
    1. The red lock icon is there
    2. The menu says Unlocked
    3. The Pause item is greyed out
    ```
    If the answer is anything other than a clean yes, dig deeper -- ask which part didn't match --
    instead of ticking every box on an ambiguous or partial answer.
11. Watch the user's answers for signs they did something that wasn't asked for (an extra click, a
    setting changed early, an unrequested action mentioned in passing). If that happens, don't just
    press on -- work out what state that leaves things in, tell the user plainly, and give explicit
    instructions to get back to the state the current step actually requires before re-asking for
    confirmation.
12. When a feature has more than one trigger (a menu item vs. a click/gesture on the status icon,
    tested as separate scenarios per point 6), always name which one an action-needed step means --
    "click the Lock **menu item**", not just "click Lock" -- even if it seems obvious from context.
    Don't make the user infer which gesture from which scenario they're currently in.

## Bugs found and fixed

If running a checklist surfaces a real bug and it gets fixed as part of the same session, record it
right under the checklist item that exposed it, as its own heading:

```markdown
- [x] **(You)** Confirm the activity name is blinking red/white.
### Bugs found and fixed
2026-07-15 - The user is a mornon and could not find the app, slapped him upside the head, fixed.
2026-07-18 - The off flash was 0 so it looked like the icon was always red, fixed.
```

One line per bug, dated `YYYY-MM-DD`, terse -- the actual fix is in the commit/diff, so don't
re-explain it here. If the same checklist gets run again later on the same branch and another bug
turns up, add another dated line under the existing heading instead of replacing it -- this builds
a running history of what testing found and fixed on this branch.

This is branch-specific history, not permanent documentation: if the checklist is later run again
on a *different* branch (e.g. this branch got merged to main and a new feature branch was cut from
it), remove any "Bugs found and fixed" sections before that run starts -- they document work that
happened on a branch the new one didn't inherit.

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
