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
5. **19, compose the device half.** ⇐ **the milestone.** Written and booted 2026-09-11, and the cube
   answered it on 2026-09-13. Open on one physical turn of the cube and nothing else.
6. ~~**20, the menu bar onto the core modules**, then **21, the dialogues.**~~ Both done 2026-09-11.
7. **22 is not a task**, it is a warning about the one part of the Mac that is not ready for you.

~~**Five more arrived from the Mac after this list was written.**~~ **All five done 2026-09-13.** 23 and 24
were edits to this side's files that nobody had compiled, and they compile; 25, 26 and 27 were the same offer
in three places -- a decision written independently here that now exists once in `FacetCore` -- and all three
were taken. Two of them were not merely duplicates: the reach here had no settle wait and never paid for its
own shortcut, and the narrowed `togglePause` left a menu item that looked live and did nothing.

## 19. Compose the device half in `main.swift`, and the app starts working

> **Run against the cube on 2026-09-13, and almost all of it is confirmed.** (Linux.) What is left is one
> physical turn of the cube, which nobody has made yet; everything reachable without one is done.
>
> **Confirmed on the hardware, in the order it happened.** The scan found the cube by name and ordered the
> room; a later launch had the remembered handle cut the window short, which is `CubeReachSequence`'s
> shortcut working over BlueZ. The vendor default was accepted, the PIN was rotated to six fresh digits,
> the cube proved it by taking a second login on the new one, and `SecretToolStore` kept it. `paired`,
> `device_uuid`, `device_name`, `device_info` and `connection` were all written, `device_uuid` holding
> `E8:DB:D8:CF:F9:0F` verbatim. The clock was set and confirmed by `0x07`; the four Device Information
> strings, the charge and all eight TimeFlip characteristics followed. Twelve `0x11` face colours, LED
> brightness and blink period went out, and the cube's `systemState` requests were answered as they
> arrived. History frames came back, `device_event` filled, and **a finished segment became `time_entry`
> 1 -- eighteen seconds filed under Break**. A later launch reconnected on the stored PIN with no help.
> The quit sequence ran whole: pause, read back, lock, read back, let go.
>
> **Every control was reached with no mouse**, through `com.canonical.dbusmenu` on the tray item, which is
> what `MenuBar`'s own comment said a scripted check would do. Pair, Pause, Unlock and Quit all landed.
>
> **What is still owed is the face-change path**, and only that: `onFace` firing on a turn, a segment
> closing on one category and opening on another. Every `device_event` row so far is face 8. The cube is
> paired, unlocked and live on this box, so it is one turn away.
>
> **The open measurement this item named cannot be taken here yet.** Whether a `0x15` rename moves BlueZ's
> `Name` the way it moves CoreBluetooth's needs something that renames the cube, and renaming is a Device
> tab control on the Mac and a control this platform does not have. `BlueZCubeGatt` still reports a device
> `PropertiesChanged` as `nameArrived`, so there is somewhere for it to show up when there is a way to ask.
>
> **Three faults came out of the run and all three are fixed**, none of them visible to the 737 hermetic
> tests: the tray menu was built once at launch and never again; a quit reported the cube as having gone
> away and armed a reconnect into a dying process; and `CubeCommandChannel` answered a read-back on
> whatever arrived first rather than on what it read, which cost every login the cube's `0x10` state and
> produced one false report that a command had been refused. The last is `FacetCore` and is
> `docs/handover-mac.md` item 25.


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
