# Running the device tests

Everything in this file is verified against a real, live test run -- not guessed. When you
discover something new, add a **minimal** entry here (the fact/command itself, not the story of how
you found it) in the relevant section below. Put any longer backstory, discovery narrative, or
"here's what happened when..." detail in `README.md` instead -- that file is historical interest
only; this one is what you actually need to operate.

When the user asks to run the device tests, work through the on-device checklists under `Tests/` --
**not** `swift test` (the hermetic unit suite, run separately, no device). Two phases, in order:

1. **Bench** (`Tests/Bench/<NN>-*-checklist.md`, numeric order) -- entirely Claude-driven. No actor
   labels; every step is Claude's.
2. **Interactive** (`Tests/Interactive/<NN>-*-checklist.md`, numeric order) -- steps needing a
   person: a physical cube action (facet flip, double-tap), a sustained press-and-hold mouse
   gesture, a status-item gesture unverified via script, or multiple elements needing to be
   confirmed changing in lockstep with each other (a single or even double screenshot doesn't
   establish synchrony -- see "Screenshot-based visual confirmation" below). Uses `(Claude)`/`(You)`
   labels.

Each folder's own `README.md` describes just that suite.

## Rules

- Finish the entire Bench phase before starting Interactive.
- Each numbered checklist has a file in both folders. A side with no work is a stub: `Nothing
  needed` (no checkboxes).
- Go top to bottom, in order -- later steps depend on state earlier ones establish.

## File naming

- `<NN>-<feature>-checklist.md`, numbered by run order (broader/foundational before
  narrower/independent), not creation order. Same number in both folders.
- Neither folder's `README.md` nor this `CLAUDE.md` is a checklist -- CI never scans them.
- To insert one earlier: rename every file numbered >= the target position up by one (`git mv`,
  highest number first, so no rename overwrites another), add the new file at that number in both
  folders (a real checklist on the side with work, a stub on the side without), then grep for and
  fix any references to the old numbers.

## Format

