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

## 34. Writing auto-pause sets the cube to the wrong value for three round trips, on both platforms

**Measured on the cube from this box, 2026-09-16**, driving the Device tab. Stepping auto-pause to 7 minutes
produced this, and the numbers are the real exchange:

    Auto-pause: sending 7m
    Sending 05 00 07                 -> command withResponse, acknowledged
    Asking whether it took: 10       -> commandResult: 02 01 00 07 ...
    The cube confirms it took: auto-pause 7m
    Telling the cube auto-pause 0m (the cube says its auto-pause is 7m and the table says 0m)
    Sending 05 00 00
    Auto-pause: the table now holds 7m

**Nothing is wrong with any one step, which is what makes it worth writing down.** `DeviceSettingWrite` writes the
table only *after* the cube confirms, which is the ordering the first design rule requires. The confirmation is a
`0x10` read. Every `0x10` answer reaches `DeviceSettingsSync.cubeReported(status:)`, including the one this write
asked for -- and at that instant the table still holds the old value, so the sync sees a disagreement it caused
and corrects the cube back to it.

**It converges, and that is the only reason it is not urgent.** The correction's own read-back starts the next
round the other way, and after three corrections the cube and the table both hold 7m. What it costs is three extra
round trips per write and a window in which the hardware is set to a value nobody asked for.

**It is not Linux-specific.** `BluetoothRadio.received(status:)` and `BlueZCubeRadio.received(status:)` are the
same seven lines and both publish every status; the Mac's Device tab writes through the same `DeviceSettingWrite`.
The reason it has never been seen there is that nobody has read a trace of an auto-pause write with the sync
running.

**I have not fixed it**, and the reason is the rule about device behaviour rather than nerve: the fix is in shared
code that changes what goes to the hardware, and the honest version of it -- the sync ignoring a status while a
write of that setting is in flight -- needs checking on both radios. I can test a fix here on real hardware the
moment you want one; what I cannot do is check CoreBluetooth.

**Where to look**: `DeviceSettingsSync.cubeReported(status:)`, and `DeviceSettingRows` (item 31's companion) as
the place a "writing this one now" flag would be set and cleared.

## 35. Four more core modules to adopt, alongside `CategoryEdits`

Item 31 asks for one; the other four arrived with the remaining tabs, and all five are the same shape -- a decision
lifted out of `SettingsWindowController` with its wording intact, and its first tests.

| Module | What it is | Tests | The Mac's copy |
|---|---|---|---|
| `FaceEdits` | What a click on a category means, the clock, the lock on the cube's face | 14 | `startTiming`, `assignToCube`, `togglePause`, `toggleFaceLock` |
| `ReportReadout` | The boundary a range is measured against, its totals, the entries behind one | 6 | `reportBounds`, `loadTotals` |
| `AppSettingWrite` | One App-tab row written and read back, and what a refusal is called | 6 | the `store(_:from:)` tail |
| `DeviceSettingRows` | The five Settings rows: which command each carries, which two send nothing | 7 | `applyPauseOnLock`, `applyBatteryWarning`, `applyAutoPause`, `applyLED*` |

**`FaceEdits` is the one worth doing first**, because of what its tests cover: both refusals -- a locked face and a
paired app that is not timing by hand -- have never had one, and the locked-face case is how it was found at all.
It was watched on hardware, producing a log row and nothing on screen.

**`DeviceSettingRows` is the one to read before item 34**, since it is where a write would say it is in flight.

**Two smaller things came out with them.** `SettingsMetrics` gained `windowWidth`, `windowDefaultHeight` and
`windowMinimumHeight` (item 32), and `ManualTimerRules`/`CubePauseState` symbol names are turned into characters in
one place on this side rather than two -- the Mac has one such place too, `StatusItemTitle`'s callers, and it is
already fine.
