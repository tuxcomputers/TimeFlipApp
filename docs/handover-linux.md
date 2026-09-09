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

---
## 10. Run `swift test` and say what the four newly-included suites do there

**Ten test files were excluded from this platform by an import they never used**, found on 2026-09-09 and
written up as candidate 7 of [architecture-review-2026-09.md](architecture-review-2026-09.md). Each carried
a `@testable import FacetMac` and used no type from it, which is enough on its own to keep a file out of a
build with no such module, so the import was what excluded them rather than the reason `Package.swift` gave.
The imports are deleted, and `Package.swift` has gone from 48 exclusions to 44: **38 platform-bound, plus a
`mainActorTests` list of 6 that is back and now names its own blocker.**

**Four files came off the list and this machine is the only one that can check them:**

    DeviceLoginRulesTests      25 tests
    DeviceReconnectRulesTests  17 tests
    PortableSHA256Tests         5 tests
    CubeFirstReadingTests       5 tests

**Why it has to be you.** On macOS `testsThatCannotRunOnLinuxYet` is `[]`, so the list is inert there and the
Mac cannot exercise this change at all. 1,751 tests pass here with the imports gone and the manifest parses,
and neither fact says anything about your build. This is the gap `CLAUDE.md` describes: green on one machine
and broken the moment it runs on the other.

**What was checked before asking**, so you know what is already ruled out: none of the four is a `@MainActor`
`XCTestCase`, which is the case that aborts a whole run at load time; none mentions `URLSession`, `NSImage`,
`CoreGraphics`, `Security` or a `CB*` type; and `PortableSHA256Tests` guards `import CryptoKit` with
`#if canImport`, with both `SHA256.hash` uses inside a second guard at lines 74 to 96.

```sh
swift build --build-tests      # the four should compile here for the first time
swift test                     # and the totals should move by 52
```

**The ask is three numbers and one judgement.** How many tests run now against the 873 of 2026-09-07, whether
all four suites are among them, and whether anything in them fails for a reason that is really about this
platform rather than about the test. `PortableSHA256Tests` is the one worth a sentence either way: it exists
because there is no CryptoKit here, it backs the PKCE challenge in Google sign-in, and until now it had never
run on the platform it protects.

**If one of the four does not compile, leave this item and say which.** That is a finding about what is
portable, and it belongs in [linux-port.md](linux-port.md) rather than being worked around: put the file back
on `platformBoundTests` with the reason attached, since a list that says why is the whole point of the change.

**The six on `mainActorTests` are not part of this**, and they are the larger prize: 110 tests, unblocked by
migrating each file to swift-testing, which is item 6 of `linux-port.md` and has a queue again. Worth knowing
why they were missed, because it is a fault in the lists rather than in the files: a suite sitting on
`platformBoundTests` was never a candidate for that migration, so the migration emptied its own queue while
six migratable suites sat hidden on the other list.

