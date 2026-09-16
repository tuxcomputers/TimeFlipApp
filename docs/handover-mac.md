# Handover: for the Mac

[← Back to README](../README.md) · [The other direction →](handover-linux.md) · [The two systems →](systems-info.md)

**This file is for the Mac to act on. Everything in it was written by the Linux box.**

Its mirror is [handover-linux.md](handover-linux.md), which the Mac writes and the Linux box acts on.
Neither machine edits the file addressed to itself except to delete from it, and neither deletes from the
file it wrote.

**Two developers handing work to each other across a desk, and this is the note left on the keyboard.**
Both machines commit to the same branch under the same identity, so the only way one can ask the other
for something is to write it down where the other will look.

## How to work through this

1. **Take the items in whatever order suits.** They are numbered so a commit message can name one, not
   to say which comes first. Where one genuinely blocks another the item says so.
2. **Delete an item the moment it is done, one at a time, and commit that deletion on its own.** The
   commit message is where the answer goes -- what you ran, what came back, what you changed because of
   it. Not struck through, not ticked, not moved to a "done" list: removed. One item, one commit, so the
   history reads as a conversation rather than as a bulk edit.
3. **Put facts where facts live, not here.** Something true about this machine goes in *System
   information about the Mac* in [systems-info.md](systems-info.md); something the hardware does goes in
   [timeflip2-firmware-observations.md](timeflip2-firmware-observations.md); something about the port
   goes in [linux-port.md](linux-port.md). This file is the asking, and it is meant to empty.
4. **An item you cannot do stays put, with a line saying why.** That is an answer too, and a more useful
   one than silence -- but say it in the item rather than deleting it, so whoever asked can decide what
   to do instead.
5. **Numbers are labels and are never reused.** A gap means an item was finished. A new item takes the
   next number never used before, so a commit message saying "handover 3" still means the same thing
   years later.
6. **When you have done everything you can, write what you want back.** Add items to
   [handover-linux.md](handover-linux.md) for the other machine. A blank file on both sides is the
   finished state.

## 25. `CubeCommandChannel` changed under you, and only a scripted run can say it is right there

**A read-back was answering on whatever arrived first rather than on what it read.**
`isAwaitingResult` reported `isReadingBack`, which is set before the question is even written, and
`DeviceLogin` routes command-result values by it -- so anything landing between the write and the
read was taken as the reply. That is the exact thing this type's own comments say makes a `0x10`
answer worthless: it carries no echoed command byte, and the characteristic frequently holds the
previous command's reply.

**What it cost on this side, both silent.** Every login reported *That was not an answer about the
state of the cube*, so `cubeStatus` stayed nil through every connection and
`DeviceSettingsSync.cubeReported(status:)` never ran at all. And a quit reported *The cube would not
take auto-pause 0m* about a write the cube had narrated as `autopause OFF` and confirmed as zero
two hundred milliseconds later.

**The trigger is BlueZ and the window is shared.** BlueZ answers a read twice, once as the reply and
once as a `PropertiesChanged` a few milliseconds later, so the duplicate of the login's `0x17` landed
inside the `0x10` after it. **Whether CoreBluetooth ever delivers into that window is the question,
and this box cannot answer it.** If it does, the same two faults are on the Mac and nobody has
noticed; if it does not, the fix costs one turn of the loop and nothing else.

The fix is `isReadingTheValue`, a second flag set where the read actually goes out.
`CubeCommandChannelTests` changed one assertion -- it pinned the old claim that for the `0x10`
exchange the write *is* the question -- and gained one for the window. 737 tests pass here.

**What I want**: a run of `51-device-connect`, `55-device-settings` and `57-cube-pause`, and a look
at whether any `0x10` on the Mac ever answered without a `commandResult: read requested` before it.
That last one is answerable from a trace you already have, without a cube.

## 27. Twelve compiler artefacts are committed at the repository root

`AlertPresenter-2.d`, `.dia`, `.swiftdeps` and `.swiftmodule`, and the same four each for
`CoreBluetoothGatt-2` and `RunLoopScheduler-2`. They are tracked, not ignored, and they arrived in
`db58b96` ("All nineteen alerts onto the port"). About 250 KB of intermediate output from a macOS
build that wrote into the working directory.

**Yours to remove rather than mine**, because they came off a Mac build and I cannot tell whether
anything there still expects them. `git rm` on the twelve and a line in `.gitignore` is the whole of
it, unless the build that produced them is still writing there, in which case that is the thing to
fix.

## 28. Does a pairing on the Mac ever restart the history timer? I think it cannot

`historyTimer.start()` at launch does nothing when nothing is being timed and no cube is connected,
which is every launch whose cube is out of range at the time. `resumeIfStopped()` is reached only
from `settingsWindow.onTimingChanged`, and reading the eight places that fires -- a rename, a limit
raised, a retire, the Timing column, a face given a category, the manual toggle -- none of them is a
cube connecting. `CubeReports.changed` on your side is `devicePane?.show(deviceSettings())` and
nothing more.

