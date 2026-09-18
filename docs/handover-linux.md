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

**Six more arrived from the Mac on 2026-09-18**, numbered 40 to 45 and below the warning that is item 22.
**40 is the one to take first and the only one that is a plain task**: Google sign-in has never met Google from
that box, and everything it was waiting on has landed. 41, 42 and 45 are warnings rather than requests, and 43
and 44 are the state of two items you are already tracking.

~~**Five more arrived from the Mac after this list was written.**~~ **All five done 2026-09-13.** 23 and 24
were edits to this side's files that nobody had compiled, and they compile; 25, 26 and 27 were the same offer
in three places -- a decision written independently here that now exists once in `FacetCore` -- and all three
were taken. Two of them were not merely duplicates: the reach here had no settle wait and never paid for its
own shortcut, and the narrowed `togglePause` left a menu item that looked live and did nothing.

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

## 40. Sign in to Google from that box, which is now possible for the first time

**Everything item 15 was waiting on has landed, and the credentials are on your machine.** The owner copied
`~/.config/facet/google-client.json` across on 2026-09-18, so `GoogleCredentials.resolve` finds it at the second
of its three places and `Connect` is live rather than correctly dead. Item 16's Mac half went the same day, so
`GoogleOAuthClient` no longer picks a listener for itself and `SocketLoopbackListener` is what yours gets.

**So the flow has never met Google from this platform and now can.** What to watch, in the order it happens:

1. **The browser opens at all.** That is `main.swift`'s `open:`, and it is the one line of the sign-in that is
   yours rather than the core's.
2. **The loopback listener answers.** `SocketLoopbackListener` binds port 0 and reads the port back with
   `getsockname`; five shared tests drive it, but none of them has had a real browser on the other end.
3. **The redirect is accepted and the token is saved before the identity rows are written**, which is
   `GoogleConnection`'s second ordering and the one worth checking in the log rather than on screen.
4. **`CalendarSync` sweeps.**

**Managing the calendar will not work and that is expected**, not a fault to chase: `settleGoogleCalendar`,
`createGoogleCalendar`, `renameGoogleCalendar` and `deleteGoogleCalendar` are still macOS-only, which
`handover-mac.md` item 42 records as deliberately untouched. Sign in, say who is connected, disconnect. Nothing
more.

**Say what Google actually did**, in `linux-port.md` item 15, because nothing on either machine knows yet.

## 41. Not a task: `DeviceSettingRows` had a silent failure mode, and it was yours as much as mine

**Scripted run 187 spent nineteen minutes finding it and it cost a whole run.** Both `recording` closures in
that module take `[weak self]`, and where the module is deallocated while a command is in flight they returned
`false` **with no row at all**: no table write, no notice, no put-back, and nothing in the log saying why. It
read on the Mac as `63-led-settings` check 6 simply never seeing the table row after the cube acknowledged the
command.

**The Mac caused it by building the module per write instead of holding one**, which is fixed (`275fbd8`), and
**your side does not have that bug**: `FacetLinux/main.swift` builds `deviceRows` once and `DevicePane` holds it
as a `let`. This is a warning rather than a request.

**What changed in the shared file is that the silence is gone.** Both closures now capture `debugLog` beside
`self` and write `... the settings rows were released mid-write, so <value> is not recorded`. If that row ever
appears on your box, the pane has stopped holding the module and the write reported nothing.

**The lesson is the one `CLAUDE.md` already has a section for**, and it is why this is written down rather than
just fixed: 1,965 hermetic tests were green through the whole thing.

## 42. Not a task: I changed one string in `DeviceSettingRows`, and it has to stay changed

**`led`'s `tookIt` row said *which is all this command can be asked*.** It now says *and there is no read-back to
confirm it with*, which is the Mac's original wording.

**Not a preference: `63-led-settings.sh` check 8 matches that row in full**, and it needs a cube, so a module
written on your box cannot reword it and find out. It would have failed the first time anybody ran it. The other
four rows already matched the Mac word for word, so nothing else moved.

**If the Linux suite ever grows the equivalent check, it has to match the same string**, because there is one
module writing it for both platforms now.

## 43. Item 25's Mac half is done and proven, and your half is still owed

**Run 189, 2026-09-18**: `65-auto-pause` check 8, *and the cube was not corrected back mid-write*, passed. Run
183 had four such corrections and there are none. The Mac adopted `DeviceSettingRows` to get there, which is what
brackets that platform at all -- until it did, the fix you wrote was Linux-only and `linux-port.md` item 25 read
as fixed while the loop was still live here.

**Nothing has changed about why you cannot do your half.** The cube answers to the Mac's PIN
(`handover-mac.md` items 36 and 41), and taking it back means resetting the cube and breaking that pairing. The
item stays ticked on the strength of the Mac's run, and the Linux half is recorded as owed rather than done.

## 44. A Linux rename control is unblocked, whenever the Device tab wants one

**Item 17 landed and was proven on the cube 2026-09-18** (`66-device-rename`, all 22 checks), and with it the
last row of `architecture-ports-plan.md` item 6. `renameDevice` no longer spells the write sequence out for
itself.

**What that leaves you is a pane and its alerts.** `DeviceNameRules`, `DeviceCommandRules`,
`DevicePairingRecorder` and the write sequence are all core, so a Linux rename is the same shape as every other
row on that tab rather than a thing to reason out again.

**One detail to know before you write it**: `DeviceSettingWrite.send` gained `announcing`, which replaces the
default `label: sending value` row. Exactly one caller passes it, the rename, because `66-device-rename.sh`
matches `Renaming the cube to <name>` in full *and reads its row id* to prove the table was written after the
cube. Do not reach for it for anything else; the default scheme is the interface.

**The notices stayed on the Mac deliberately**, and yours will want its own: a rename is the only setting that
says something on **success**, and the only one that speaks where `nothingToSendTo` is silent everywhere else,
because a name that reached neither the cube nor the table has a filtered scan downstream of it
(`DeviceScanRules.isEligible`).

## 45. Not a task: `v_failure` in the test log is stale and will show you the wrong run

**It joins `script_old`**, which a schema migration left behind, where the live table is `script`. So it returns
failures from before the migration and silently omits recent ones. It cost two queries on 2026-09-18 before the
failure from the run that had just happened could be found.

**What works is joining `script` directly:**

```sql
SELECT s.name, c.sequence, c.description, c.detail
  FROM check_result c JOIN script s ON s.script_id = c.script_id
 WHERE s.run_id = (SELECT MAX(run_id) FROM run) AND c.verdict = 'fail';
```

**Not fixed, deliberately.** The view is created by `Tests/Scripted/testlog.sh`, and that layer is not edited
while the suite is low priority (`CLAUDE.md`). It is written here so the next person to read a failed run does
not lose the same ten minutes.
