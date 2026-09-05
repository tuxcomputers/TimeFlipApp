# Project Conventions

## Read this entire file before taking any actions

Read this whole CLAUDE.md, top to bottom, before doing anything in response to a request. This
must remain the first rule in this file. (Global rule: this rule is the first rule in every
CLAUDE.md; if you read a CLAUDE.md and it is missing, add it.)

## The database is the source of truth, and is read at the point of use

**If a value lives in the database, read it from the database at the moment it is needed, every
time.** Not loaded at startup and remembered, not held in an in-memory model the app then trusts,
not "reflected in the database" after the fact. The database is not a backing store for what the app
thinks; it is what is true, and the app is a view onto it.

This applies every single time it can be applied. It is the default for all new code, not a
consideration to weigh against convenience.

What it means concretely:

- **Startup reads only what starting up needs**, and nothing else. It is not an opportunity to load
  everything into memory while the disk is warm.
- **Opening a window reads that window's values then.** Open Settings and the Device tab's
  auto-pause value comes from the database. Change it, close the window, open it again: it is read
  from the database again. The second open is not allowed to show what the first one loaded.
- **An open Settings window is the source of truth for the settings it shows, and only until it
  closes.** This is the one place a value is held rather than re-read, and it is held under conditions
  that keep the two copies from parting company:

  1. **Opening the window reads every tab's settings**, in one go, not the tab that happens to be on
     show. From that moment what the window holds is the answer.
  2. **A changed field is written straight through, and the write is checked by reading it back.** Not
     by trusting the statement: a write that reports success and did not happen is exactly the
     disagreement this rule exists to prevent.
  3. **The window adopts a change only once the table has it.** A refused write puts the row back to
     what the window holds and **says so in an alert** -- a field still showing what was typed while
     the table holds something else is the two-answers problem itself.
  4. **A value the table has gained meanwhile is overwritten.** If something else changes a row while
     this window is open, this write wins. The window read the setting when it opened and has been the
     answer since; merging a change nobody in this window made would mean a control that quietly does
     something other than what it says.
  5. **Closing the window ends it.** The next open reads the table again, so an external change made
     while the window was shut is simply what the next open finds.

  What this licence does **not** cover: anything the app itself changes behind the window keeps being
  read on its own terms -- the clock in the Timing column ticks, a pause from the menu bar shows up,
  and an edit that changes *which* rows belong in a list (retiring a category) re-reads the list. A
  list is not a setting: which rows belong in it is a different question from what a value is.

  Nor does it license a read-back per keystroke. A value being typed into is not re-read underneath
  whoever is typing: that clamps "1" on the way to "15", and rebuilding a row to show a value it is
  already showing takes the field out from under them.
- **A value used part-way through a sequence is read at that point in the sequence.** During quit,
  whether locking the cube pauses it is read when the quit sequence reaches the step that needs it
  -- not read at launch, not read at the start of the quit, and not passed down through the call
  chain from earlier.
- **After a write, what the app shows comes from reading it back**, not from an in-memory copy
  updated alongside the write. Updating both is exactly the thing this rule exists to forbid. The one
  place a copy is updated instead is an open Settings window (above), and there the read-back is what
  decides whether it may be.
- **Nothing accumulates a private copy of a table.** If a list is needed twice, it is read twice.

The reason is that two copies of one fact can disagree, and when they do, nothing fails. The app
simply acts on the wrong one, and no test notices because both copies were written by the same code
that believes them. This codebase has already paid for that: manual mode was a published flag
sitting beside the connection status -- two answers to one question -- and the disagreement that
mattered was a manual session running while the status still said "connected" (see the manual mode
section of `docs/TODO-features-under-development.md`). Deriving the second answer from the first
removed the possibility rather than the symptom.

### The reference tables are the standing exception

`icon` (`database/004_icon.sql`), `colour` (`005_colour.sql`) and `event_type` (`001_event_type.sql`)
are **reference tables**: seeded by the DDL, never written by the app, and fixed for the life of a
launch. They may be read into memory at startup and referenced from there for as long as the app runs.

This is not a hole in the rule, it is the rule's own reasoning applied: two copies of a fact are only
dangerous because one can change without the other, and nothing can change these. A held copy of the
`icon` table cannot go stale, because nothing in the app writes an icon.

