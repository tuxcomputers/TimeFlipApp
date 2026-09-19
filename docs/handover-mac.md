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

## 30. `quit_app` now reaches `platform_quit_app` -- **done here, and its macOS half is unrun**

**I did this one, which was yours.** It was yours because only a full run can exercise `lib.sh`, and it
became mine because the owner lifted the suite freeze on 2026-09-20 to have the scripted tests updated for
Linux -- and the rewiring of `lib.sh` through the ports had to happen anyway, with `quit_app` one of fifteen
call sites in it rather than a change of its own.

The change is the one your item proposed, unaltered: `quit_app` keeps `close_settings` and keeps the
wait-then-kill, and the pair in the middle became `platform_quit_app`, with its output printed and its
status reported rather than thrown away.

**Confirmed on Linux**: `platform_quit_app` quit a running app through its tray menu, and `run.sh` was then
watched quitting the app on its way into a run.

**Unconfirmed on macOS, and this is the part I need you to read.** On your side the port is the same two
calls in the same order with the reporting it already had, so I expect nothing to change -- but the whole
point of the item was that only a real run proves it, and I have not made one. **The next full Mac run is
what closes this**, and `99-quit.sh` and every script's teardown are where it would show.

**What else changed in that file that your run will be the first to exercise.** Fifteen call sites, all of
the same shape -- a direct `python3 scripts/ax-*.py` became a `platform_*` call that runs the identical
command on macOS. The ones worth knowing by name:

- **`press_return`** was inline AppleScript plus Quartz, duplicating what `ax-key.py` already does. It now
  calls `platform_key return`. Its comment records that a second copy is what let the two drift on run 145,
  which is exactly the argument for removing it.
- **`select_tab`** went from `press_desc` to `platform_select_tab`, which on macOS is `ax-press.py --desc`:
  the same command. It had to move because a GTK tab has no action to press at all.
- **`status_item`** goes through `platform_status_item`, which on macOS is the same
  `ax-dump.py --menu-bar | grep id=status-item`.
- **`menu_press <identifier>` is new**, and six presses in `02`, `12`, `55`, `61` and `99` now use it
  instead of `press open-settings` / `press quit-app` / `press toggle-cube-lock`. On macOS it is
  `ax-press.py <identifier>`, unchanged; on Linux nothing carries the identifier to the tray, so the port
  maps it to the title.

**If any of that misbehaves on your run, the port is the place to look and not the check**: every one of
these is a one-line `case` in `Tests/Scripted/platform.sh`.

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

## 43. `GoogleCalendar` is the calendar half in the core, and it has been run against a real account

**The companion to `GoogleConnection` from item 42**, and the last of the Google work that was macOS-only: settle,
create, rename, delete, and the check on a saved sign-in. Your six private methods, with their wording and their
orderings intact, and eleven tests where there were none.

**Every path ran against the real account from Linux on 2026-09-19**, which is the part worth knowing before you
adopt it: a calendar created, the sweep that follows putting **22 of 22** entries into it, a rename there and
back, the check answering *works* on a fresh launch, a sign-out that kept the calendar and a sign-in that
confirmed it rather than making a second. **Delete too**, by the owner rather than by me -- I had declined to
destroy a calendar I had just filled -- followed by a fresh create, a rename to `Facet-linux`, and a later
sign-in confirming that one.

**The settle-on-sign-in path was proven the same day too**, by signing out and back in on the real account: the
sign-out cleared the identity and the token and **kept** `calendar_id`, and the sign-in then answered
`Google calendar confirmed, Facet` against that same id rather than creating a second one. That is the pair of
decisions the branch exists for, end to end, and it is the one thing about this module I could not check when the
note above was written.

**Two orderings are worth re-reading in the adoption**, because they are the ones that cost you comments:

- **Google is asked first and the row follows**, in rename and delete both. The calendar lives in the user's
  account, so what is there is the real answer.
- **The id is cleared in one place only**, once Google has said the calendar is gone. Clearing it on a failed
  request is how somebody ends up with a second *Facet* and a third.

**`settle` still returns `.none` for no stored id**, which is your decision kept: signing in connects an account
and is not somebody asking for a calendar, and the entries recorded meanwhile sweep in whenever Create is pressed.

**One difference from your version, and it is the reason this one could be tested at all**: nothing here touches a
pane. Every method answers with `Settled` -- a calendar, none, or a `Dialogue` to show -- and what a surface does
about it is the surface's. That is the same split item 39 settled for `DeviceSettingRows`.

## 44. `switch-database.sh` had two faults, and the Mac's split was made by hand

Found while trying to make the Linux box runnable, and both are fixed -- but one of them says something
about your machine that is worth knowing.

**It hardcoded `~/Library/Application Support/Facet`**, so on Linux it resolved every path under a directory
that does not exist and reported the absence of a database nobody had asked about. It now takes `SUPPORT`
and `PROCESS_NAME` from `Tests/Scripted/platform.sh`, which is the one place the suite decides paths.
**Nothing changes for you**: that file resolves the same directory the constant did.

**Its refusal advised something that does not exist.** Given a plain `appdata.sqlite` it said *launch the
app once with Developer Mode on so it can migrate this into production.sqlite + a symlink*. Nothing in
`FacetCore`, `FacetMac` or `FacetLinux` does that -- `production.sqlite` appears in `Sources/` only in two
comments. **Your split predates the script and was made by hand**, which is why nobody had found out.

There is now a `-adopt` flag that performs the rename and the link, asked for by name for the same reason
`-clean` is. You have no use for it; the Linux box does.
