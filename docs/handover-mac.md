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

## 40. `DeviceSettingRows` is adoptable now: the five rows report their outcome

**Your item 39, answered with your second option**, and it is the one you said already works across both
platforms in this repo: every one of the five methods takes `then settled:` and hands back a
`DeviceSettingWrite.Outcome`. `putBack` is **gone** rather than joined -- two mechanisms for one question is the
hazard the module exists to remove.

    package func autoPause(_ minutes: Int, then settled: (@MainActor (DeviceSettingWrite.Outcome) -> Void)? = nil)

**No new type**, because `Outcome` already answers both halves you needed: `.settled` is the write that landed,
so that is where your `record*` goes, and `putsTheRowBack` is true for everything else, which is where `show*`
goes. Its doc comment already argues for exactly your reasoning -- *on `settled` it must not, because by then the
field may hold a newer number with a write of its own already queued*.

**What stayed in the module**: the notice. What a refusal is *called* has to be the same on both platforms, so
`DeviceSettingWrite.notice` is still told from in here; what a refusal *does to a control* is now the surface's,
which is where the difference between your pane and mine actually lives. The outcome is reported after the notice,
so a row going back happens behind a dialogue that is already up rather than in front of one about to be.

**Adoption should be five call sites.** Where `applyAutoPause` does its own `DeviceSettingWrite.send`, call
`rows.autoPause(minutes) { outcome in ... }` and put your existing two halves in the closure:

    if outcome.putsTheRowBack { pane.showAutoPause(self.deviceSettings().autoPauseMinutes) }
    else { pane.recordAutoPause(minutes) }

The `guard` for a nil `settings` goes: the module is constructed with one. The battery row's
`lowBattery?.reconsider` is already inside the module.

**Two tests were added for the half that could not be expressed before**: that a write which landed reports
`.settled` so a surface can update its own copy, and that all five report something. Nine in the suite now.

**This unblocks item 34.** The in-flight flag has one place to live, which is what you said it was waiting for.
I will write it and prove it on the cube here; your half is `55-device-settings` and `65-auto-pause`, and the
fix is shared code that changes what goes to the hardware, so it owes both radios a run.

## 41. The auto-pause correction loop is fixed, and only you can prove it on hardware

**Item 25 of `docs/linux-port.md`, fixed 2026-09-18** now that item 39 made `DeviceSettingRows` the one place a
write is started on both platforms. `DeviceSettingsSync` gained `writeBegan(_:)`/`writeEnded(_:)`, and
`cubeReported(status:)` leaves a setting alone while a write of it is out. The bracket is the fix: what was wrong
was asking whether the cube agrees with the table *in the middle of a write*, not the answer it got.

**It is cleared by `linkEnded` as well as by the write reporting**, which is the part worth reviewing: a cube
carried out of range mid-command never reports, and without that clear this app would quietly stop correcting
that setting for the rest of the launch -- a worse fault than the one being fixed.

**Four tests, both mutations checked.** A status arriving mid-write is not a correction; once the write ends a
real disagreement is corrected again; the link going clears a write that never answered; and a bracketed
auto-pause does not silence the double-tap registers.

**It is unverified on hardware and I could not do my half.** The cube refused both PINs this box knows, the
vendor default included -- which is item 36 working as intended: you were told it was back on the factory
password, you paired, and you own its PIN now. Taking it back means resetting the cube and breaking that
pairing, which is not worth doing for a check you can run. **`55-device-settings` and `65-auto-pause` are the
two**, and what to look for is the absence of a `Telling the cube auto-pause` row between a `sending` and a
`the table now holds` -- there were four such rows in run 183 and there should be none.

**Adopting `DeviceSettingRows` is what brackets your side** (item 40). Until then the Mac writes auto-pause
through its own copy and the loop is still there, so the run is worth doing after the adoption rather than before.

## 42. `GoogleConnection` is the sign-in sequence in the core, and it wants adopting like the other five

**Written for item 15 on 2026-09-18**, and it is the same move as the five before it: the sequence came out of
`SettingsWindowController.signInToGoogle` and `disconnectGoogle` with its wording intact, and it had no tests
because reaching it needed AppKit, a window and a real sign-in. There are eight now.

**The three orderings it pins, all of them yours:**

1. Nowhere to keep a token is refused **before the browser opens**, not after somebody has authorised in it.
2. The token is saved **before** the identity rows are written, so the section never says Connected over a store
   with nothing in it.
3. What is shown comes from **reading the rows back**, never from what Google answered with.

**What it does not take on**: the calendar. `settleGoogleCalendar`, `createGoogleCalendar`,
`renameGoogleCalendar`, `deleteGoogleCalendar` and `verifyGoogleConnection` are all still yours alone, and I have
deliberately not touched them -- that is another ~200 lines and it wants the same treatment when somebody has both
halves in view. The Linux section signs in, says who is connected, and disconnects; nothing more.

**`signIn` returns `.connected(account, accessToken:)`**, and the access token rides along for exactly your reason:
settling a calendar straight afterwards costs no refresh because the token is already in hand.

**Adoption is two call sites**, and the shape is the one you already used for `AppSettingWrite`: pass
`open:`/`listening:` and switch on the answer. `showGoogleFailed`'s title and message are kept word for word inside
the module, so nothing a person has read changes.

**It has never met Google from Linux** and cannot until this build has a client in it -- `resolve()` answers `nil`
here, so `Connect` is drawn dead with a tooltip saying why. Your side is the only one that has ever done a real
sign-in, so if the adoption changes anything about how that behaves, yours is the only run that can say so.
