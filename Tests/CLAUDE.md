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

## Scenario preconditions

Every `## Scenario`/named section states the device/app state it needs right after its heading, as
a `**Preconditions:**` line (e.g. "device connected, unlocked, unpaused, `pause_on_lock=true`"),
followed by a step that checks the current state against it and resolves any mismatch before the
scenario's real steps begin -- don't assume state a previous scenario or session left behind is
still true, even within the same file. A single checkbox combining check-and-fix is fine when the
fix is simple (e.g. "confirm X; if not, do Y"); point back at an existing resolution step elsewhere
in the same file instead of duplicating it when one already exists (e.g. Setup's own lock/pause
resolution).

This matters because a checklist can be restarted mid-way (see "Restarting" below), run standalone
out of its usual order, or simply re-run much later after unrelated state drifted between sessions
-- confirmed live: `Interactive/04` found the device locked *and* paused at the very start of a run,
left over from a previous session's quit-while-`pause_on_lock`-enabled, not anything that session's
own checklist had done. A scenario that silently assumes a prior scenario's ending state is still
true will misreport a real bug as a broken precondition (or vice versa) the next time it's run.

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
  deciding what to click. `key code 53` (Escape) dismisses without acting, in the same block.
  **Always finish an open menu in the same block** -- either click an item or send Escape. If you
  read the item names in one `osascript` call and then click in a *separate* call, the menu is left
  open, and the second call's `click menu bar item ... / click menu item ...` collides with the
  already-open menu and **hangs** (confirmed live: a ~2-minute System Events stall, misread at first
  as an Accessibility problem -- it was not; the canary passes and a real permission denial errors
  instantly with `-1719`, it doesn't hang). So either do read-then-click in one block, or dismiss
  with Escape before a fresh open -- never re-`click` a menu that's still open. The
  status item's single/double-click-right-half gesture (`MenuBarController.swift`) is a genuine
  screen-position hit-test against a real `NSEvent.locationInWindow`, not a menu action --
  `tell application "System Events" to click at {x, y}` at the status item's right-half screen
  coordinates (from its `position`/`size`) does **not** trigger it (confirmed no `debug_log`/
  `device_event` change resulted); this gesture stays `(You)` in `Tests/Interactive/`, not a
  capability gap worth re-attempting the same way.
- **Preferences window** (open via the status-item menu's "Preferences..."):
  - Switch tabs: `click radio button <N> of radio group 1 of group 1 of toolbar 1 of window
    "TimeFlip Settings"` (`N` = 1/2/3 for Device/Facets/Report). A radio button's `title` is
    `missing value` -- use `description` to identify which is which.
  - The auto-pause field's up/down stepper arrows (custom `Image` views with
    `onLongPressGesture(minimumDuration: 0)`, not real `AXButton`/`NSStepper` controls) do not
    respond to a synthetic click at all -- neither `tell application "System Events" to click at
    {x, y}` at their screen coordinates nor the `click`/AX-press action on the element reference
    registers any change (confirmed live: repeated synthetic clicks left `auto_pause_minutes`
    completely unchanged), while a real physical click reliably moves the value by exactly 1. Same
    class of limitation as the status-item gesture above -- treat as `(You)` in
    `Tests/Interactive/`, not a bug to chase or a capability gap worth re-attempting the same way.
  - Read any label/value directly via accessibility (`static text`/a control's `value`) -- exact
    string, no screenshot needed. Locate a specific element by dumping `entire contents` of the
    window first and reading off its `group`/`scroll area` nesting -- indices shift depending on
    which tab/disclosure groups are expanded, so re-derive the path each time rather than hardcoding
    one from a prior session.
  - Type into a text field: focus it, `keystroke "a" using {command down}` (select all), type the
    value, `keystroke tab` to commit. The value actually commits live on every keystroke, not only
    on `tab` -- confirmed live by querying the DB immediately after a `keystroke` with no `tab` at
    all and seeing it already updated. `tab` only shifts focus off the field (useful to finalize
    display formatting or move on), and doing so **breaks** a rapid multi-value sequence in the
    same field -- a `keystroke tab` between edits sends the next `cmd+A`/value to whatever control
    focus landed on instead, not back to the same field. For back-to-back edits of the same field
    (e.g. testing a debounce), omit `tab` between them and only send it (if at all) after the last
    one. `keystroke` always goes to the frontmost application
    regardless of which process a `tell` block targets -- clicking the field via its UI element
    reference does not guarantee TimeFlip is actually frontmost (confirmed live: a stray `cmd+A`/
    `1`/`tab` sequence landed in VS Code instead, mid-`05-auto-pause-arrow-stepper-checklist.md`,
    with TimeFlip's Preferences window visibly on screen the whole time). Run
    `tell application "TimeFlip" to activate` immediately before the click, then confirm with
    `tell application "System Events" to name of first process whose frontmost is true` -- do this
    before every keystroke sequence, not just the first. Even with TimeFlip frontmost, `click e` on
    the field alone did not actually set keyboard focus (`focused of e` read back `false`
    immediately after) -- follow the click with an explicit `set focused of e to true` and confirm
    it reads back `true` before sending keystrokes, in the same `osascript` invocation as the click
    (a stale UI element reference doesn't carry across separate invocations).
  - Buttons/checkboxes/sliders/dialogs use the same mechanism (`click button "..."`, `set value of
    checkbox ... to true`) but aren't all individually verified -- confirm via `debug_log`/DB
    evidence the first time each is actually used.
  - A `DisclosureGroup`'s row shows up as role `AXDisclosureTriangle` ("UI element", not `button`
    or `static text`), with no label text readable off it directly via `description`/`title` --
    identify it by position/ordering among its siblings instead, and `click` it the same as any
    other element to expand/collapse.
  - Screenshots are needed only for what SwiftUI's default accessibility doesn't decompose into
    separate elements: the status item's own custom-drawn icon/badge (one rendered image), and
    color/animation (not a queryable AX attribute).
- Any script-driven click still mutates real app/device state -- treat it exactly like a human
  click: run against the test database (below) except for narrow discovery work, and follow the
  root `CLAUDE.md`'s live-app-interaction rule (heads-up before, all-clear after). **A factory
  reset** (`01-reset-device-checklist.md`) is irreversible on real hardware, but does **not** need
  a live pause-and-confirm before the click -- the "Switching to the test database" pre-flight
  below (sync real device history to `production.sqlite` first, only then switch to test) already
  guarantees nothing real is at risk, so it's safe to run unattended like everything else in
  Bench. Only pause if that pre-flight wasn't actually done first this session.
- A factory reset intentionally ends with the device **forgotten / "Not paired"**, not reconnected
  (changed on `bugfix/resetDevice`). Flow: `TimeFlipBLEDevice.factoryReset()` just *sends* the 0xFF
  command -- the device gives no usable ack for it (the command-result read comes back stale, e.g. a
  leftover `17 3A ...` double-tap response) and reboots. The app then drops the connection, and the
  reconnect path re-logs-in with `TimeFlipConstants.defaultPassword`; a successful default-password
  login is the confirmation the wipe took (confirmed via os_log / `debug_log` "Factory reset
  confirmed"), and is deliberately **not** treated as a pairing -- it forgets the device into the
  pristine never-paired state. Expect the UI to read **"Resetting..." -> "Not paired"** (Name /
  Connection / Battery all greyed), *not* "Reconnecting..." -> "Connected", and to require a fresh
  Scan/re-pair afterward. Watch for: on the first reconnect the device can still accept the OLD
  password briefly (reset not yet applied) -- the app logs "not yet confirmed ... retrying" and waits
  for a later reconnect where only the default works; confirmation is gated on the default password
  specifically, so don't expect it on the first successful login. The default-password fallback in
  `ApplicationDelegate.startDeviceEvents`'s login guard still exists and also covers an out-of-band
  reset done by other means.
- The device correctly rejects an arbitrary wrong password (confirmed live: `login(password:
  "999999")` against an authenticated session got an explicit rejection, raw commandResult
  `0x01`, not silently accepted) -- no known security concern there.

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
  instead if one exists (see the `device_event`/`duration_seconds` pattern used in
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

### Detecting a physical action instead of asking "are you done?"

For a `(You)` physical action that produces a verifiable DB/`debug_log` change (a facet flip
creating a new `device_event` row, a double-tap logging to `device_notification`), poll for that
change instead of asking the user to confirm they did it -- e.g. after asking for a flip, loop
`SELECT device_event_id, event_number, device_face ... ORDER BY device_event_id DESC LIMIT 1;`
every couple of seconds until the row changes. Only ask for explicit confirmation when the action
has no detectable side effect at all (or the detectable side effect is ambiguous about which
specific action produced it).

### Reading debug output

Use `debug_log`, not a live terminal transcript (no reliable way to attach to one):
```
sqlite3 ~/Library/Application\ Support/TimeFlip/appdata.sqlite \
  "SELECT tag, message, logged_at FROM debug_log ORDER BY debug_log_id DESC LIMIT 20;"
```
`tag` matches the bracketed prefix from `DeveloperMode.DebugTag` (`history`, `battery`, `TimeFlip`,
`dev-check`, ...); `logged_at` lets you correlate against when a step happened.

**After a factory reset, query `device_event` by `device_event_id DESC`, not
`MAX(event_number)`.** `event_number` is the device's own counter and isn't unique across a reset
(it restarts from 1), and old pre-reset rows are never deleted -- so `MAX(event_number)` returns
whichever is bigger, pre- or post-reset, silently hiding the real current state.
`device_event_id` is the local auto-increment PK and is always strictly increasing regardless of
what the device's own counter is doing, so `ORDER BY device_event_id DESC LIMIT 1` is the only
reliable way to find the actual latest row.

### Switching to the test database before testing

`~/Library/Application Support/TimeFlip/appdata.sqlite` is a symlink to `production.sqlite` or
`test.sqlite`, only re-read at the app's next launch:
```
scripts/use-test-database.sh        # appdata.sqlite -> test.sqlite (creates fresh if missing)
scripts/use-production-database.sh  # appdata.sqlite -> production.sqlite
```
**Pre-flight, before switching, every session:** confirm `db_type` currently reads
`{"type":"production"}`, confirm the device is connected, and wait until a `history` fetch
completes (`debug_log`, `trigger=startup`/`periodic` followed by a `DB refreshed` or stream-fetch
line) so any real, not-yet-synced device history lands in `production.sqlite` first. Only then
quit and switch to test. This is what makes it safe to run anything in these checklists --
including `01-reset-device-checklist.md`'s factory reset -- **without pausing to confirm with the
user first**: real timings are already captured before the device's own state is touched, so there
is nothing left to lose. (The `CLAUDE.md`/checklist text elsewhere may still say to pause and
confirm before the reset -- that's superseded by this paragraph; update those in place if you land
here from a link.)

Then: quit the app, run the test-database script, start the app, then query `db_type` as the very
first Setup step, every time -- it must read `{"type":"test"}`. If it reads `{"type":"production"}`,
**stop immediately** -- don't run anything that would mutate data. When done: quit, run the
production-database script, start the app again. `test.sqlite` is left in place between sessions
(not deleted), so accumulated state carries forward.

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
never for changes made during normal development (like the reset-flow work that produced this very
rule). If no bug surfaced during a test run, there's no section.

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

To restart a checklist: clear every box in that file back to `- [ ]` (don't delete or reorder the
steps) and start again from the top.

## CI enforcement

`scripts/check_interactive_checklists.sh` (wired into `.github/workflows/tests.yml`) fails the
build if any `<feature>-checklist.md` under either `Tests/Bench/` or `Tests/Interactive/` has an
unchecked (`- [ ]`) item. A PR touching either folder must have it fully ticked before merging.
