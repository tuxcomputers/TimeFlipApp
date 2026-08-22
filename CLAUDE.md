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

## Read how the archived app did it, before building anything

The app is being rebuilt from the ground up, and the previous implementation is in `Archive/`
(`TimeFlipApp/`, `TimeFlipAppTests/`, `Tests/`, `testrunner/`), with its supporting material in
`Archive/Tests/Methods.md` and in `docs/`. **For every feature request, read how the old code did it
first.** Not to copy it, and not as a courtesy to it: to find out what it knows.

Then decide, explicitly, which of three applies -- and **say which in the reply**, so the choice is
visible rather than buried in a diff:

- **Ignore it.** It solved a problem this design does not have, or it was working around something
  that no longer exists. Say what it did and why the new shape does not need it.
- **Massage it.** The intent is right, the shape is not. Take the intent and build it the new way.
  This is the common answer.
- **Copy it as is.** It is right, and rewriting it would land in the same place. Copy it, and say
  what makes it worth keeping verbatim.

Treat the old code as prior art written by somebody else, and this as a better version of it: reading
it is not permission to import it, and "the old code did X" is not a reason for anything on its own.
Judge it on merit. When it wins, it wins because the reason survives inspection today.

**What is actually valuable in there is the measurements**, not the habits. The archive holds facts
that cost a real experiment to obtain, and re-deriving them costs the same again:

- `SingleInstanceLock` records that an instance launched directly reports a `nil` `launchDate`, which
  is why "whoever started first wins" could not work and a kernel lock was used instead.
- `Archive/Tests/Methods.md` Method 10 records that a Settings tab button has no `AXTitle` and must be matched
  on `description`. Without reading it, the same discovery in the rebuild looked like a regression to
  be worked around, when it was the contract the suite already expected.

So the archive's comments and its test methods are the first place to look, and a fact it recorded from
a real device or a real accessibility tree outranks reasoning about what should happen.

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
one being precise. `CategorySection` is the pattern: a borderless button spanning the row sits *behind* the
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

This is about *collapsible* groups. A plain section heading, like the App tab's "App settings", stays above its
panel: it names the panel, it does not operate it.

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

## The device tests are archived, and are being rebuilt per feature

There is no device-test suite at the moment. The previous one -- the Bench and Interactive
checklists, the shared methods, the setup, and the Python harness that drove them -- is in
`Archive/Tests/` and `Archive/testrunner/`, kept as reference and as code to reuse where it still
fits. **`swift test` is the only suite that runs today**, and it is hermetic: it never touches a
radio, so a feature can be entirely green and still be broken on hardware.

Most of the old suite cannot come back as it is. Every locator in it addresses the previous app's
accessibility tree (`Archive/Tests/Methods.md` Method 10 reaches the Settings tabs through
`toolbar 1`, which this app does not have), and every checklist tests a feature this app has not
rebuilt yet. What *does* carry over is worth taking deliberately:

- The **engine** knows nothing about the app: `md_checklist.py`, `run_record.py`, the supervisor loop
  and `logs/testruns.sqlite`. What knew about the app -- `locators.py`, the app-specific actions,
  `session_setup.py` -- is what died.
- The **procedure**, which cost real runs to learn and is written down in `Archive/Tests/CLAUDE.md`:
  Bench (script-drivable) before Interactive (needs a person); refresh `current_log_id` before every
  step; a cross-step wait needs its own named baseline; a scenario is the atomic resume unit; an
  indefinite wait gets no silent grace period; poll the database for a physical side effect rather
  than asking the user to confirm one.
- The **device measurements**, which are facts about the hardware and so still true. See
  `Archive/Tests/Methods.md` and `docs/timeflip2-firmware-observations.md`.

It should also come back much smaller. The old `locators.py` existed largely because elements were
not addressable and steps had to hunt by position; every element this app builds carries an
`AXIdentifier`, and every click it handles writes a `debug_log` row, so a step is now "press by name,
then poll for the row". `scripts/ax-press.py`, `scripts/ax-dump.py` and
`scripts/status-item-click.py` are that whole layer.

