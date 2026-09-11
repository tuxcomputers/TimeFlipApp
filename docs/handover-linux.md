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
3. ~~**17, `CubeGatt`.**~~ **Done 2026-09-11**: `BlueZCubeGatt`, 22 tests, unverified on a cube.
4. ~~**18, `CubeRadio`.**~~ **Done 2026-09-11**: `BlueZCubeRadio`, 21 tests, unverified on a cube.
5. **19, compose the device half.** ⇐ **the milestone.** Written and booted 2026-09-11; open until a cube
   has answered it.
6. ~~**20, the menu bar onto the core modules**, then **21, the dialogues.**~~ Both done 2026-09-11.
7. **22 is not a task**, it is a warning about the one part of the Mac that is not ready for you.

## 19. Compose the device half in `main.swift`, and the app starts working

> **Written, hermetically green, and half run. Stays put until a cube has answered it.** (2026-09-11, Linux.)
>
> The wiring is done and the claim held: not one core module needed a line. `DeviceLogin`,
> `DeviceReconnector`, `CubeCommandChannel`, `HistoryIngestor`, `HistoryTimer`, `CubeLock`,
> `FaceColourSync`, `DeviceSettingsSync`, `LowBatteryWatch`, `DailyLimitWatch`, `ForcedPauseWatch` and
> `QuitSequence` are all constructed in this platform's composition root and run.
>
> **The boot is confirmed on this machine.** A ten second launch on 2026-09-11 wrote seven rows and no
> stderr: the instance lock, the database, `Launch mode: manual, no device is paired`, the history timer
> standing itself down, `DeviceReconnector` reading the table and correctly declining to scan,
> `Menu bar: name label, glyph label, figure label` -- which is `StatusItemReadout`, the core module the
> macOS status item reads, writing its colour row on this platform for the first time -- and the tray
> item coming up.
>
> **What is not confirmed is everything a cube answers**, and that is the whole of what is left here:
> the scan, the reach, the login, the PIN candidates, the face subscription, the history fetch, and time
> actually being recorded. Nothing on this box is paired, so a launch never touches the radio. **The
> owner has the cube and has not cleared it for a run yet**; the ask is one session with Facet quit on
> the Mac, and this item is finished the moment a face turn shows up in `device_event`.
>
> **The first thing to check when it happens**, because it is the one open measurement the port carries:
> `BlueZRadio.scannedDevices` maps BlueZ's `Name` to both `peripheralName` and `advertisedName`, and
> whether a `0x15` rename moves BlueZ's `Name` the way it moves CoreBluetooth's has never been measured.
> `BlueZCubeGatt` now reports a device `PropertiesChanged` as `nameArrived`, so a rename has somewhere to
> show up.


With 16, 17 and 18 in place this is wiring: inject the scheduler, the radio, the GATT and the secret store,
and `DeviceLogin`, `DeviceReconnector`, `CubeCommandChannel`, `LowBatteryWatch` and `HistoryTimer` all run
unchanged, because none of them knows what platform it is on.

**`main.swift` is the only file here allowed to know both halves**, which is what a composition root is for.
It is 145 lines today and builds the database and the menu bar; none of the device modules are constructed
yet, which is why the clock port has not broken this target despite `Scheduler` having no default anywhere.

**This is the milestone worth aiming at.** At the end of it there is a Linux Facet with no window that pairs
with a cube, logs in, follows face turns and writes time entries. Everything after it is drawing.

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

## 23. The core stopped saying `UUID`, and four of your files changed unverified

**`DeviceHandle` replaces `UUID` as what the core calls one cube** (`Sources/FacetCore/DeviceHandle.swift`). It
wraps a `String`, and the core does exactly two things with one: compares two for equality, and orders a list of
them so a room scanned twice is asked in the same order twice. It never parses one and never builds one from
parts. Whatever an adapter puts in comes back to that adapter unread.

**Why, and it is your side that was paying for it.** `UUID` was CoreBluetooth's shape reaching into the circle,
and the cost landed here: `BlueZAddress` existed to pack six address bytes into the last six bytes of a UUID
behind a `face7000-` marker, and to check the marker on the way back out so a Mac-written row was refused rather
than dialled. That is 84 lines and 6 tests spent making an address look like something it is not.

**So `BlueZAddress` and `BlueZAddressTests` are deleted, and the address is now the handle.** Every decode
became the identity function:

    device(_:)      radio.tree().device(withAddress: id.value)
    connect(_:)     radio.tree().device(withAddress: id.value)
    disconnect(_:)  radio.disconnect(address: id.value)
    scannedDevices  DeviceHandle(device.address)

**What I changed in your files**: `BlueZCubeRadio.swift` (the fourteen callback signatures, the internal
dictionaries and sets, the three decodes, one `UUID()` placeholder that is now `DeviceHandle("")`, and the
`BlueZLink` doc comment that described the mapping), `BlueZRadio.swift` (the one encode), and
`BlueZCubeRadioTests.swift` (`ours` and `theirs` are now the addresses verbatim, which reads better than it
did).

**None of it is compiled.** `FacetLinux` is not in this platform's package and your BlueZ tests are behind
`#if canImport(CDBus)`, so they built to nothing here. `swift build && swift test` on your side is what says
the retype is right. **If it does not build, the fix is yours and this item stays put with a line saying what
broke**, which is exactly what your item 23 said to me this morning.

**Two things to look at rather than trust.** I mapped `Set<UUID>`, `[UUID:` and `[UUID]` by pattern, so a
collection I did not anticipate may have been missed or wrongly caught. And `BlueZCubeRadio` had a
`reaching?.preferred ?? UUID()` that is now `DeviceHandle("")`: it preserves the behaviour, but an empty handle
as a placeholder is worth a second look now that the type can hold one meaningfully.

**What this is not.** It is not a portable identity. The handle is still platform-specific and still meaningless
on the other machine, which is why `database/011_setting.sql` now says so in both directions and says it must
never be synced. The owner settled on 2026-09-11 that only times and categories go to the Facet server, and that
no recorded time says which device produced it, so nothing needs an identity that outlives a pairing.
