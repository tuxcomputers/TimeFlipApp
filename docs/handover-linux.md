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

**Five more arrived from the Mac after this list was written, and only two of them gate anything.** 23 and 24
are edits already made to your files that nobody has compiled, so a build will refuse until they are right:
take those first. 25, 26 and 27 are offers rather than tasks, and they are all the same offer in three places,
which is that a decision you wrote independently now exists once in `FacetCore`: the reach, the app's own
clock, and what the app does when the radio says something. None of them blocks a build and none of them is
urgent; each removes a second copy of something that agrees today.

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

**Two more things came out of it after this was written (Mac, 2026-09-13), and the warning still stands.**
`ManualClock` took the app's own clock, which three controls reach and one of them is not a window at all;
`CubeReports` took what the app does when the radio says something, including both of the reconnect loop's
feedback inputs. Neither is a port and neither helps you draw a window: they are decisions that were in the
wrong file, and taking them out is why the number below keeps falling.

So `SettingsWindowController` is 3,206 lines of AppKit and **there is no port to fill for it**. When you get
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

**Two more sites were missed and are fixed (Mac, 2026-09-13).** `main.swift` compared
`settings.string("device_uuid", field: "uuid")` against `id.uuidString` in `onLoginEnded` and `onDeviceName`,
and a `DeviceHandle` has no such member: both now say `id.value`. Found by reading your callbacks rather than
by anything failing, which is the whole problem with editing files I cannot build.

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

## 24. Double tap is off for good, and your `main.swift` changed unverified

**The owner removed the gesture from the app on 2026-09-11.** There is no control on the Device tab, nothing
reads `double_tap_settings`, and `DoubleTapRules.alwaysSent` is the only thing ever sent: the factory registers
with `window` at 0.

**Why, and it is a real reason rather than a preference.** A double tap stops the cube's tracking *in firmware
with no command involved*. It produces no face change, writes no command result, and `systemState` does not
carry it, so nothing can tell the app it happened: the app finds out on its next history fetch and not before
(finding 11, `docs/timeflip2-firmware-observations.md`). Off, that state cannot arise at all.

**What changed in the core, which you build.** `DeviceSettingsSync.Stored` lost `doubleTap` and
`isDoubleTapEnabled`; `DoubleTapRules` lost `asSent` and `DoubleTapParameters` lost `withTheGestureOff`, both
of which existed to zero a stored window there is no longer one of.

**What changed in your file.** `Sources/FacetLinux/main.swift` built `Stored` with those two fields and now
does not. That is the only edit and it is a deletion, but `FacetLinux` is not in this platform's package so it
has not been compiled: `swift build && swift test` on your side is what says it is right.

**What did not change, deliberately.** `radio.onDoubleTapParameters` and `cubeReported(doubleTap:)` both stay,
and they are now the whole mechanism. `0x16` has a read-back in `0x17`, the login reads it on every connection,
and the comparison is against the constant instead of a table: a cube running something else gets `0x16`, and a
cube already off is told nothing. Nothing was added to `linkSettled`, which still blind-sends only the two
commands that have no read-back. So the Linux side needs no new wiring, only the deletion above.

## 25. Your `Reach` can go: the sequence it duplicates is in the core now

**`CubeReachSequence` landed on 2026-09-13**, the last of candidate 1's five clusters. It holds the order, the
queue, the not-tried-twice set, the settle wait before each candidate, `anyRefused` telling "none of them was
ours" from "nothing was there", and the shortcut where the remembered handle turning up cuts the scan window
short and then has to be paid for if that device refuses the PIN.

**`BlueZCubeRadio` has its own `Reach`** with its own `tried` and `anyRefused`, written when there was nothing
to share. That is the second implementation candidate 1 predicted and the reason it was worth doing: two
copies of these decisions will not stay in step, and the shortcut in particular is subtle enough that a
difference would be found by a user rather than by a test.

**What it needs from you.** Three closures, the same shape `CubeResetProof` takes: `tryThis(handle,
candidates, rotatingTo)` begins one login attempt, `scanAgain()` opens a second window, and `finished(handle,
outcome)` says the reach is over. Feed it `scanEnded(found:remembered:previouslyKnown:isBusy:)` when a window
closes, `shouldCutTheWindowShort(for:)` on each advertisement, and `candidateEnded(_:isBusy:)` when a login
ends. `tryNext` is deliberately private: `scanEnded` and `candidateEnded` each end in one, and a caller that
also called it would skip a device with nothing failing.

**`CubeReachSequenceTests` is what it should behave like**, thirteen tests with no radio in them, and they run
on your side too.

**Nothing of yours was changed for this.** Your `Reach` still compiles and still works; this is an offer to
delete it, not a break to repair. The one thing worth checking as you go is whether your loop makes a decision
mine does not, in which case say so here rather than keeping both.

## 26. `ManualClock` exists, and your `togglePause` is deliberately narrower than it

**Your comment gives the reason and it is a good one**: "closing the open segment is the whole of what stopping
it means here. On the Mac this is the Faces tab's own control; this platform has none, so a segment on an app
face can only have been inherited from a launch on the other machine."

**So this is a choice to make rather than a bug to fix.** `ManualClock.toggle` in `FacetCore` is what the Mac's
three controls now share: it reads before writing, refuses a resume against a spent daily limit, closes or
starts a segment on one moment, and reads back what the table holds. Yours closes and stops there.

**What adopting it would change**, so the choice is made on what it does rather than on tidiness:

- **Pause would become resumable** from the Linux menu bar. Today a second press does nothing, because there is
  nothing that starts a segment. Whether that is wanted on a platform with no way to pick a category is your
  call and is the real question here.
- **A spent daily limit would refuse the resume.** Moot while nothing can resume, and not moot afterwards.
- The two log rows would become `Timing: running <name>` and `Timing: stopped <name>`, which
  `05-faces-timing` reads on the Mac.

**If you keep the narrowing, say so in `ManualClock`'s doc comment rather than only here.** Two answers to one
question is what this model exists to prevent, and a deliberate difference that is written down where the
shared one can be read is not that. An undocumented one is.

## 27. `CubeReports` exists, and five of your radio callbacks are it, near-verbatim

**Written independently and they agree, which is the good case and still the hazard.** `CubeReports` landed on
2026-09-11 holding what the app does when the radio says something. Your `main.swift` has its own
`onLoginEnded`, `onDeviceName`, `onDeviceInfo`, `onBatteryLevel` and `onPINChanged`, and they make the same
decisions in the same order, down to the comments: the pairing-or-reconnection question asked of the table, the
`DevicePairingRules.adoption` switch, the loop told before anything is recorded.

**They agree today. Nothing keeps them agreeing.** That is the whole argument, and it is the one
`docs/state-reference.md` opens with: two copies of a decision get taught something in one place and not the
other, and nothing fails when they part.

**What it takes.** Build one with `settings`, `devicePINs` and `debugLog`, set `reconnect`, `lowBattery` and
`dialogues` on it, and give it a `changed` closure, which is your `menuBar.redraw()`. Then each callback
becomes one line. The Mac's own `adopt(_:)` is the worked example, and `CubeReportsTests` is what it should
behave like: eight tests, no radio, and they run on your side too.

**One deliberate difference to keep.** `connectionDropped` tells the reconnect loop to back off, which is right
for a link that ended by itself and wrong for one the app let go of on purpose. The Mac kept a separate path
for the deliberate case rather than folding it in.