It covers those tables and no others. In particular it does **not** extend to `setting`, `category`,
`face`, or anything holding recorded time -- all of which the app or the user edits while it runs, which
is exactly the case the rule exists for.

### Anywhere else

Where the rule genuinely cannot be followed, **say so in a comment at that exact place**, naming what
makes the read impossible and what would invalidate the value being held instead. Two examples of a
real exception: a value read once because it cannot change while the process runs (the `db_type` row is
written when the database file is created and never again), and a read that would otherwise happen on a
repeating timer. Neither is a licence to cache by default -- they are the cases where the comment has to
earn it, and "it would be a read per tick" is a reason to be explicit, not a reason to say nothing.

## What a state is called is settled in `docs/state-reference.md`

**Before writing any branch, look the fact up in `docs/state-reference.md` and use the name it lists.** That
is the register of every state this app branches on: what the fact is, what values it can take, where the
truth for it lives, and the one name it goes by. A state that can only be true or false is `is<Name>`; one
that can be more than that is `<name>State`. If the fact is not in there, add it in the same change that adds
the branch.

`docs/state-audit.md` is its companion and a different thing: the snapshot of what the code calls these
things today, kept deliberately unedited. Read it to find out what a fact is *currently* spelled where you
are working. The two disagreeing is the record of what is left to rename, and their section numbers match.

This is the rule above pointed at the app itself. That one keeps one answer in the database; this keeps one
*question* in the code. Two names for one fact are the same hazard as two copies of one value: they get asked
in different places, one gets taught something the other does not, and nothing fails.

Already paid for, and the audit names each one:

- `isLocked` is the cube being frozen in one file and a face refusing reassignment in another.
- `isPaused` is the cube's pause byte in `CubeLock`, and "the figure is not moving" in
  `DailyLimitEnforcement`, whose own doc comment still describes the first.
- Whether the daily limit is spent is decided by four separate expressions in four files. Two of them did not
  exist until a spent budget was bypassed on a live cube on 2026-08-27, because the other two ask about the
  app's own clock and a cube leaves that `.idle` however busy it is.

So check the collisions section before reusing a name, and the alias table before inventing one. A branch that
coins a synonym is the next row in that table.

## The previous implementation is in the git history, not in the tree

The app was rebuilt from the ground up, and the previous implementation used to sit in `Archive/`. It was
deleted once the rebuild was finished. **It is not gone**: it is in the history at `3ee3b47`, the commit
before "Archive the app sources ahead of the rebuild", and `scripts/old.sh --rebuild` makes a worktree at
that commit and builds it. That is also the only way to run it.

**Everything it knew that is still load-bearing has been brought forward.** That was the condition of
deleting it, and it is why the old tree is no longer the first place to look:

- Its **measurements of the hardware** are in `docs/timeflip2-firmware-observations.md`, with
  `docs/timeflip2-firmware-evidence.sqlite` holding the debug rows behind each one.
- Its **test techniques** are in `Tests/Methods.md`, renumbered and rewritten against this app's own
  accessibility tree.
- Its **reasoning** is quoted where it is acted on: a comment that says the previous app did something and
  why is the record of it, and those comments name its types rather than its file paths.

So do not go looking for it by default. Read it when a specific question is worth a worktree -- how the old
driver actually handled a frame, what its numbers were -- and when you do, treat it as prior art written by
somebody else: reading it is not permission to import it, and "the old code did X" is not a reason for
anything on its own. When it wins, it wins because the reason survives inspection today.

**A fact it recorded from a real device or a real accessibility tree still outranks reasoning about what
should happen.** That is why those facts were moved rather than dropped, and why anything else found in
there that turns out to matter gets written into `docs/` or `Tests/Methods.md` in the same change -- not
left in a commit nobody will think to check.

## A tab's content spans the width of the window