**`Tests/Methods.md` is the new suite's shared methods, numbered, and it starts now rather than when
the first checklist does.** Anything learned while checking the app against a running copy of itself goes there
as it is learned -- the command and the fact, not the story -- because a technique rediscovered is a
technique that was written down too late. It already carries the ones that cost the most: what needs a
real mouse event and what does not, why a status item is not in `AXMenuBar`, and the two reasons
`performClick` silently does nothing.

So: write each checklist as its feature lands, keep it small, and let the harness grow back around
what the first few actually need. CI already tolerates none of them --
`scripts/check_interactive_checklists.sh` prints "No test checklists found; skipping" and exits 0 --
and it still enforces the two rules that matter the moment one exists: no unchecked box, and a
`### Last run` heading naming the PR's own branch.

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

1. **The archive's code** (`Archive/TimeFlipApp/`). It drove this hardware for a year, so where it
   disagrees with any document it is because the document was wrong and the code had to work anyway.
   Its comments say which measurement forced each departure.
2. **`docs/TimeFlip2 BLE Protocol v4.3.md`**, the official vendor spec.
3. **`docs/timeflip.md`**, a developer-written summary of the previous codebase's BLE driver.

Only reach for a lower one when the one above it is silent. This ordering is not a preference, it is
what two long debugging sessions cost: `docs/timeflip.md` says a history frame's duration is five
bytes little-endian at 13-17, the vendor table says four bytes at 13-16, and the archive's parser
reads four bytes and tries both byte orders because firmware disagrees with its own spec. Following
`timeflip.md` produced a rebuild that rejected every single-event answer the cube gave, reported it
as "a frame this app cannot read", and sent somebody hunting a parser bug while the cube answered
correctly (2026-08-21). The same day, the archive's `readLastEventLocked` turned out to have already
recorded that a `0x01` reply arrives as a **read** and never as a notification -- "waiting on a
notification here reliably timed out against real hardware" -- which the rebuild had to rediscover
from a live trace.

`docs/timeflip2-firmware-observations.md` sits with the archive at the top and outranks both
documents: it records behaviour **measured on the real device** where the spec is silent or wrong,
with `docs/timeflip2-firmware-evidence.sqlite` holding the debug log rows behind each claim. Check it
before trusting the spec on anything to do with the device name, or with whether a command is
acknowledged. Add to it only from an actual device run, citing the evidence rows, and never from
reasoning about the protocol.

**Query that database rather than only reading the prose around it.** It holds 753 real rows from the
previous app against this same cube, including actual history frames, and those frames are what
finally settled the layout above after the documents had disagreed for an afternoon:

```sh
sqlite3 docs/timeflip2-firmware-evidence.sqlite \
  "SELECT DISTINCT message FROM debug_log WHERE message LIKE 'history ->%';"
```

## Debug print messages

- All dev-only `print(...)` console messages (gated on `DeveloperMode.isEnabled`) must lead with
  a zero-padded 24-hour local time, followed by the `[Tag]` naming the action/source, e.g.:
  ```
  13:25:38 [history] Fetched 12 segments, newest event_number=112
  13:25:39 [entry  ] Segment 4213 became tracked time, filed under Meeting
  ```
- Use `DeveloperMode.debugPrint(_ tag: DebugTag, _:)` (in `DeveloperConfigStore.swift`) rather than
  a bare `print(...)` call — it prepends the timestamp and gates on `isEnabled` itself, so call
  sites don't need their own `if DeveloperMode.isEnabled { ... }` wrapper.
- The tag names all pad to the same bracket width (right-padded with spaces) so console lines stay
  aligned, per the example above. This is enforced by `DeveloperMode.DebugTag`: its cases hold the
  tag names, and `width` is derived from the longest case's name, so adding a case automatically
  re-pads every tag — **when a new debug message is requested, add its tag as a new `DebugTag`
  case instead of inlining a `[Tag]` string in the message**, and double check the console output
  afterwards to confirm every tag still lines up (a new case that's longer than all existing ones
  widens every other tag's padding too).
