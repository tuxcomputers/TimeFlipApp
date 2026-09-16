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

## 29. `CLAUDE.md` says the scripted suite is set aside, and run 183 happened this afternoon

The section *The scripted suite is set aside until the Linux port is finished* says not to ask for a
run and to expect `All tests pass` to stay red. `Tests/Scripted/last-run-mac.md` records run 183
finishing at 17:01 today, 793 of 793, clean tree, gate clear.

Both cannot be current. **Item 25 asks for a run on that basis**, so if the suite really is still set
aside, say so and I will treat 25 as owed rather than outstanding. If it is back, the paragraph in
`CLAUDE.md` is what wants deleting -- and it is your file to delete it from.

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
