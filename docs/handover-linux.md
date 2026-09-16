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
5. ~~**19, compose the device half.** ⇐ **the milestone.**~~ **Done 2026-09-13**: written and booted
   2026-09-11, and the cube answered every part of it two days later, down to a face turn filing a
   `time_entry`.
6. ~~**20, the menu bar onto the core modules**, then **21, the dialogues.**~~ Both done 2026-09-11.
7. **22 is not a task**, it is a warning about the one part of the Mac that is not ready for you.

~~**Five more arrived from the Mac after this list was written.**~~ **All five done 2026-09-13.** 23 and 24
were edits to this side's files that nobody had compiled, and they compile; 25, 26 and 27 were the same offer
in three places -- a decision written independently here that now exists once in `FacetCore` -- and all three
were taken. Two of them were not merely duplicates: the reach here had no settle wait and never paid for its
own shortcut, and the narrowed `togglePause` left a menu item that looked live and did nothing.

## 37. Put the cube-arrival clock resumes behind a named list, so a test can read them

**Your root has never had this bug and mine did, which is why I am asking rather than telling.**
`FacetMac/main.swift` resumed `dailyLimit` when a cube arrived and never `historyTimer`, so a Mac
launch whose cube turned up a minute later had a dead `fetch_history_interval_seconds` for the rest
of the session. That is item 28, which you found by reading my file. You read it right.

**Fixed here on 2026-09-16, and made checkable rather than just fixed.** The two calls are now a
named list beside `linkEnders`, which is its mirror -- one is what a link ending has to let go of,
the other what a link coming up has to put back:

    let clocksResumedOnLink: [() -> Void] = [
        historyTimer.resumeIfStopped,
        dailyLimit.resumeIfStopped,
    ]
    radio.onCubeReady = { _ in
        historyIngestor.refresh(because: "the link came up")
        for resume in clocksResumedOnLink { resume() }
    }

`ClockResumeFanOutTests` reads that list against every `FacetCore` module declaring
`resumeIfStopped()` and fails if one is missing, if the list is never iterated, or if it is iterated
from a moment other than the link coming up. Mutation-checked on all three.

**What I want**: the same named list in `FacetLinux/main.swift`. Yours does the job correctly today,
inline in `onLoginEnded`, so this changes no behaviour -- it only gives the test something to read.
The test's doc says it takes a second path rather than a second copy when that lands, which is the
note `LinkEndedFanOutTests` already carries for the same reason.

**Yours rather than mine because I cannot compile `FacetLinux`**, and editing your sources blind is
what items 23 and 24 cost us in the other direction. If `onLoginEnded` is the better moment on your
side -- you have an argument for it that I do not, `onCubeReady` being where mine has to go because
`connection` is written by then -- then say so and keep it there; the list is the part I am asking
for, not the callback.

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
