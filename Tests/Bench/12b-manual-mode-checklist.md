# Manual Mode Checklist

### Last run - 2026-08-11 18:23 on the branch 'feature/inactiveID'

Covers **manual mode**: what happens when the app cannot reach the cube, and the user chooses to
time from the app instead. The mode lasts one launch, quitting is the only way out, and everything
it records goes through the same `device_event` -> `time_entry` pipeline a real cube's history does,
on a face of its own (13).

This side takes the route where **the device is there and refuses the app's PIN**. The other route,
nothing in range at all, needs Bluetooth switched off by hand and lives in `Interactive/12i`. Both
are worth having: they are different branches ending at the same dialog, and one of them has already
shipped a bug the other could not have found (see Bugs found and fixed).

**How the refusal is staged.** `config.json`'s `PIN` is what a dev build presents to a cube it is
already paired to. Setting it to a value the cube is not on makes the login fail while the scan
still finds the device, which is exactly the case under test. Nothing is written to the cube, and
the app's own rotation target is a separate compiled constant, so the cube stays on the PIN it was
paired with throughout and the file is put back in Teardown.

**Do not pair while the PIN is staged.** Pairing is the one place a password is guessed, and a
successful pair would rotate the cube and rewrite the file mid-run. No step here touches the Device
tab's pairing section, and Scenario D confirms the app itself has those controls switched off.

Requires a paired physical TimeFlip device and the app running with Developer Mode enabled and the
`debug` setting's `enabled` field `true`, same as every other checklist here.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`
Config path: `~/Library/Application Support/TimeFlip/config.json`

## Setup

**Preconditions:** the test database and the device connected, both established by
`Tests/00-test-setup.md`, which the supervisor always runs first.