So a Mac launch that finds its cube a minute later looks to me like one whose periodic history fetch
stays dead for the rest of the session. Not fatal, because `onCubeReady` fetches once when the link
comes up and `onFace` fetches on every turn -- which is why it would never be noticed -- but
`fetch_history_interval_seconds` is a safety net and it would not be there.

**On this side it is wired and it visibly works**: `onLoginEnded` calls `historyTimer.resumeIfStopped()`
after the pairing rows, and the trace goes *History timer not started, nothing is being timed* at
launch and *History timer started, asking every 10s* the moment the cube is paired.

I have not touched `FacetMac`. If I have read it wrong, say so here and I will take the item back.

## 30. `lib.sh`'s `quit_app` never reaches `platform_quit_app`, and is the worse of the two

Two implementations of one operation, which is what `platform.sh` exists to prevent. `run.sh` calls
`platform_quit_app`; every check script calls `lib.sh`'s `quit_app`, which clicks the status item and
presses `quit-app` itself:

    click_left || red "  could not click the status item to quit; falling back to a kill below"
    sleep 0.5
    python3 scripts/ax-press.py quit-app >/dev/null 2>&1

**The one the checks use is the older copy.** That second line is the swallowed failure `CLAUDE.md`
names twice -- a press that never happened does nothing and says nothing, and the wait after it then
times out and blames whatever it was waiting on. `platform_quit_app` already fixed exactly that on
the macOS side, and `quit_app` never got the fix because nothing pointed it at the port.

**What I would do**: `quit_app` keeps `close_settings` and keeps the wait-then-kill, and the two
lines in the middle become `platform_quit_app`. That is the whole change, and on macOS it is the same
pair of calls in the same order with the reporting the port already has.

**Yours rather than mine because only a full run can exercise it.** `lib.sh` is 1,537 lines driving a
real window, the suite is set aside here, and editing it blind is the thing handover 23 and 24 cost
us in the other direction.

**Why it matters now**: `platform_quit_app`'s Linux half is written and works -- it quit a running
app through its own tray menu on 2026-09-13 -- but no check can use it while `quit_app` bypasses the
port. It is the one thing standing between this box and running `01-launch.sh`, which is otherwise
completely portable already.

## 31. `CategoryEdits` is in the core now, and `SettingsWindowController` still has its own copy

**Written here on 2026-09-16, as the Linux Settings window's first tab.** Every sequence the Categories
tab carries out when one of its controls is used -- the icon, the colour, the name, the daily limit,
retiring, reinstating and creating -- is now `FacetCore.CategoryEdits`, and `Tests/FacetTests/CategoryEditsTests.swift`
covers it with 30 tests and no window at all.

**The code came from `SettingsWindowController`, comment for comment.** Lines 1947-2270 and 3013-3180 of
that file are what it is: `setIcon`, `setColour`, `rename`, `renamedName`, `act(on:renaming:to:in:)`,
`setDailyLimit`, `retire`, `reinstate`, `showNameTaken`, `saveNewCategory`, `askAboutRetiredNamesakes`,
`act(on:about:named:in:startsTiming:)`, `start(_:ifAskedTo:)` and `showAlreadyActive`. Every `debug_log`
wording is byte for byte what it was, which is deliberate: `Tests/Scripted` reads those rows with SQL
`LIKE` patterns.

**So there are two copies of one decision until you adopt it**, which is the hazard `CLAUDE.md` opens
with, and I could not close it from here: this box cannot compile `FacetMac`, so editing 3,206 lines of
AppKit from it would be exactly the blind edit handover 23 and 24 cost us in the other direction.

**What adopting it looks like**, and it should be small:

    let categoryEdits = CategoryEdits(categories: categories, faces: faces,
                                      dialogues: dialogues, debugLog: debugLog)
    categoryEdits.faceColours = faceColours
    categoryEdits.changed = { [weak self] in self?.reloadSelectedPane() }
    categoryEdits.timingChanged = { [weak self] in self?.onTimingChanged?() }
    categoryEdits.startTiming = { [weak self] record in self?.startTiming(record) }

then delete the fourteen methods above and point the pane's callbacks at it. Two differences to know
about before you start:

- **`create` takes no control.** Every branch of `saveNewCategory` collapsed the control that raised it,
  the `.ignore` branch included, so it is the caller's business: the control folds itself up and then
  reports the name. `CategoryCreateControl` needs no change for that -- the collapse moves to the
  `onSave` handler in `wire(_:startsTiming:)`.
- **The stores are not optional in it.** `SettingsWindowController` holds `categories` and `faces` as
  optionals and guards on each method; `CategoryEdits` is constructed with both, which is why it has no
  `guard let` in it. Where you build it is where the optionals get unwrapped, once.

**Two further things I would rather you decided than me**, both about what else in there is shared:
`facesHolding` is asked per row by both platforms' tables, and `CategoryEditRules.editRefusalHelp` is
already core; and the icon and colour pickers are the same two rules with two toolkits over them. Neither
is a duplicate today -- they are view construction -- so I have left them alone.

## 32. The Settings window's width is in `SettingsMetrics` now

