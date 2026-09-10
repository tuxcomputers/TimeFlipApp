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

---

## 15. Candidate 1 of the architecture review: put the radio seam below the sequencing

**Yours because this box cannot compile the files it rewrites.** `swift build --target FacetMac` here answers
`error: no target named 'FacetMac'` -- the Linux graph has no such target -- so `DeviceLogin.swift` (1,482
lines) and `BluetoothRadio.swift` (1,418) are 2,900 lines I can neither build nor test, let alone drive
against a cube. The candidate itself is written out in
[architecture-review-2026-09.md](architecture-review-2026-09.md) with the five clusters, their line numbers,
the budgeted-twice argument and a *what it must not break* section; this item is what has changed around it
rather than a restatement.

**The diagnostic that was supposed to justify it came back negative.** *The sequence worth doing them in*
offered candidate 2 as the cheap evidence: if `DeviceReconnector` proved awkward to drive through
`CubeRadio`'s members, that would show the seam was in the wrong place. Candidate 2 is done, and it was not
awkward -- 64 lines of double, nothing contorted. That does not weaken candidate 1, because the two are seams
for different things: `CubeRadio` serves the reconnect loop, and candidate 1 is about the seam under the
protocol sequencing, which `CubeRadio` never touches. **So it has to be argued on its own terms**, and the
review now says so where it previously promised the opposite.

**The payoff is not what it might look like, and I checked rather than assuming.** It is tempting to expect a
crowd of test files to come off the Linux exclusion list. They will not. Of the 37 there:

    30  AppKit only            unaffected by this candidate
     3  AppKit and the radio   still blocked by AppKit afterwards
     1  the radio alone        BLETraceTests.swift, which would come off
     3  neither, on inspection CubeNotFoundOffer (a FacetMac alert),
                               SettingsTab (a FacetMac type), and
                               GoogleOAuthRulesTests, which is mine to fix

So the case for it is the two things the review already gives, and they stand on their own: **~1,480 lines of
sequencing that has no unit test and cannot get one** through the current interface -- `DeviceLoginRulesTests`
says outright that a `CBPeripheral` cannot be built outside CoreBluetooth -- and **not writing it twice**,
`linux-port.md` item 10 having budgeted 600-1000 lines to reimplement exactly that list behind BlueZ.

**Two patterns landed on 2026-09-09 that this should copy rather than reinvent.**

- **A timer moving into `FacetCore` needs a `fire()`.** On Linux a `@MainActor` swift-testing test does not
  run on the main thread, so a `Timer` on `RunLoop.main` never fires and a suite that waits on one fails
  silently. Four modules now expose the timeout body as a method the tests call -- `HistoryTimer.fire`,
  `WriteDebounce.fire`, `LowBatteryWatch.fire` and `DeviceReconnector.attempt`. Anything in the reach, the
  reset proof or the command deadline that arms a timer will meet this the moment its tests run here.
- **`InMemoryCubeRadio` is the worked example** of the double the candidate's last paragraph asks for ("an
  in-memory adapter makes the whole of the above hermetic"). It also shows the trap worth avoiding: the suite
  it replaced built a concrete `BluetoothRadio` and stayed honest only because `device_uuid` was empty, so
  the attempt stopped before the radio was touched. A seam with one adapter is a seam nothing is holding open.

**And the part I cannot help with at all.** This is the change where the scripted suite being set aside costs
the most. It moves the code that talks to the cube, and `CLAUDE.md`'s *what it must not break* has two
measured traps inside it: a `0x10` answer carries no echoed command byte, so it is trustworthy only when read
strictly after its own acknowledgement, and a locked cube reports itself paused whatever its pause byte says,
so pause is confirmed before the lock is sent. Both live in the code being moved and neither has a unit test
today. The device rename is the precedent nobody wants repeated: green everywhere and the cube unreachable on
the next launch, because reconnecting is a scan and nothing in `swift test` scans.

**So my recommendation, for what it is worth from the machine that cannot run it:** do not land this while the
suite is set aside, or bring the suite back for it specifically. A refactor of the radio verified only by
`swift test` is the one shape this repository has already paid for twice.