- [x] Step 1: Confirm `db_type` reads **test** before anything writes to it.
```toml step
use = "method-24.a"
setting = "db_type"
expect = '{"type":"test"}'
```
- [x] Step 2: Capture the real PIN from `config.json`, so Teardown can put it back.
Everything after this depends on being able to restore it: get it wrong and the next launch cannot
reach the cube. Captured rather than assumed, because a re-pair may have rewritten it.
**Refuses to run if the staged fixture is already there.** A run that halts anywhere between
Scenario A Step 2 and Teardown leaves `123457` in the file, and a fresh run from the top would then
capture the fixture *as* the real PIN and have Teardown write it back permanently, leaving the app
unable to reach the cube and every later checklist failing in a way that points nowhere near here.
Restore the real PIN by hand first, then start again.
```toml step
[[actions]]
action = "shell"
command = "python3 -c \"import json,os; pin=json.load(open(os.path.expanduser('~/Library/Application Support/TimeFlip/config.json')))['PIN']; print('ok' if pin != '123457' else 'STAGED FIXTURE STILL IN config.json from a halted run -- put the real PIN back before running this')\""
expect = "ok"

[[actions]]
action = "shell"
command = "python3 -c \"import json,os; print(json.load(open(os.path.expanduser('~/Library/Application Support/TimeFlip/config.json')))['PIN'])\""
capture = "real_pin"
```
- [x] Step 3: Confirm the app can currently reach the cube with that PIN.
The premise of the whole checklist is that only the PIN is wrong afterwards. If the device is
already unreachable, every assertion below would pass for the wrong reason -- and Scenario A's proof
that the cube was *found* is what separates this file from `12i`.
Read from the live `connection` setting, not from the log. This asked
[Method 24.d](../Methods.md#method-24) for the newest `TimeFlip`-tagged message and expected the
login, which only holds if nothing else has been logged under that tag since. `00-test-setup.md`
ends by leaving the device unlocked and unpaused, and that verification is logged under the same
tag, so the newest row is reliably *not* the login: this step failed on its first run reading
`Lock verification confirmed: requested=OFF actual=OFF`. Elsewhere in the suite 24.d is safe because
the step provokes the message immediately before reading it; here nothing was provoked.
The flag is also the better question. "Is the app connected right now" is what the premise needs,
and a login row proves only that one succeeded at some point.
```toml step
use = "method-24.f"
setting = "connection"
field = "connected"
expect = "1"
```
`00-test-setup.md` ends by leaving the device unlocked and unpaused and logs that under the same
tag, so the newest row was `Lock verification confirmed: requested=OFF actual=OFF` and the step
could never pass. Reads the live `connection.connected` flag now, which is also the thing the
premise is actually about. Same fix in `Interactive/12i` Step 2, which was a copy of it.

## Scenario A -- a device that answers and refuses raises the offer

**Preconditions:** Setup complete: test database, device connected, the real PIN captured.

- [x] Step 1: Quit the app, so the staged PIN is read at the next launch.
`config.json` is read at startup, so editing it under a running app changes nothing.
[Method: Number 3](../Methods.md#method-3).
```toml step
use = "method-3"
```
- [x] Step 2: Stage the refusal by setting the PIN to `123457`.
One digit off the real one, deliberately: a value that is obviously a test fixture and obviously not
a real PIN. The Google keys in the same file are read and rewritten around it rather than the file
being replaced, because losing a client secret to a test fixture would be a bad way to find this out.
```toml step
[[actions]]
action = "shell"
command = "python3 -c \"import json,os; p=os.path.expanduser('~/Library/Application Support/TimeFlip/config.json'); d=json.load(open(p)); d['PIN']='123457'; json.dump(d,open(p,'w'),indent=2,sort_keys=True)\""

[[actions]]
action = "shell"
command = "python3 -c \"import json,os; print(json.load(open(os.path.expanduser('~/Library/Application Support/TimeFlip/config.json')))['PIN'])\""
expect = "123457"
```
- [x] Step 3: Capture the log baseline, then launch.
Everything asserted below has to be a row *this* launch produced: the same messages are sitting in
the table from earlier runs. Methods: [Number 24.b](../Methods.md#method-24),
[Number 2](../Methods.md#method-2).
```toml step
[[actions]]
use = "method-24.b"
capture = "before_staged_launch"

[[actions]]
use = "method-2"
```
- [x] Step 4: Confirm the scan **found** the cube.
The line that separates this run from `12i`'s. Without it, a refusal and an empty airspace are
indistinguishable from the offer alone.
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='scan' AND message LIKE 'eligible after scan:%' AND debug_log_id > $before_staged_launch ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "TimeFlip"
timeout_seconds = 60
```
- [x] Step 5: Confirm the cube answered and rejected the PIN.
A real `0x01` from the device, not a timeout: it was reached, it understood, and it said no.
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='scan' AND message LIKE 'none of the%' AND debug_log_id > $before_staged_launch ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "accepted this app's PIN"
timeout_seconds = 60
```
- [x] Step 6: Confirm the offer names the **refusal**, not an empty scan.
The regression this pins shipped once. Two callers race here -- the attempt's own result, and the
disconnect the refused probe causes -- and the one that knows the true answer lost by 3ms, so the log
blamed the absence of a cube that was on the desk. "Not in range" and "there and refused" are
different problems, and this line is the only place they can be told apart.
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='manual-mode' AND message LIKE 'Offering manual mode:%' AND debug_log_id > $before_staged_launch ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "refused this app's PIN"
timeout_seconds = 30
```
- [x] Step 7: Confirm the dialog is actually on screen with both answers.
An `NSAlert` raised by an app with no window open, which is the part least likely to survive a macOS
change. [Method: Number 29](../Methods.md#method-29).
```toml step
[[actions]]
action = "applescript"
script = """
tell application "System Events"
    tell process "TimeFlip"
        return (count of windows) & "/" & (name of every button of window 1)
    end tell
end tell"""
expect_contains = "Switch to Manual Mode"

[[actions]]
action = "applescript"
script = """
tell application "System Events"
    tell process "TimeFlip"
        return name of every button of window 1
    end tell
end tell"""
expect_contains = "Retry"
```
- [x] Step 8: Press **Retry** and confirm it scans again rather than giving up.
Retry is the whole reason the threshold was dropped to one failure: the cost of asking too early is
a click. It must produce a fresh scan, and land back on the same dialog while the PIN is still wrong.
[Method: Number 29](../Methods.md#method-29).
```toml step
[[actions]]
use = "method-24.b"
capture = "before_retry"

[[actions]]
use = "method-29"
button = "Retry"

[[actions]]
action = "wait_for_sql"
query = "SELECT COUNT(*) FROM debug_log WHERE tag='scan' AND message LIKE 'eligible after scan:%' AND debug_log_id > $before_retry;"
expect_contains = "1"
timeout_seconds = 90

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='manual-mode' AND debug_log_id > $before_retry ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Offering manual mode"
timeout_seconds = 60
```
and no scan ran for 99 seconds. The offer is raised from inside the connect task and puts up a
modal, so that task is still on the stack while the dialog is answered. Retry cleared the flag and
started a fresh attempt; the modal then returned, the old task carried on into its failure handling,
raised the dialog a second time, and `offerManualMode` -> `stopDeviceEvents` cancelled the new
attempt before its first line ran. `eventTaskGeneration` already existed for exactly this and was
consulted only by the task's `defer`; it is now checked **inside** the `MainActor.run` that acts on
the outcome. Checking before that hop was tried first on the device and changed nothing, because the
generation is still current on that side of the await.
- [x] Step 9: Press **Switch to Manual Mode** and confirm the session starts.
```toml step
[[actions]]
use = "method-24.b"
capture = "before_answer"

[[actions]]
use = "method-29"
button = "Switch to Manual Mode"

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='manual-mode' AND debug_log_id > $before_answer ORDER BY debug_log_id LIMIT 1;"
expect_contains = "Manual mode chosen"
timeout_seconds = 30

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='manual-mode' AND message LIKE 'Manual session started%' AND debug_log_id > $before_answer ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "face 13"
timeout_seconds = 30
```
- [x] Step 10: Confirm answering the question did not re-ask it.
The bug this pins was user-facing and shipped: the losing caller's offer sat blocked behind the modal
and fired the instant the dialog closed, putting it straight back up and tearing down the session
that had just started. The mode could only be entered by answering twice. Zero windows and no second
offer are the two halves of that.
```toml step
[[actions]]
action = "applescript"
script = """
tell application "System Events"
    tell process "TimeFlip"
        return (count of windows) as text
    end tell
end tell"""
expect = "0"

[[actions]]
action = "sql_query"
query = "SELECT COUNT(*) FROM debug_log WHERE tag='manual-mode' AND message LIKE 'Offering manual mode:%' AND debug_log_id > $before_answer;"
expect = "0"
```
- [x] Step 11: Confirm the menu bar shows a live display rather than the bare app name.
Manual mode reports its own `ConnectionStatus`, and the menu bar's three display rules read it. Read
literally as a disconnection, they emptied the status item to `TEST TimeFlip`.
[Method: Number 27](../Methods.md#method-27).
```toml step
use = "method-27"
expect_contains = "0:00:00"
```

## Scenario B -- timing a category from the Faces tab

**Preconditions:** Scenario A complete: the app in manual mode with a session running and no dialog
on screen.

- [x] Step 1: Open Settings from the dropdown and confirm it lands on **Faces**.
Manual timing is driven entirely from that tab, so it is forced open there on every open rather than
reopening wherever the window was last closed. Methods: [Number 6](../Methods.md#method-6),
[Number 11](../Methods.md#method-11).
```toml step
[[actions]]
use = "method-6"
item = "Settings..."

[[actions]]
use = "method-11"
tab = "Faces"
expect = "1"
```
- [x] Step 2: Confirm the tab is in its manual shape.
The left column's label reads `Timing` rather than `Top face`, and the device artwork is not drawn
at all -- there is no cube in this mode, so a picture of one would be reporting nothing.
```toml step
action = "applescript"
script = """
tell application "System Events"
    tell process "TimeFlip"
        set out to ""
        repeat with t in static texts of group 1 of group 1 of window "TimeFlip Settings"
            set out to out & (value of t) & "|"
        end repeat
        return out
    end tell
end tell"""
expect_contains = "Timing|"
```
- [x] Step 3: Click the first category row and confirm it starts the clock.
The click is a real CGEvent one at the row's centre: these rows expose no name, title or identifier
to accessibility, so the app's own `click`-tagged log is what proves which row was hit.
[Method: Number 7](../Methods.md#method-7).
```toml step
[[actions]]
use = "method-24.b"
capture = "before_pick"

[[actions]]
action = "cgevent_click_element"
element = "button 1 of group 1 of group 1 of window \"TimeFlip Settings\""

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='click' AND message LIKE 'Category %picked in manual mode%' AND debug_log_id > $before_pick ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "starting the clock"
timeout_seconds = 30

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='manual-mode' AND message LIKE 'Manual timing: category%' AND debug_log_id > $before_pick ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "on face 13"
timeout_seconds = 30
```
- [x] Step 4: Confirm the segment landed on face 13 and is still open.
A manual segment is an ordinary `device_event`, which is the whole point of the design: no second
kind of record, and the same conversion into `time_entry` a cube's history gets.
```toml step
[[actions]]
use = "method-24.c"
column = "device_face"
expect = "13"

[[actions]]
use = "method-24.c"
column = "finalised"
expect = "0"
```
- [x] Step 5: Confirm the duration is climbing.
Read from the status item's rendered title rather than a screenshot; two reads ten seconds apart is
what proves movement, which a single frame cannot. [Method: Number 27](../Methods.md#method-27).
```toml step
[[actions]]
use = "method-27"
capture = "duration_first"

[[actions]]
action = "shell"
command = "sleep 12"

[[actions]]
use = "method-27"
capture = "duration_second"

[[actions]]
action = "shell"
command = "test \"$duration_first\" != \"$duration_second\" && echo moved || echo stuck"
expect = "moved"
```
- [x] Step 6: Confirm the Faces tab and the menu bar agree.
Two views of one session, and the requirement was that they cannot disagree. The elapsed figure sits
under the play/pause control, inside the square, and is the same string the status item renders.
```toml step
action = "applescript"
script = """
tell application "System Events"
    tell process "TimeFlip"
        set out to ""
        repeat with t in static texts of group 1 of group 1 of window "TimeFlip Settings"
            set out to out & (value of t) & "|"
        end repeat
        return out
    end tell
end tell"""
capture = "faces_tab_row"
```
- [x] Step 7: Close the Settings window, so the next checklist starts with none open.
[Method: Number 23](../Methods.md#method-23).
```toml step
use = "method-23"
```

## Scenario C -- both pause controls drive the one timer

**Preconditions:** Scenario B complete: a category being timed, the clock running, no Settings window
open.

- [x] Step 1: Confirm the dropdown offers Pause and refuses Lock.
Pause survives manual mode because the thing it acts on moved into the app. Lock has no such half:
it is a device command with a device state behind it, and there is no device. This item was dead in
manual mode until the status item's right half had already been taught to pause, so the same gesture
had a live trigger and a grey one directly above it. [Method: Number 30](../Methods.md#method-30).
```toml step
[[actions]]
use = "method-30"
expect_contains = "Lock=false"

[[actions]]
use = "method-30"
expect_contains = "Pause=true"
```
- [x] Step 2: Pause from the dropdown and confirm the timer stops.
It routes to the manual timer's own path, not to the device command the ordinary pause sends -- which
would be refused anyway, manual mode never being connected.
[Method: Number 6](../Methods.md#method-6).
```toml step
[[actions]]
use = "method-24.b"
capture = "before_menu_pause"

[[actions]]
use = "method-6"
item = "Pause"

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='manual-mode' AND message LIKE 'Manual timing:%' AND debug_log_id > $before_menu_pause ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "stopped"
timeout_seconds = 30
```
- [x] Step 3: Confirm the duration is frozen, not merely slower.
```toml step
[[actions]]
use = "method-27"
capture = "paused_first"

[[actions]]
action = "shell"
command = "sleep 12"

[[actions]]
use = "method-27"
expect = "$paused_first"
```
- [x] Step 4: Confirm the item now reads Resume and is still live, with Lock still dead.
A live item saying `Pause` over a stopped timer would be the same lie the greyed-out case exists to
avoid. [Method: Number 30](../Methods.md#method-30).
```toml step
[[actions]]
use = "method-30"
expect_contains = "Resume=true"

[[actions]]
use = "method-30"
expect_contains = "Lock=false"
```
- [x] Step 5: Resume from the status item's right half and confirm it drives the same timer.
The other trigger for one gesture. It fires immediately rather than waiting out the double-click
interval, because that wait exists only to let a second click upgrade to lock, and manual mode has
nothing to lock. Methods: [Number 7](../Methods.md#method-7), [Number 8](../Methods.md#method-8).
```toml step
[[actions]]
use = "method-24.b"
capture = "before_item_resume"

[[actions]]
action = "cgevent_click"
target = "status_item_right"

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='click' AND debug_log_id > $before_item_resume ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "manualMode -> togglePauseImmediately"
timeout_seconds = 30

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='manual-mode' AND message LIKE 'Manual timing:%' AND debug_log_id > $before_item_resume ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "running"
timeout_seconds = 30
```

## Scenario D -- the Device tab cannot reach a device that isn't there

**Preconditions:** Scenario C complete: the app in manual mode with the timer running, and **no
Settings window open** -- Scenario B closed the one it opened, and Scenario C is driven entirely from
the status item. This scenario opens its own.

- [x] Step 1: Open Settings on the Device tab and confirm Forget Device and Reset Device are both
      disabled.
These are deliberately **not** gated on being connected -- forgetting a cube that is out of range is
an ordinary thing to want. Manual mode is the exception, and it fails quietly: a virtual device
answers both. Reset is routed against the protocol so `0xFF` lands on the stand-in, is confirmed, and
discards the real cube's stored name and uuid; Forget reports success having sent nothing, clears the
stored password and unpairs, leaving the cube holding a PIN whose only copy has just been deleted.
Neither is recoverable without the device in hand.
The open is this step's own: it read the window straight away and failed with `-1728`, having
inherited an assumption from Scenario B that no longer held once B learned to close up after itself.
Manual mode forces the window to **Faces** on every open, so the tab switch is still needed after it.
Methods: [Number 6](../Methods.md#method-6), [Number 10](../Methods.md#method-10),
[Number 13](../Methods.md#method-13).
```toml step
[[actions]]
use = "method-6"
item = "Settings..."

[[actions]]
use = "method-10"
tab = "Device"

[[actions]]
action = "applescript"
script = """
tell application "System Events"
    tell process "TimeFlip"
        set out to ""
        repeat with b in buttons of group 3 of scroll area 1 of group 1 of window "TimeFlip Settings"
            try
                set out to out & (value of attribute "AXIdentifier" of b) & "=" & (enabled of b) & "; "
            end try
        end repeat
        return out
    end tell
end tell"""
expect_contains = "forget-device=false"
```
- [x] Step 2: Close the Settings window this scenario opened.
So Scenario E quits with nothing on screen, matching how every other scenario here leaves it.
[Method: Number 23](../Methods.md#method-23).
```toml step
use = "method-23"
```
Scenario B opens the window and its last step closes it again, and Scenario C is driven entirely
from the status item, so by the time this scenario runs there is no window to address. It opens its
own now. Found on the first run that ever reached Scenario D.

## Scenario E -- quitting closes the segment off

**Preconditions:** Scenario D complete: the app in manual mode with the timer running on face 13.

- [x] Step 1: Capture the open segment's id and duration.
Every other segment in `device_event` is closed by the frame that follows it. A manual session has no
frame after its last one, so without the quit handler the segment being timed would stay open and
never become a `time_entry`. For a cube that self-heals on the next flip; here nothing is coming.
```toml step
[[actions]]
use = "method-24.c"
column = "device_event_id"
capture = "open_manual_row"

[[actions]]
use = "method-24.c"
column = "duration_seconds"
capture = "duration_before_quit"

[[actions]]
action = "sql_query"
query = "SELECT COUNT(*) FROM time_entry te JOIN device_event de ON de.device_event_id = te.device_event_id WHERE de.device_event_id = $open_manual_row;"
expect = "0"
```
- [x] Step 2: Let it run a little, then quit.
The row is only as current as the last periodic fetch left it, so the close-off has to give it its
true duration rather than accept whatever was last written. [Method: Number 3](../Methods.md#method-3).
```toml step
[[actions]]
action = "shell"
command = "sleep 15"

[[actions]]
use = "method-3"
```
- [x] Step 3: Confirm the segment was finalised, and grew on the way out.
```toml step
[[actions]]
action = "sql_query"
query = "SELECT finalised FROM device_event WHERE device_event_id = $open_manual_row;"
expect = "1"

[[actions]]
action = "shell"
command = "sqlite3 ~/Library/Application\\ Support/TimeFlip/appdata.sqlite \"SELECT CASE WHEN duration_seconds > $duration_before_quit THEN 'grew' ELSE 'stuck' END FROM device_event WHERE device_event_id = $open_manual_row;\""
expect = "grew"
```
- [x] Step 4: Confirm it became a `time_entry`.
"And all that entails": finalising is only half of it, the row has to be converted too, and against
the category face 13 held at the time.
```toml step
[[actions]]
action = "sql_query"
query = "SELECT COUNT(*) FROM time_entry WHERE device_event_id = $open_manual_row;"
expect = "1"
```
- [x] Step 5: Confirm the app said so on the way out.
A SQLite write during `applicationWillTerminate` is the part of this feature least likely to survive
first contact, so it is worth asserting from both ends.
```toml step
use = "method-24.d"
tag = "manual-mode"
expect_contains = "Manual segment closed off"
```

## Teardown

**Preconditions:** Scenario E complete: the app quit, the staged PIN still in `config.json`.

- [x] Step 1: Put the real PIN back.
Everything after this run depends on it. Restored before the relaunch, so the very next launch proves
it worked rather than leaving a broken file for the next checklist to trip over.
```toml step
[[actions]]
action = "shell"
command = "python3 -c \"import json,os; p=os.path.expanduser('~/Library/Application Support/TimeFlip/config.json'); d=json.load(open(p)); d['PIN']='$real_pin'; json.dump(d,open(p,'w'),indent=2,sort_keys=True)\""

[[actions]]
action = "shell"
command = "python3 -c \"import json,os; print(json.load(open(os.path.expanduser('~/Library/Application Support/TimeFlip/config.json')))['PIN'])\""
expect = "$real_pin"
```
- [x] Step 2: Relaunch and confirm the app reaches the cube again.
The proof that the restore worked, and the state the next checklist expects to inherit. Methods:
[Number 2](../Methods.md#method-2), [Number 4](../Methods.md#method-4).
```toml step
[[actions]]
use = "method-24.b"
capture = "before_restore_launch"

[[actions]]
use = "method-2"

[[actions]]
use = "method-4"
since_id = "$before_restore_launch"
timeout_seconds = 90
```
success while doing it. `act_shell` ignored both `capture` and `expect`, so Setup Step 2 never set
`real_pin`; the restore command then reached `subprocess.run(..., shell=True)` with `$real_pin`
still in it and **bash** expanded that undefined name to an empty string, writing `"PIN": ""`. The
verification action directly underneath compares the file against `$real_pin` and would have caught
it, except `expect` was ignored there too. Only Step 2's relaunch noticed, by which point the cube
was unreachable and the cause was two steps and one silent assertion away.
`act_shell` now honours both. Note this makes five other shell assertions in this file live for the
first time, including Scenario B Step 5 (`moved`) and Scenario E Step 3 (`grew`), which have been
passing regardless of what they printed.