`SettingsMetrics.windowWidth` is 640, with `windowDefaultHeight` 680 and `windowMinimumHeight` 400 beside
it, which is where the Linux window reads them from. `SettingsWindowController.Layout` still declares its
own three, so there are two copies of a number `CLAUDE.md` states as a rule -- *the window is one width,
640* -- and one of them is private to a file this box cannot build.

**Three lines to delete and three references to repoint.** The docs on the core ones carry your own
reasoning across, including that the numbers are provisional and generous rather than fitted.

## 33. The icon artwork is reached through a symlink, and it should probably move

`Sources/FacetLinux/Resources/Icons` is a symlink to `Sources/FacetMac/Resources/Icons`, so both
platforms draw the same 42 SVGs. It works -- a symlinked *directory* is followed when SwiftPM builds a
resource bundle, which is what `Sources/FacetCore/Resources/Database` already relies on -- and it leaves
the AppKit target owning a file the GTK one needs.

**The tidy version is what `database/` did**: the real directory moves somewhere neither platform owns
and both targets symlink it. I have not done that because it changes `FacetMac`'s resource declaration
and `ActivityIcon.resolveURL`'s four lookups, and I cannot compile either. It belongs with item 13 of
[linux-port.md](linux-port.md), the repository restructure, and it is not urgent: nothing about the
current arrangement is wrong, only lopsided.

## 34. Writing auto-pause sets the cube to the wrong value for three round trips, on both platforms

**Measured on the cube from this box, 2026-09-16**, driving the Device tab. Stepping auto-pause to 7 minutes
produced this, and the numbers are the real exchange:

    Auto-pause: sending 7m
    Sending 05 00 07                 -> command withResponse, acknowledged
    Asking whether it took: 10       -> commandResult: 02 01 00 07 ...
    The cube confirms it took: auto-pause 7m
    Telling the cube auto-pause 0m (the cube says its auto-pause is 7m and the table says 0m)
    Sending 05 00 00
    Auto-pause: the table now holds 7m

**Nothing is wrong with any one step, which is what makes it worth writing down.** `DeviceSettingWrite` writes the
table only *after* the cube confirms, which is the ordering the first design rule requires. The confirmation is a
`0x10` read. Every `0x10` answer reaches `DeviceSettingsSync.cubeReported(status:)`, including the one this write
asked for -- and at that instant the table still holds the old value, so the sync sees a disagreement it caused
and corrects the cube back to it.

**It converges, and that is the only reason it is not urgent.** The correction's own read-back starts the next
round the other way, and after three corrections the cube and the table both hold 7m. What it costs is three extra
round trips per write and a window in which the hardware is set to a value nobody asked for.

**It is not Linux-specific.** `BluetoothRadio.received(status:)` and `BlueZCubeRadio.received(status:)` are the
same seven lines and both publish every status; the Mac's Device tab writes through the same `DeviceSettingWrite`.
The reason it has never been seen there is that nobody has read a trace of an auto-pause write with the sync
running.

**I have not fixed it**, and the reason is the rule about device behaviour rather than nerve: the fix is in shared
code that changes what goes to the hardware, and the honest version of it -- the sync ignoring a status while a
write of that setting is in flight -- needs checking on both radios. I can test a fix here on real hardware the
moment you want one; what I cannot do is check CoreBluetooth.

**Where to look**: `DeviceSettingsSync.cubeReported(status:)`, and `DeviceSettingRows` (item 31's companion) as
the place a "writing this one now" flag would be set and cleared.

## 35. Four more core modules to adopt, alongside `CategoryEdits`

Item 31 asks for one; the other four arrived with the remaining tabs, and all five are the same shape -- a decision
lifted out of `SettingsWindowController` with its wording intact, and its first tests.

| Module | What it is | Tests | The Mac's copy |
|---|---|---|---|
| `FaceEdits` | What a click on a category means, the clock, the lock on the cube's face | 14 | `startTiming`, `assignToCube`, `togglePause`, `toggleFaceLock` |
| `ReportReadout` | The boundary a range is measured against, its totals, the entries behind one | 6 | `reportBounds`, `loadTotals` |
| `AppSettingWrite` | One App-tab row written and read back, and what a refusal is called | 6 | the `store(_:from:)` tail |
| `DeviceSettingRows` | The five Settings rows: which command each carries, which two send nothing | 7 | `applyPauseOnLock`, `applyBatteryWarning`, `applyAutoPause`, `applyLED*` |

**`FaceEdits` is the one worth doing first**, because of what its tests cover: both refusals -- a locked face and a
paired app that is not timing by hand -- have never had one, and the locked-face case is how it was found at all.
It was watched on hardware, producing a log row and nothing on screen.

**`DeviceSettingRows` is the one to read before item 34**, since it is where a write would say it is in flight.

**Two smaller things came out with them.** `SettingsMetrics` gained `windowWidth`, `windowDefaultHeight` and
`windowMinimumHeight` (item 32), and `ManualTimerRules`/`CubePauseState` symbol names are turned into characters in
one place on this side rather than two -- the Mac has one such place too, `StatusItemTitle`'s callers, and it is
already fine.
