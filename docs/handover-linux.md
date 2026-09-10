# Handover: for the Linux box

[← Back to README](../README.md) · [The other direction →](handover-mac.md) · [The two systems →](systems-info.md)

**This file is for the Linux box to act on. Everything in it is written by the Mac.**

Its mirror is [handover-mac.md](handover-mac.md), which the Linux box writes and the Mac acts on. Neither
machine edits the file addressed to itself except to delete from it, and neither deletes from the file it
wrote.

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
   information about the Linux* in [systems-info.md](systems-info.md); something the hardware does goes
   in [timeflip2-firmware-observations.md](timeflip2-firmware-observations.md); something about the port
   goes in [linux-port.md](linux-port.md), and the D-Bus mechanics in
   [linux-bluez-port-notes.md](linux-bluez-port-notes.md). This file is the asking, and it is meant to
   empty.
4. **An item you cannot do stays put, with a line saying why.** That is an answer too, and a more useful
   one than silence -- but say it in the item rather than deleting it, so whoever asked can decide what
   to do instead.
5. **Numbers are labels and are never reused.** A gap means an item was finished. A new item takes the
   next number never used before, so a commit message saying "handover 3" still means the same thing
   years later.
6. **When you have done everything you can, write what you want back.** Add items to
   [handover-mac.md](handover-mac.md) for the other machine. A blank file on both sides is the finished
   state.

## What this is not

**Not `systems-info.md`'s queues.** Those two sections ask for *facts about a machine* -- what compiler,
which filesystem, where the data directory resolves -- and the answer is written into that machine's own
facts section. This file asks for *work*: build something, run something, decide something. A question
whose answer is a fact belongs there; a task belongs here.

**Not the to-do list in `linux-port.md`.** That is what the port needs doing, in dependency order, by
whichever machine gets to it. This is what the *other* machine is being asked for, which is a much
shorter list and one that empties.

## The order I would take these in

**Asked for on 2026-09-10 and written by the Mac, so it is a recommendation rather than a rule** -- the rule
at the top of this file still holds, and an item can be taken out of turn. What the order is really saying is
which items unblock the most, and where the milestone is.

1. ~~**15** -- does the tree build and test here at all.~~ **Done 2026-09-11**; it did not, and does now.
2. ~~**16, the clock.**~~ **Done 2026-09-11**: `GLibScheduler`, injected from `main.swift`.
3. **17, `CubeGatt`.** The largest amount of behaviour bought for the least code anywhere in this port.
4. **18, `CubeRadio`.** Scanning and connecting, which 17 has nothing to talk to without.
5. **19, compose the device half.** ⇐ **the milestone: a Linux Facet that pairs with the cube and records
   time.** No window, and it would already be doing the thing the app is for.
6. **20, the menu bar onto the core modules**, then **21, the dialogues.** Both are drawing.
7. **22 is not a task**, it is a warning about the one part of the Mac that is not ready for you.

## 17. `BlueZGatt` has something to conform to now: `CubeGatt`

**This is the item that buys the most.** `DeviceLogin` -- the whole 1,300-line login sequence, the PIN
rotation, the read-back discipline, the deadlines, the Device Information reads -- moved into `FacetCore` on
2026-09-10 and now talks to a `CubeGatt` rather than to a `CBPeripheral`. The command channel, the queue and
the read-back matrix were already there. **So this slot owes transport and nothing else**: discover, read,
write, subscribe, and the answers handed back.

`Sources/FacetCore/CubeGatt.swift` is the port. Three things to read beside it:

- **`Sources/FacetMac/CoreBluetoothGatt.swift`, 153 lines**, is the reference: a `CBPeripheral`, a table of
  characteristics keyed by canonical UUID, and every call a translation. It decides nothing.
- **`Tests/FacetTests/InMemoryGatt.swift`, 87 lines**, is the second adapter and shows the contract with no
  radio at all.
- **`Tests/FacetTests/DeviceLoginTests.swift`** drives the login through that double, which means the
  sequence you are about to feed is already tested and will be tested on this platform too.