**Part done, on a branch, and the hardware half is not done. Seen at `0640277`, worked 2026-09-09 into the
night.** `feature/commandChannel` is pushed, two commits off this branch's tip, and deliberately not merged:
your recommendation not to land candidate 1 while the suite is set aside is the right one and I have followed
it.

**What is done: the command channel, which is one of the five clusters.** `CubeCommandChannel` in `FacetCore`
now holds the queue of whole write-and-await exchanges, the pending slots, the read-back sequencing and the
deadline. `DeviceLogin.swift` is 1,315 lines rather than 1,477, `send` and `askStatus` are two lines each, and
the delegate's two dispatch points lost their branches, because which of two writes an acknowledgement belongs
to is not a question anything at the delegate can answer.

**It took both patterns you pointed at.** The transport is two closures and the deadline is `fire()`, so
nothing in its tests waits on a run loop, which is your `@MainActor`-is-not-the-main-thread finding applied
before it could bite. `InMemoryCubeRadio` was the model for the doubles.

**16 tests, and they bite, which is the part worth having.** Three mutations were tried and all three fail the
suite: dropping the read-only-after-its-own-acknowledgement guard turns a stale value on the characteristic
into "the cube confirms it took"; swapping the `isReadingBack` branch breaks 27 assertions; and calling the
completions before clearing the pending slots fails one line. **That third one survived the first pass**, and
the reason is worth carrying into the rest of the candidate: `finishExchange` ends with `startNextIfIdle`, so a
slot left full merely delays the next write by a hop rather than losing it. Only asserting that the lock has
*already gone out* by the time the pause's completion returns pins the ordering `CubeLock` depends on. A test
that checks "it went out eventually" would have passed the bug.

**One thing the extraction found rather than assumed.** The queue serves four kinds of exchange, not two: the
factory reset and the `0x17` double-tap read are on it as well. Their state and deadlines stay in `DeviceLogin`
where their bytes are, so the channel has `enqueueOther`, `isOtherExchangeInFlight` and a package
`startNextIfIdle`. Those three are the part of its interface that is still a seam waiting to close, and its own
doc says so: they go the day those two move in too.

**Verified on the cube, 2026-09-10, once the owner quit his session and cleared the way.** Run against a copy
of the production database with `appdata.sqlite` repointed at it and put back afterwards; the real file is
byte-identical, still 158 rows, its open paused segment untouched, and the cube is locked and paused exactly
as it was found. 371 debug rows, 69 of them the channel's.

**Five of the channel's paths ran, and the two measured traps are the ones the log proves.** The order on the
unlock is the whole point:

    command  Sending 04 02
    ble-rx   command: write acknowledged        <- acknowledged -> acknowledgedCommand
    command  Asking whether it took: 10         <- isReadingBack now true
    ble-rx   command: write acknowledged        <- the same signal, routed to askedForConfirmation
    ble-tx   commandResult: read requested      <- only here, after the question's own acknowledgement
    ble-rx   commandResult: 02 01 00 00 ...
    command  The cube confirms it took

That is a `0x10` answer being read strictly after the question that earned it, which is the trap: the
characteristic frequently holds the previous command's reply and the answer carries no echoed command byte.
And the relock went `06 01` confirmed, then `04 01`, so pause is still confirmed before the lock is sent.

**The paths exercised**: a read-back question sent and confirmed, a plain `0x10` question, a command with no
read-back defined, and one queued behind another (`the command 09 19 waits its turn, 1 in the queue`). The
resume also sends its second command from inside the first's completion, which is the `finishExchange`
ordering the mutation test pins.

**Still unexercised on hardware**: the deadline, a refused write, a read-back the cube denies, and `linkEnded`.
All four are covered hermetically. Face turns and double taps are not this cluster.

**So what is left of item 15 is the other four clusters and a run.** The reach and candidate order, the reset
proof, the history fetch and the PIN rotation machine are untouched. This item stays put.

## 23. Five files of yours changed from here and not one of them has been compiled

**The Linux port needed things that were written down inside `FacetMac`**, and moving them is what item 20 of
`handover-linux.md` asked for in one case and what the two-copies rule forced in the others. `FacetMac` is not in
this platform's package -- `swift build --target FacetMac` answers `error: no target named 'FacetMac'` -- so
every one of these is unverified here and `swift build && swift test` on your side is what says they are right.