- `Tests/Bench/`: no actor label, one plain instruction per line.
- `Tests/Interactive/`: `**(Claude)**` (DB/file/command) or `**(You)**` (needs a person) prefix on
  every item. Single ordered sequence, not grouped by actor -- order matters (e.g. "note the event
  number" before "flip the device").

## Driving the app directly

- **Build**: `scripts/run.sh` (`mint run stackotter/swift-bundler@main run TimeFlip`) builds and
  launches in one step, blocking in the foreground -- background it and poll the log for `"Build of
  product"`/`"error:"`. Bundle path once built:
  `.build/bundler/apps/TimeFlip/TimeFlip.app/Contents/MacOS/TimeFlip`.
- **Launch for a Claude-driven step**: invoke that binary directly, not `scripts/run.sh` again --
  it inherits the shell's env vars (needed for a debug hook like `TF_DEBUG_OPEN_SETTINGS`);
  `scripts/run.sh` does not reliably pass them through.
- **Quit**: `osascript -e 'tell application "TimeFlip" to quit'`. Never `pkill`/`kill` for an actual
  test step -- it skips `applicationShouldTerminate`/`applicationWillTerminate` (e.g. the
  `pause_on_lock`-on-quit behavior never fires). `pkill` is fine only as last-resort cleanup when
  there's nothing to assert about the shutdown itself.
- **Confirm reconnect**: query `debug_log` for a fresh `TimeFlip`-tagged `"Login accepted,
  code=0x02"` row -- don't ask the user.
  ```
  sqlite3 ~/Library/Application\ Support/TimeFlip/appdata.sqlite \
    "SELECT logged_at, message FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Login accepted%' ORDER BY debug_log_id DESC LIMIT 1;"
  ```
- **Accessibility permission** (separate from Screen Recording) must be granted to the calling app
  -- trace it via `ps -o ppid=,comm= -p <pid>` up the process tree from the current shell -- under
  System Settings -> Privacy & Security -> Accessibility (not the top-level "Accessibility"
  sidebar item, which is unrelated accessibility-*features* settings), then that app fully
  quit/reopened. Canary check -- a shallow System Events query succeeding is *not* sufficient proof:
  ```
  osascript -e 'tell application "System Events" to tell process "Finder" to get name of every menu bar item of menu bar 1'
  ```
  A real result (not a `"not allowed assistive access" (-1719)` error) confirms it works.
- **Status-item menu** (Lock/Unlock, Pause/Resume, Preferences, Quit): click to open, then click the
  named item, in the same `tell` block (opening and addressing the menu in one line without a
  separate `click` first does not work):
  ```applescript
  tell application "System Events"
      tell process "TimeFlip"
          tell menu bar item 1 of menu bar 2
              click
              delay 0.5
              click menu item "Unlock" of menu 1
          end tell
      end tell
  end tell
  ```
  Read item names first (`name of every menu item of menu 1`) to check current state before
  deciding what to click. `key code 53` (Escape) dismisses without acting, in the same block. The
  status item's single/double-click-right-half gesture (`MenuBarController.swift`) is a genuine
  screen-position hit-test against a real `NSEvent.locationInWindow`, not a menu action --
  `tell application "System Events" to click at {x, y}` at the status item's right-half screen
  coordinates (from its `position`/`size`) does **not** trigger it (confirmed no `debug_log`/
  `device_events` change resulted); this gesture stays `(You)` in `Tests/Interactive/`, not a
  capability gap worth re-attempting the same way.
- **Preferences window** (open via the status-item menu's "Preferences..."):
  - Switch tabs: `click radio button <N> of radio group 1 of group 1 of toolbar 1 of window
    "TimeFlip Settings"` (`N` = 1/2/3 for Device/Facets/Report). A radio button's `title` is
    `missing value` -- use `description` to identify which is which.
  - Read any label/value directly via accessibility (`static text`/a control's `value`) -- exact
    string, no screenshot needed. Locate a specific element by dumping `entire contents` of the
    window first and reading off its `group`/`scroll area` nesting -- indices shift depending on
    which tab/disclosure groups are expanded, so re-derive the path each time rather than hardcoding
    one from a prior session.
  - Type into a text field: focus it, `keystroke "a" using {command down}` (select all), type the
    value, `keystroke tab` to commit.
  - Buttons/checkboxes/sliders/dialogs use the same mechanism (`click button "..."`, `set value of
    checkbox ... to true`) but aren't all individually verified -- confirm via `debug_log`/DB
    evidence the first time each is actually used.
  - Screenshots are needed only for what SwiftUI's default accessibility doesn't decompose into
    separate elements: the status item's own custom-drawn icon/badge (one rendered image), and
    color/animation (not a queryable AX attribute).
- Any script-driven click still mutates real app/device state -- treat it exactly like a human
  click: run against the test database (below) except for narrow discovery work, and follow the
  root `CLAUDE.md`'s live-app-interaction rule (heads-up before, all-clear after). **A factory
  reset** (`01-reset-device-checklist.md`) is irreversible on real hardware -- pause and get the
  user's explicit go-ahead immediately before that specific click, every time, even though it's
  otherwise just another scripted step.

### Screenshot-based visual confirmation

For a **static** state (badge/icon presence, text, a field's value) that isn't otherwise
accessibility-readable (prefer the accessibility read above when it applies), a `(Claude)`
screenshot-and-inspect step replaces asking the user, in `Tests/Interactive/`:
```markdown
- [ ] **(You)** Click the "Lock" menu item.
- [ ] **(Claude)** Screenshot the menu bar status item; confirm the red lock badge is visible.
```
The triggering action stays `(You)` if it genuinely needs a human's hands. If reading it needs a
dropdown open, "open it" stays `(You)` -- leave it open until told the screenshot is captured,
rather than reading the text out loud.

**Time-based checks are not automatically `(You)`** -- a *single* frozen frame can't show change
over time, but two or more screenshots taken more than a second apart can, and often replace asking
the user just as well:
- A value that should simply be increasing (e.g. a duration ticking up): prefer a DB-based check
  instead if one exists (see the `device_events`/`duration_seconds` pattern used in
  `02-history-refresh-checklist.md` and `04-lock-and-pause-on-lock-checklist.md`'s Bench Scenario
  C) -- it's more direct than reading rendered text at all. Fall back to two time-spaced
  screenshots (or two accessibility text reads) only when there's no DB proxy for what's actually
  being confirmed (e.g. confirming the *rendering itself* updates, not just the underlying data).
- A single element blinking between two states: two screenshots roughly half a blink-interval
  apart, confirmed to show different colors, is enough to prove it's animating at all.
- **Multiple elements blinking in lockstep** (e.g. `03-battery-low-indicator-checklist.md`'s three
  elements) is a stronger claim than "it's animating" -- it requires them to change at the *same
  moment*, which two screenshots can't establish (both could easily show "changed" despite having
  flipped at different times within the gap). This needs several screenshots spaced closely
  relative to the blink interval (enough to see multiple full cycles), comparing all elements at
  each sample -- more samples than the simple cases above, but still not fundamentally
  human-only. Not yet actually converted this way in any checklist here -- if you do, verify it
  first and update this entry and the checklist together, the same as everything else in this file.

Launching the app for any of this still needs the root `CLAUDE.md`'s heads-up/wait/all-clear
ritual.

### Presenting durations

Convert `duration_seconds` to `mm:ss` when asking the user to compare it on screen -- that's the
menu bar's own display format. Keep the `display_seconds` setting enabled during testing so the
menu bar shows seconds, not just minutes. To ask whether the device is running vs. paused, ask "is
the time increasing?" over a couple of seconds of watching, not "is it paused?".

### Reading debug output

Use `debug_log`, not a live terminal transcript (no reliable way to attach to one):
```
sqlite3 ~/Library/Application\ Support/TimeFlip/appdata.sqlite \
  "SELECT tag, message, logged_at FROM debug_log ORDER BY debug_log_id DESC LIMIT 20;"
```
`tag` matches the bracketed prefix from `DeveloperMode.DebugTag` (`history`, `battery`, `TimeFlip`,
`dev-check`, ...); `logged_at` lets you correlate against when a step happened.

### Switching to the test database before testing

`~/Library/Application Support/TimeFlip/appdata.sqlite` is a symlink to `production.sqlite` or
`test.sqlite`, only re-read at the app's next launch:
```
scripts/use-test-database.sh        # appdata.sqlite -> test.sqlite (creates fresh if missing)
scripts/use-production-database.sh  # appdata.sqlite -> production.sqlite
```
Every session: quit the app, run the test-database script, start the app, then query `db_type` as
the very first Setup step, every time -- it must read `{"type":"test"}`. If it reads
`{"type":"production"}`, **stop immediately** -- don't run anything that would mutate data. When
done: quit, run the production-database script, start the app again. `test.sqlite` is left in place
between sessions (not deleted), so accumulated state carries forward.

### Suppressing incidental physical double-taps during a test session

The device pauses itself on any physical double-tap -- unconditional firmware behavior; no BLE
command disables it outright. The only lever is accelerometer sensitivity
(`clickThreshold`/`limit`/`latency`/`window`, each `UInt8` 0-255) via the app's Double Tap section
in Settings -- not the `double_tap_settings` DB row (nothing reads that yet, it's dead seed data).
This is a physical register on the device, unaffected by which database is active, so it needs its
own snapshot/restore separate from the database switch above:

1. Expand Advanced -> Double-tap sensitivity -> "Sync from device"; record the four values in
   `Tests/Bench/device_register_snapshot.json` (gitignored) under a timestamp-keyed
   `double_tap_params_as_at` object. One snapshot per session, before the first change; restore
   from the **latest** entry once done.
2. Set `window` to `0` and Apply -- guarantees no double-tap can complete (stronger than raising
   `clickThreshold`, which only requires more force). Leave the other three alone.
3. Run the session's checklist(s) as normal.
4. Once done, restore the original values from step 1 and Apply again.

If a scenario specifically tests double-tap-to-pause behavior, temporarily restore real sensitivity
for just that scenario, then re-suppress before continuing.

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

## Bugs found and fixed

Record a real bug found and fixed mid-session right under the item that exposed it:
```markdown
- [x] **(You)** Confirm the activity name is blinking red/white.
### Bugs found and fixed
2026-07-18 - The off flash was 0 so it looked like the icon was always red, fixed.
```
One line per bug, dated `YYYY-MM-DD`, terse -- the actual fix is in the commit/diff, don't
re-explain it here. Append further bugs found on later runs of the same checklist on the same
branch under the existing heading, rather than replacing it. Remove this section entirely if the
checklist runs again on a *different* branch -- it's branch-specific history, not permanent
documentation.

## Restarting

To restart a checklist: clear every box in that file back to `- [ ]` (don't delete or reorder the
steps) and start again from the top.

## CI enforcement

`scripts/check_interactive_checklists.sh` (wired into `.github/workflows/tests.yml`) fails the
build if any `<feature>-checklist.md` under either `Tests/Bench/` or `Tests/Interactive/` has an
unchecked (`- [ ]`) item. A PR touching either folder must have it fully ticked before merging.