**Answer in `TimeFlipUUIDs.canonical` spelling.** This is the one trap and it is invisible: on the Mac it cost
three bugs that all compiled, and one of them was found only because a test existed. It should be *easier*
here, because BlueZ already reports the expanded lowercase form natively and `canonical` was written against
what this machine prints -- but the port's contract is the canonical spelling either way, so canonicalise
rather than assuming BlueZ has done it.

**One more thing landed on 2026-09-10 that you will see**: there is now one table of characteristic names,
`TimeFlipUUIDs.named`, and the spellings in it (`commandResult`, `timeFlipService`) are interface -- the
scripted suite reads them back out of `debug_log` with `LIKE` and `GLOB`. There used to be two tables
disagreeing.

## 18. `BlueZRadio` and `CubeRadio`

Scan, connect, disconnect, forget, and the answers back. It already does all of that; what it does not do is
say so in the shape the port names, and it has no caller.

**`DeviceScanRules` decides which advertisement is a cube, unchanged and shared**, which is the point: a
renamed cube is found or lost identically on both platforms. That rule is more load-bearing than it looks --
the advertised local name stays `TimeFlip v2.0` for ever and only the GAP name changes, so a filter matching
one name loses a renamed cube. That is not hypothetical, it is what the previous app shipped.

## 19. Compose the device half in `main.swift`, and the app starts working

With 16, 17 and 18 in place this is wiring: inject the scheduler, the radio, the GATT and the secret store,
and `DeviceLogin`, `DeviceReconnector`, `CubeCommandChannel`, `LowBatteryWatch` and `HistoryTimer` all run
unchanged, because none of them knows what platform it is on.

**`main.swift` is the only file here allowed to know both halves**, which is what a composition root is for.
It is 145 lines today and builds the database and the menu bar; none of the device modules are constructed
yet, which is why the clock port has not broken this target despite `Scheduler` having no default anywhere.

**This is the milestone worth aiming at.** At the end of it there is a Linux Facet with no window that pairs
with a cube, logs in, follows face turns and writes time entries. Everything after it is drawing.

## 20. The menu bar's meaning is in the core; GTK should only draw

`Sources/FacetLinux/MenuBar.swift` is 191 lines and `CLAUDE.md` holds it up as the right shape, which it was
when it was written. It now predates four core modules that took the decisions off it:

    StatusItemMenu      220 lines   what the items are, and what each does
    StatusItemReadout   137 lines   what the title and the tooltip say
    StatusItemGesture   135 lines   what a click means, including the double-tap window
    StatusColour         39 lines   which colour a state is

The macOS side went from 679 lines to 518 doing this, and what is left there is `NSStatusItem` and drawing.
**Point this file at those four and delete whatever it was deciding for itself**, so the two platforms cannot
disagree about what the menu says.

## 21. A GTK slot in the dialogue square

`DialoguePresenter` and `Dialogue` are in `Sources/FacetCore/Dialogue.swift`. A `Dialogue` carries a title, a
message, its choices, **which choice is the way out** and whether it is a warning; the presenter shows it and
answers with an index. All nineteen alerts in the app go through it.

`Sources/FacetMac/AlertPresenter.swift` is 77 lines: a sheet where there is a window and app-modal where there
is not, and every keyboard-shortcut decision lives in it rather than at the call sites.
`Tests/FacetTests/RecordingDialogues.swift` is 34 lines and is the second adapter.

**`wayOut` is the part not to skip.** AppKit relocates a button titled Cancel, which took Return off it and
put it on the destructive answer; the port names the way out explicitly so no platform has to infer it from
button order. Whatever GTK does about default buttons, honour that field.

## 22. Not a task: what is not ready for you yet

**The Settings window.** The remodel took the menu bar, the radio, the clock, the dialogues, the quit sequence
and the settings-write ordering into the core, and it stopped there deliberately.
`docs/architecture-ports-plan.md` item 6 has one row left (`renameDevice`/`sendRename`) and the honest
statement about the rest is that it is view construction and tab wiring, which is what an adapter is *for*.

So `SettingsWindowController` is 3,487 lines of AppKit and **there is no port to fill for it**. When you get
to a Linux Settings window you are building it, not slotting into it -- and the decisions it makes that are
worth sharing should come out into the core as you find them, the same way everything above did. **Say so
here when you hit one**, rather than reimplementing it: a rule spelled twice is the thing this whole model
exists to prevent.