**What changed, and why each one had to:**

- **`Sources/FacetMac/BLETrace.swift` is now the `CBUUID` spellings and no wording of its own.** All ten
  `ble-tx`/`ble-rx` rows moved to `FacetCore/BLETrace.swift`, keyed on UUID strings. They are read back by
  `Tests/Scripted` with `LIKE` and `GLOB`, which makes them interface, and BlueZ writing a second copy would have
  been two traces diverging one row at a time. **Every wording is byte-identical**; the errors are turned into
  strings on each side, which is the only real seam.
- **`TimeFlipUUIDs.name(for: CBUUID)` is deleted**, nothing calling it once the rows named their own UUIDs from
  the core's one table. That is the answer `feature/commandChannel` got for `linkEnded()`.
- **`DevicePane.Values.seeded` reads its five device settings from `DeviceSettingsSync.Stored.seeded`.** Those
  numbers are `database/011_setting.sql`'s own seeds and a second composition root needs them; two copies of a
  seed diverge the next time the DDL moves one. The fields of `Stored` are `package` now so they can be read.
- **`StatusItemMenu.openSettings` is optional**, and `nil` means the Settings line is not drawn. Your call site
  passes a closure, so nothing changes for you. It is there because this platform has no window to open and a
  line that opens nothing is the fault `choose: nil` already rules out one level down.
- **`BLETraceTests` came off `platformBoundTests`** (33 files to 32) and no longer imports `FacetMac` or
  CoreBluetooth: what it checks is the hex rendering and the name fallback, both core now.

**What I would check first**, in the order the risk runs: that `FacetMac` compiles at all, that
`BLETraceTests` and `MenuBarControllerTests` still pass, and that the Device tab still shows the seeded numbers
on a fresh database.

**And the one that only a scripted run can answer**, whenever the suite comes back: the `ble-tx`/`ble-rx` rows
are what `51-device-connect` and its neighbours read, and I have moved every one of them between files. The
wordings are unchanged and `BLETraceTests` checks the rendering, but neither of those is the same as a check
that actually matched one.

## 24. There is a gate now that fails on your side when an isolated XCTestCase is written

**`AnIsolatedXCTestCaseAbortsTheLinuxRunTests` runs on both platforms and will fail on yours**, which is the
point of it rather than a side effect.

**What it is for.** On Linux an `@MainActor` `XCTestCase` aborts the whole test executable at load time --
corelibs-XCTest reflects a test method's type and an isolated one does not cast -- so one of them costs every
other suite in the binary. On 2026-09-11 three had appeared since the suite was last cleared on 2026-09-09, and
all 671 XCTest tests reported nothing at all. `docs/linux-port.md` has the measurement.

**The attribute costs nothing on your side**, which is exactly why it keeps coming back: the author cannot see
it, the machine that can is not the one being typed at, and the crash names one class while destroying the run
of every other. So the check fails at the moment the attribute is written rather than at the next pull.

**Two ways out and it says which to take.** If the subject really is `@MainActor`, make the file a
`@Suite @MainActor` swift-testing suite -- `QuitSequenceTests` is the worked example and `docs/linux-port.md`
has the conversion table. If it is not, delete the attribute: two of the three found on 2026-09-11 were
carrying isolation left behind by a subject that had moved into the core and stopped touching AppKit, which the
ports remodel will keep producing.

**It reads the exclusion list out of `Package.swift` rather than keeping a copy**, so a file coming off that
list is checked from that moment without anybody remembering to say so.

**Three files changed to satisfy it, and their assertions are untouched**: `QuitSequenceTests` became a
swift-testing suite, `StatusItemTitleTests` lost a class-level `@MainActor` it stopped needing when
`StatusItemTitle` moved into the core, and `CubeNotFoundOfferTests` lost it from three methods that were
asserting against a `Dialogue` value rather than an `NSAlert`.

**`HandDrivenScheduler` gained two things while I was there**, both of which your suites use: `tickAll` now
skips a wake cancelled earlier in the same pass, and there is a `tickAll(after:)` for a subject holding several
wakes at once. The first is a bug fix -- a module that arms a poll and a deadline together cancels the second
from inside the first, and firing it anyway runs a timeout whose work has already happened.
