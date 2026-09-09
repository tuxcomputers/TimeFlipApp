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

## 14. The last 17 tests want a `fire()`, not an injected `RunLoop`

**`WriteDebounce` and `LowBatteryWatch` are the two files left on `mainRunLoopTests`**, 17 tests, and you
measured why: a `@MainActor` swift-testing test does not run on the main thread here, so the `RunLoop.main`
timer both of them schedule never fires. The review calls the open question "whether they should take their
`RunLoop` as a parameter". **They probably should not, and this codebase already answered it a different
way.**

`HistoryTimer` has the same `RunLoop.main.add(timer, forMode: .common)` and its suite runs green here. The
difference is one method:

```swift
func fire() { … }        // HistoryTimer.swift:129 -- the timeout body, on its own
self?.fire()             //              :165 -- all the Timer closure does
```

and its own doc says the bargain out loud:

> "The timeout is driven by calling `fire()` rather than by waiting for a run loop, so the re-arming is
> asserted in milliseconds instead of minutes. What that skips is `Timer` itself, which is the part with no
> decisions in it."

**So the seam belongs at "the timeout happened", not at "here is a RunLoop".** Split the timeout body out of
the closure in each of the two, let the tests call it, and they stop touching a run loop at all rather than
needing one that behaves. Smaller than threading a scheduler through two initialisers, and it makes the two
files look like the third instead of like a special case.

**What it does not buy, and say so at the call site rather than leaving it implied:** `Timer` itself stays
untested, exactly as `HistoryTimer` accepts. On the Mac the scripted suite covers both behaviours for real,
the debounced setting writes and the low battery blink.

**Yours if you want it.** You can prove the 17 run, which is the whole point and something this machine
cannot do; it is a pure `FacetCore` change, so it builds and tests there; and you found the cause. The Mac's
half is `swift test`, which is cheap.

**One caution.** This is production timer plumbing in two modules the app really uses. Moving a closure body
into a method it then calls should change no behaviour, but "should" is doing work in that sentence, so keep
the `Timer` construction and the interval exactly as they are and let the diff be the extraction and nothing
else. Confirmation on real hardware is not available for a while: the scripted suite is set aside for the
length of the port (`CLAUDE.md`, *The scripted suite is set aside until the Linux port is finished*), so this
lands unverified on a device deliberately, and that is worth a line in the commit rather than silence.

**And a finding while looking, which is the more useful half.** Five `FacetCore` modules reach for
`RunLoop.main`, not two:

| Module | Its tests on Linux | Has a `fire()` |
| --- | --- | --- |
| `HistoryTimer` | run green | yes |
| `DailyLimitWatch` | run green | **no** |
| `WriteDebounce` | excluded | no |
| `LowBatteryWatch` | excluded | no |
| `DeviceReconnector` | no suite at all | no |

`DailyLimitWatch` is the one worth a second look: it passes here only because its tests never drive the
timer, so that path is unverified on this platform and nothing says so. `DeviceReconnector` having no suite
is candidate 2 of the review, and its `RunLoop` is the backoff.