**Every panel, list and section on every Settings tab runs the full width of the window**, inset by the
tab's own padding and nothing more. Not sized to the widest control in it, and not left hanging with
empty space to the right of it. This is how the previous app drew every tab it had (`image/preferences-device.png`,
and the App tab's grouped form), and it is what makes the tabs read as one window rather than as pages
that each chose their own width.

It applies to whatever a tab grows, and it applies as the window is resized: a panel that spans at one
size and stops short at another is the same fault seen later.

The trap that produces the wrong version, because it has already happened once: **a pane must keep its
autoresizing frame.** `SettingsWindowController.makePane` hands each pane `autoresizingMask = [.width, .height]`
and the tab view resizes it to the content rect from there, so a pane that sets
`translatesAutoresizingMaskIntoConstraints = false` on *itself* throws that away and is then sized by
its own contents -- which looks like a panel that stops short of the right-hand edge, with nothing in the
constraints to explain it. Set it on the subviews, never on the pane.

## A collapsible group opens on its whole heading, not just its triangle

**Anywhere in this app that a section folds away, the entire heading line is the target**: the triangle, the
words beside it, and the space after them to the end of the row. Not the triangle alone.

A triangle is a small target for a gesture the heading is obviously about, and every other list on this
platform opens on its title too, so a heading that ignores a click is a control that looks broken rather than
one being precise. `PanelSection` is the pattern: a borderless button spanning the row sits *behind* the
triangle and the label, so the triangle still draws itself and a click lands in one place wherever in the line
it falls.

This applies to every collapsible group the app grows, not only the Categories tab's two.

**Its heading sits on the group's own panel, as the first row of it, and folding closes the panel around the
heading.** The archive drew each one as a `Section` of a grouped form, where the disclosure label is a row inside
the box, and a heading floating above a panel it folds reads as a caption rather than as the control it is. Two
things follow, both of which have already gone wrong once: whatever is inside the panel must not draw a panel of
its own (`quaternarySystemFill` is translucent, so two of them stack and the contents come out darker than the
heading), and hiding the contents is not folding them (Auto Layout ignores `isHidden`, so the hidden height stays
behind unless the section's bottom edge moves with it).

This is about *collapsible* groups. A plain section heading, like the Faces tab's "Timing" and "Categories", stays
above its panel: it names the panel, it does not operate it. That tab is the only one left with any, the Categories,
App and Device tabs all having sections that fold.

**A section that gains a fold moves its heading onto the panel**, rather than keeping the caption it had and putting a
triangle on it. The App tab's two sections and the Device tab's three were plain headings above panels until they
folded, and the whole of making each of them fold was handing it to `PanelSection`: the heading became the panel's
first row and the panel closes around it. A folding heading left floating above its panel is the caption case wearing
a triangle, which is the shape this rule exists to rule out.

**Folds nest, and each level keeps its own default.** The Device tab has both kinds at once: *More* is a `DisclosureRow`
inside a `TimeFlip` section that is a `PanelSection`, and their defaults are opposite -- the section opens, *More* does not. The
window's walk goes on into a section it has just folded, so both come back to their own answer; a reset that put
everything one way would be exactly as wrong as one that put nothing back.

**A second tab overrides nothing, and proves it on screen.** Every number a Settings tab is drawn from lives in
`SettingsMetrics`, and `rowHeight` is the point of reference: change it and all three tabs move together, which is
what it is for. The Categories tab is where those numbers came from, being the one that was right.

`PanelSection.Metrics` used to be overridden by the App and Device tabs, to a content inset of nothing, because their
rows ran the panel's full width and held their own labels off the edge so that the hairlines between rows ended where
the archive's did. **There are no hairlines anywhere now**: a gap of `rowSpacing` is what divides one row from the
next, which is what the Categories tab has always done, so that exception buys nothing and one inset puts a row at the
same x on all three tabs.

The reason this is a rule at all is what happened without it. Both tabs were measured against the Categories tab by
eye, at different times, and both landed somewhere else: the App tab at a 46pt row pitch against that tab's 32, its
`rowPadding` of 11 adding itself twice on top of a 24pt field; the Device tab at exactly the right row height with no
gap at all under it, which reads as a tighter list rather than the same one. Neither was visible in the source, where
both files looked like they had been careful. **So take a screenshot of all three before changing any of it**, and
measure the pitch rather than trusting the numbers -- `SettingsMetricsTests` does exactly that, and it fails if any
tab grows a number of its own again.

**Anything drawn from a fold follows the state, not the gesture.** `onToggle` fires only when somebody presses a
heading, because `restoreDefaultState` is deliberately silent; `onExpandedChanged` fires on every path. A view that
sits outside the panel and so cannot fold with it -- the App tab's Google footnote is the one -- has to hang off the
second, or it ends up showing under a folded section the moment the window resets the folds.

**Where a group has no panel of its own, its heading is a row of the list it belongs to** and there is nothing to sit
on top of. The Report tab's categories are that case: each one is a line of the totals list, carrying a swatch, a name
and a figure, with its entries folded away underneath. What survives from the paragraph above is the part that is
really the rule -- the whole heading line is the target, and folding takes the space back rather than merely hiding
what was in it.

## Requests that affect real device behavior

- Before implementing a request that changes how the physical TimeFlip device behaves (e.g.
  "set auto-pause to 10 seconds"), check it against what the device's BLE protocol actually
  supports (see `docs/TimeFlip2 BLE Protocol v4.3.md`/`docs/timeflip.md`) -- granularity,
  ranges, whether a value has any read-back, etc.
- If the request isn't achievable as literally stated (e.g. the device only supports whole-minute
  auto-pause delays, so "10 seconds" can't make it fire in 10 seconds), say so explicitly and
  explain the actual constraint before implementing anything -- don't silently build something
  that looks like it does what was asked but can't actually behave that way on real hardware.

## A command the device can be asked about is read back before it is believed

**Every command that has a read-back is sent and then read back, and only what the read says is treated as
what happened.** Not the write landing, not the vendor's acknowledgement, and not what the app asked for: the
device's own answer to a question about its state.

This is the device-side half of the database rule at the top of this file. An in-memory copy of what the app
last sent is exactly the second answer that rule exists to forbid, and the cube is freer to disagree with it
than a table is -- it drops its password on every disconnect, it reboots, its batteries come out, and a user
can double-tap it or use the vendor's app behind this one's back.

**What an acknowledgement actually proves, and it is less than it looks.** There are two, and neither is the
state changing. CoreBluetooth's `.withResponse` callback says the bytes reached the device at the ATT layer.
The vendor's own `[cmd, 0x02]` on the command result says the firmware accepted the command. A cube refuses
every command until a PIN has been accepted, and refuses it *after* the write has already succeeded -- so a
command can be acknowledged twice over and still have done nothing at all.

**Which commands can be confirmed is a matrix, not a rule of thumb**, and it is written out in
`docs/timeflip.md` under *Confirming a command actually took effect*. In short:

- **A dedicated read-back**: `0x10` (status: lock, pause, auto-pause), `0x14` (task parameters), `0x17`
  (double-tap registers), `0x07` (device time). Send the command, then send the read, then compare against
  what was asked for. These are the ones this rule is about.
- **No read-back defined**: `0x09` (LED brightness), `0x0A` (blink interval), `0x11` (face colour). The
  vendor spec defines nothing that reads these back, so the write is genuinely all there is. **Say so at the
  call site** rather than leaving a reader to assume the read-back was forgotten.
- **A read impossible by nature**: `0x30` (set password). Confirmation is functional instead -- log in with
  the new PIN and treat only that as proof. `0xFF` (factory reset) is the same shape: the cube reboots
  without writing a fresh command result, so the proof is the cube coming back on the vendor PIN.

**Two measured traps in the `0x10` answer**, both from the archive and both easy to build on top of by
accident:

- **It carries no echoed command byte.** `0x17` answers with `17 3A .. 3B .. 3C .. 3D ..`, which identifies
  itself; `0x10` answers with four bare bytes. The command result characteristic frequently holds the
  *previous* command's reply (finding 2, `docs/timeflip2-firmware-observations.md`), so nothing about a
  `0x10` answer says it is one. The only thing that makes it trustworthy is sequence: read strictly after
  this command's own acknowledgement, and treat anything arriving otherwise as somebody else's.
- **A locked cube reports itself paused whatever its pause byte says.** The archive reads it as
  `paused = locked ? true : data[1] == 0x01`, and `docs/timeflip.md` records the same as "pause (0x01/0x02
  unless locked)". So a pause confirmed *after* a lock proves nothing, and pause must be confirmed before
  the lock is sent.

## Two suites, and only one of them can tell you it works on hardware

**`swift test` is hermetic**: 1632 tests, no window, no radio. A feature can be entirely green there
and broken the moment it runs. **`Tests/Scripted/` is what says it works** -- 32 shell scripts that
drive the real app and read the real database, `00`-`13` needing no cube and `50`-`66` needing one.
`Tests/Scripted/README.md` is how to run them, `Tests/Methods.md` is the shared methods they are
written from, and `Tests/Scripted/last-run.md` is the committed stamp of the last full run.

**Never launch `Tests/Scripted/run.sh` yourself.** It drives the real mouse and keyboard on the
owner's screen and needs a person to turn the cube. Ask, and watch the logs.

The previous suite -- the Bench and Interactive checklists, the setup, and the Python harness that
drove them -- is in the git history and did not come back as it was. Every locator in it addressed the
previous app's accessibility tree, reaching the Settings tabs through a `toolbar 1` this app does not
have. What *did* carry over is here, and is why that history is not the first place to look:

- The **procedure**, which cost real runs to learn and is now the rules in this file and in
  `Tests/Scripted/README.md`: refresh the log baseline before every step; a cross-step wait needs its own
  named baseline; a scenario is the atomic resume unit; an indefinite wait gets no silent grace period;
  poll the database for a physical side effect rather than asking the user to confirm one.
- The **device measurements**, which are facts about the hardware and so still true. They are in
  `docs/timeflip2-firmware-observations.md`, with `docs/timeflip2-firmware-evidence.sqlite` behind them.
- The **test techniques**, renumbered against this app's own tree, in `Tests/Methods.md`.

It came back much smaller, and needs no AI and nothing installed beyond what building the app needs.
The old `locators.py` existed largely because elements were not addressable and steps had to hunt by
position; every element this app builds carries an `AXIdentifier`, and every click it handles writes a
`debug_log` row, so a step is "press by name, then poll for the row". `scripts/ax-press.py`,
`scripts/ax-dump.py`, `scripts/ax-set.py`, `scripts/ax-hold.py`, `scripts/ax-key.py`, `scripts/ax-alert.py`
and `scripts/status-item-click.py` are that whole layer.

**`Tests/Methods.md` is the suite's shared methods, numbered.** Anything learned while checking the app against a running copy of itself goes there
as it is learned -- the command and the fact, not the story -- because a technique rediscovered is a
technique that was written down too late. It already carries the ones that cost the most: what needs a
real mouse event and what does not, why a status item is not in `AXMenuBar`, and the two reasons
`performClick` silently does nothing.

So: write each check as its feature lands, keep it small, and let the harness grow back around what
the first few actually need. That is what happened: `Tests/Scripted/` is 32 scripts now, `00`-`13`
needing no cube and `50`-`66` needing one, and `Tests/Scripted/README.md` is how to run them.

CI cannot run any of it -- no screen, no Keychain, no Google account, no cube -- so
`scripts/check_interactive_checklists.sh` does two things instead. It checks the suite is *runnable*:
every script parses, is executable, declares `EXPECTED_CHECKS`, ends in `finish`, and guards the
database. And it checks somebody actually ran it, from `Tests/Scripted/last-run.md`, which `run.sh`
writes and which has to name this branch, name a commit in its history, report a run that passed with
nothing failed and no script short of the checks it declares, and have been run with a clean tree
against `Sources/`, `Tests/Scripted/` and `database/` as they now stand.

## Ask for the device whenever you need it

- **Any time confirming something needs the physical device, just ask.** Say what you want to
  check and ask me to keep my hands off the keyboard, and I'll clear the way. This is standing
  permission to ask, not permission to launch: the warning-and-all-clear protocol in the next
  section still applies every time.
- Don't leave device-dependent behavior unverified because interrupting me seems expensive. The
  unit suite is hermetic and never touches a radio, so a feature can be entirely green and still
  be broken on hardware. That is not hypothetical: the device rename shipped with every test
  passing and made the cube unreachable on the next launch, because reconnecting is a **scan** and
  nothing in `swift test` scans (2026-08-01, see the Device rename section of
  `docs/TODO-features-under-development.md`).
- So when a change touches how the app finds, connects to, or writes to the device, say plainly
  whether it has been confirmed on hardware. If it hasn't, ask, rather than reporting it as done.

## Running the app interactively for visual verification (screenshots, driving the UI)

- This launches a real window on the user's actual screen -- it is not an isolated/headless
  sandbox. Keystrokes and clicks the user makes while the app has focus can land in it (this has
  actually happened -- see git history around the Settings-window sizing fix).
- Before launching the app for this purpose, post a clear, prominent, impossible-to-miss message
  asking the user to acknowledge and to avoid touching the keyboard/mouse until told the
  verification is finished. Wait for that acknowledgment before launching.
- Once done (or if interrupted), immediately kill the launched process, revert any temporary
  debug-only scaffolding added purely to drive the verification (e.g. an env-var-gated hook to
  jump straight to a window/tab) -- these must never ship as part of the actual change -- and post
  an equally big, equally prominent message telling the user it's safe to use the keyboard/mouse
  again. The "all clear" matters as much as the initial warning -- don't let it shrink to a small
  aside in a longer message.

## Working with the git remote (push, PR, etc.)

- Before any operation that touches the GitHub remote (`git push`, `gh pr create`, deleting/renaming
  a remote branch, etc.), the **active** `gh` account must have enough privileges on the remote
  you're targeting. `git`'s own credential helper delegates to `gh auth git-credential`, so an
  operation run under an account without access fails with `403 Permission denied` (confirmed live:
  the `harryphillips-byte` account has no push access to this repo).
- Don't hardcode a username -- which account is the right one depends on who's working. Run `gh auth
  status` to list the logged-in accounts, and if the active one lacks access, `gh auth switch --user
  <name>` to another and retry, working through the available accounts until one has the privileges
  the operation needs. (For this repo's owner that account happens to be `tuxcomputers`, matching the
  org `tuxcomputers/TimeFlipApp`.)
- Contribution model: an outside contributor **forks** this repo and opens a PR to it from their
  fork -- so they push to their own fork with their own account and never need push rights on
  `tuxcomputers/TimeFlipApp` directly. Only the repo owner pushes branches here directly.

## TimeFlip2 BLE protocol documentation

**How to operate the device is answered in this order, and the first one that answers wins:**

1. **`docs/timeflip2-firmware-observations.md`**, which records behaviour **measured on the real device**
   where the spec is silent or wrong, with `docs/timeflip2-firmware-evidence.sqlite` holding the debug rows
   behind each claim. Check it before trusting the spec on anything to do with the device name, with whether
   a command is acknowledged, or with double tap. Add to it only from an actual device run, citing the
   evidence rows, and never from reasoning about the protocol.
2. **This app's own driver** (`Sources/FacetApp/DeviceLogin.swift`, `BluetoothRadio.swift`). It talks to this
   hardware and is checked against a real cube by `Tests/Scripted/50`-`66` on every full run, so where it
   departs from a document it is because the document was wrong and the code had to work anyway. Its comments
   say which measurement forced each departure.
3. **`docs/TimeFlip2 BLE Protocol v4.3.md`**, the official vendor spec.
4. **`docs/timeflip.md`**, a developer-written summary of the previous codebase's BLE driver. **Known wrong in
   at least one place**, see below.
5. **The previous implementation**, at `3ee3b47` in the history. It drove this hardware for a year, so it is
   worth a worktree for a question the four above cannot answer -- and anything found there that matters gets
   written into 1 or into `Tests/Methods.md` in the same change.

Only reach for a lower one when the one above it is silent. This ordering is not a preference, it is
what two long debugging sessions cost: `docs/timeflip.md` says a history frame's duration is five
bytes little-endian at 13-17, the vendor table says four bytes at 13-16, and the previous app's parser
read four bytes and tried both byte orders because firmware disagrees with its own spec. Following
`timeflip.md` produced a rebuild that rejected every single-event answer the cube gave, reported it
as "a frame this app cannot read", and sent somebody hunting a parser bug while the cube answered
correctly (2026-08-21). The same day, the old `readLastEventLocked` turned out to have already
recorded that a `0x01` reply arrives as a **read** and never as a notification -- "waiting on a
notification here reliably timed out against real hardware" -- which the rebuild had to rediscover
from a live trace. **That finding now lives in `DeviceLogin.readLastEvent`**, which is the point of the
ordering above: a fact that only exists in a deleted tree is a fact somebody pays for twice.

**Query that database rather than only reading the prose around it.** It holds 753 real rows from the
previous app against this same cube, including actual history frames, and those frames are what
finally settled the layout above after the documents had disagreed for an afternoon:

```sh
sqlite3 docs/timeflip2-firmware-evidence.sqlite \
  "SELECT DISTINCT message FROM debug_log WHERE message LIKE 'history ->%';"
```

## Nothing fails silently

**A command that can fail must say so.** Not `>/dev/null 2>&1`, not a discarded exit code, not a helper that
returns nothing whichever way it went. The point is not tidiness: a swallowed failure does not disappear, it gets
reported later, somewhere else, as something it is not.

Discarding *output* is fine where the output is noise. Discarding the *failure* is not. So capture, check the
status, print what went wrong, and return non-zero:

```sh
output=$(python3 scripts/status-item-click.py "$@" 2>&1)
status=$?
[ "$status" -ne 0 ] && { red "  the status item click failed (exit $status)${output:+: $output}"; return 1; }
```

**What it costs when it is not done, twice measured.** On 2026-08-23 `57-cube-pause` failed on "the cube is
stopped, ready to be turned while it is stopped", reported as `no debug_log row matching 'The cube is paused'
within 20s`. The cube was fine. `click_right` was `python3 scripts/status-item-click.py --right >/dev/null 2>&1`,
the click never happened, and the run spent twenty seconds waiting before blaming the device for a click nobody
had made. The same shape is already written up in `pair_a_cube`: `press` swallows everything, so pressing a button
that is not on screen does nothing and says nothing, and the wait after it timed out and reported the radio.

**The rule applies to the app too, and it already has one instance worth copying.** `DebugLog.reportWriteFailure`
exists because a run reconstructed from an empty table looks exactly like a run where nothing happened -- so a
failed write is announced once rather than never.

The two honest exceptions, and both have to earn it in a comment at the call site:

- **The record of the tests must never fail the tests.** Every write in `Tests/Scripted/testlog.sh` ends
  `2>/dev/null || true`, because a locked log database turning a passing run red would make the record a
  participant in what it is recording.
- **A probe whose failure is the answer.** `sqlite3 "$TESTLOG" "SELECT skipped FROM run LIMIT 1;" >/dev/null 2>&1`
  is asking whether a column exists; the error is the negative result, not a fault.

## Debug print messages

- **A message is plain text: no apostrophes, and no quotation marks around a value.** They are read back out of
  `debug_log` by SQL `LIKE` patterns, and a pattern goes inside a single-quoted string literal -- so `The cube's
  clock is set` closes the quote at `cube` and sqlite refuses the whole statement, answering nothing rather than
  failing. `Tests/Scripted/lib.sh` doubles apostrophes defensively, but a message that never carries one cannot be
  got wrong by whoever writes the next pattern. Quotation marks around an interpolated name cost an escape in the
  Swift source for no gain: `Timing: started Break (category_id 1)` reads as well as the quoted form did.

- Every dev-only console message must lead with a zero-padded 24-hour local time, followed by the
  `[Tag]` naming the action/source, e.g.:
  ```
  13:25:38 [history] Fetched 12 segments, newest event_number=112
  13:25:39 [entry  ] Segment 4213 became tracked time, filed under Meeting
  ```
- Use `debugLog?.record(_ tag: DebugLog.Tag, _:)` (in `Sources/FacetApp/DebugLog.swift`) rather than a
  bare `print(...)` call. It prepends the timestamp, and it writes a `debug_log` row as well as
  printing, which is the half that matters: a terminal transcript is whatever happened to still be in
  a scrollback buffer, while a row outlives the session and is what every scripted check polls for.
- `DebugLog` is **injected, not global**. It is built once in `main.swift`, gated there on the `debug`
  setting's `enabled` field, and handed to whatever needs it as an optional -- so a launch with logging
  off has no logger at all rather than one that returns early, and no call site needs an `if` around it.
  It is read at launch and then told by the App tab's Debug section, so logging starts and stops as the box
  is pressed rather than at the next launch. A row edited behind the app's back is not noticed until it
  restarts, which is why `Tests/Scripted/00-setup.sh` writes it with the app shut.
- The tag names all pad to the same bracket width (right-padded with spaces) so console lines stay
  aligned, per the example above. This is enforced by `DebugLog.Tag`: its cases hold the tag names,
  and `bracketed` pads to the width of the longest case, so adding a case automatically re-pads every
  tag — **when a new debug message is requested, add its tag as a new `Tag` case instead of inlining
  a `[Tag]` string in the message**, and double check the console output afterwards to confirm every
  tag still lines up (a new case that's longer than all existing ones widens every other tag's
  padding too).
