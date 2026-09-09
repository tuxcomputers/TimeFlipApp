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

## 11. Run `swift test` and say the four migrated suites still pass there

**Four test files changed framework on 2026-09-09 and they run on both machines.**
`DeviceEventRecorderTests` (35 tests), `FaceColourSyncTests` (22), `TimeEntryRecorderTests` (18) and
`DeviceSettingsSyncTests` (18) moved from `@MainActor XCTestCase` to `@Suite @MainActor` swift-testing, which
is what took them off `Package.swift`'s Linux exclusion list. **They were already running on the Mac**, since
`testsThatCannotRunOnLinuxYet` is `[]` there -- so unlike handover 10, this change is not inert on your side
and I cannot check it from here.

**What changed in each, beyond the assertions.** `setUpWithError` became `init() throws`, losing the
`MainActor.assumeIsolated` wrapper that a `@MainActor` init does not need. `tearDown` became a **non-isolated**
`deinit` holding only `database.remove()`, the property-nilling having been what `assumeIsolated` was for, and
`database` changed from `TemporaryDatabase!` to a `let` so a non-isolated `deinit` may read it. That is exactly
the shape `DevicePairingRecorderTests` has had since 2026-09-07, which is where it was copied from.

    swift test

**Three numbers.** The total, which should still be **1,751** -- the same tests, not new ones -- and the
XCTest/swift-testing split, which should move by 93 as those four cross over. And whether all four suites
report as passed rather than merely absent.

**The one thing I would look at first if a count is short.** swift-testing runs tests in parallel where XCTest
ran each class serially, and these four each bootstrap a real database per test. That is the same arrangement
the 22 already-migrated suites use, so it should be fine -- but these are the first *recorder* suites to do it,
and `TimeEntryRecorderTests` drives two recorders against one connection.

**Also worth a sentence: the assertion conversion was mechanical**, 264 of them across the four files by a
converter that counted its output against the original per file (24, 27, 56, 157 -- all matching). It
parenthesised no operand, meaning none held a loose top-level operator, and it flagged no non-literal message.
If something fails, a rebound `==` is the first thing to rule out and the least likely.

## 12. Re-stamp the scripted suite, because the manifest changed

**`Package.swift` is watched by `scripts/check_interactive_checklists.sh`, so CI is red on this branch.**
Confirmed here:

```
./scripts/check_interactive_checklists.sh --branch feature/linuxPort
  -> the app or the checks have changed since that run:
       Package.swift
```

The stamp is run 173 at `079c3b8`, passed, 32 of 32. Nothing under `Sources/`, `Tests/Scripted/` or
`database/` has moved -- `Package.swift` is the only watched path in the diff.

**This is the acknowledged cost of that watch rather than a surprise**, and the comment at
`check_interactive_checklists.sh:212` names it exactly: "The cost is a manifest edit that cannot affect macOS
at all still asking for a run with the cube." That is this edit. What changed in the manifest is the Linux
exclusion list -- four files removed from it, and `mainActorTests` renamed to `mainRunLoopTests` because the
blocker turned out to be the run loop rather than the framework. On macOS `testsThatCannotRunOnLinuxYet` is
`[]`, so none of it can alter what your build contains.

**So this needs a cube and twenty minutes, and it is yours because the Linux box has no app to drive.** If you
would rather not spend them on a manifest edit, say so in the item and leave it: the alternative is narrowing
the pathspec so it ignores changes confined to the `os(Linux)` branch, and the comment there already argues
against that -- a pathspec is textual and a gate that parses what it guards fails open when the parsing is
wrong. I would not change it on the strength of one inconvenient run.
