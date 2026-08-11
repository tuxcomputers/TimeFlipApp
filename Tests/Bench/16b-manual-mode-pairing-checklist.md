# Manual Mode Pairing Checklist

### Last run - 2026-08-12 09:34 on the branch 'feature/dailyLimit'

Covers the two ways a manual session meets a device: **an app with nothing paired starts in manual
mode**, unasked, and **scanning and pairing work from inside a session**, which is the only way out of
the mode other than quitting.

Both are new on 2026-08-11 and neither is reachable from the hermetic suite, because both are about the
object `ApplicationDelegate.device` points at. A manual session replaces it with a virtual device, and
every discovery path used to reach the radio by casting that property -- so in manual mode the cast
found a mock, the scan button did nothing at all, and the real `TimeFlipBLEDevice` had already been
deallocated along with its `CBCentralManager`, nothing else holding a reference to it. A unit test
cannot see any of that: there is no radio in the suite to lose.

The three things worth watching while it runs, each the failure this file exists to catch:

- **The clock.** A manual session is writing real segments to a real database throughout. Forgetting a
  cube and failing to pair are now ordinary things to do mid-session, and both used to tear the session
  down (`stopDeviceEvents`) or clear the reading out from under it (`AppState.forgetDevice`) while the
  virtual device carried on recording, so the app would have been timing something it was telling the
  user it was not.
- **The handover.** Pairing stands the session down *before* anything connects, which is what keeps a
  manual segment and a cube's from ever describing the same span. The open manual row has to be closed
  and converted on the way out: there is no frame coming to close it, the same reason the quit path
  closes one.
- **Nothing being asked.** With nothing paired there is no question to put to the user -- no device was
  expected and no scan has failed -- so a launch here must reach manual mode with no dialog at all.

**How the paired-but-unreachable state is staged.** Scenario A needs a session in manual mode that is
still paired, and reaches it the way `12b` does: `config.json`'s `PIN` is where a dev build keeps the
**stored** PIN, so setting it to a value the cube is not on makes the login fail while the scan still
finds the device. Nothing is written to the cube, and the file is put back before anything pairs --
pairing presents the factory default and then the stored PIN (`PairingPasswordRules`), so a staged PIN
would fail the pairing this checklist is here to prove works.

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
- [x] Step 2: Capture the real PIN from `config.json`, so it can be put back.
Everything after Scenario A depends on being able to restore it: get it wrong and nothing can pair, which
is most of what this file asserts. Captured rather than assumed, because a re-pair may have rewritten it.
**Refuses to run if the staged fixture is already there** -- a run that halts between Scenario A Step 2
and Scenario B Step 1 leaves `123457` in the file, and a fresh run would capture the fixture *as* the real
PIN and write it back permanently. Restore the real PIN by hand first, then start again.
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
- [x] Step 3: Confirm the app is paired and reaching the cube right now.
Scenario A stages a session that cannot reach a device it is paired to, so both halves have to be true
first: an app that was already unpaired would skip the offer entirely, and a cube that was already
unreachable would make Scenario A pass without the staging having done anything.
```toml step
[[actions]]
use = "method-24.f"
setting = "paired"
field = "paired"
expect = "1"

[[actions]]
use = "method-24.f"
setting = "connection"
field = "connected"
expect = "1"
```

## Scenario A -- forgetting the cube from inside a manual session

**Preconditions:** Setup complete: test database, device paired and connected, the real PIN captured.

- [x] Step 1: Quit the app, so the staged PIN is read at the next launch.
`config.json` is read at startup, so editing it under a running app changes nothing.
[Method: Number 3](../Methods.md#method-3).
```toml step
use = "method-3"
```
- [x] Step 2: Stage the refusal by setting the PIN to `123457`.
One digit off the real one, deliberately: a value that is obviously a test fixture. The Google keys in
the same file are read and rewritten around it rather than the file being replaced.
```toml step
[[actions]]
action = "shell"
command = "python3 -c \"import json,os; p=os.path.expanduser('~/Library/Application Support/TimeFlip/config.json'); d=json.load(open(p)); d['PIN']='123457'; json.dump(d,open(p,'w'),indent=2,sort_keys=True)\""

[[actions]]
action = "shell"
command = "python3 -c \"import json,os; print(json.load(open(os.path.expanduser('~/Library/Application Support/TimeFlip/config.json')))['PIN'])\""
expect = "123457"
```
- [x] Step 3: Capture the log baseline, launch, and wait for the offer.
Everything asserted below has to be a row *this* launch produced: the same messages are sitting in the
table from earlier runs. Methods: [Number 24.b](../Methods.md#method-24), [Number 2](../Methods.md#method-2).
```toml step
[[actions]]
use = "method-24.b"
capture = "before_staged_launch"

[[actions]]
use = "method-2"

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='manual-mode' AND message LIKE 'Offering manual mode:%' AND debug_log_id > $before_staged_launch ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "refused this app's PIN"
timeout_seconds = 120
```
- [x] Step 4: Answer the offer with **Switch to Manual Mode**, and confirm a session starts.
[Method: Number 29](../Methods.md#method-29) -- the alert holds the main thread while it is up, so
nothing else can be driven until it is answered.
```toml step
[[actions]]
use = "method-24.b"
capture = "before_answer"

[[actions]]
use = "method-29"
button = "Switch to Manual Mode"

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='manual-mode' AND message LIKE 'Manual session started%' AND debug_log_id > $before_answer ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "on face 13"
timeout_seconds = 60
```
- [x] Step 5: Pick a category on the Faces tab, so there is a clock to lose.
Manual mode forces the window open on Faces, which is where the timing is driven from. The row exposes
no name or identifier, so the app's own `click`-tagged log is what proves which one was hit. Methods:
[Number 6](../Methods.md#method-6), [Number 7](../Methods.md#method-7).
```toml step
[[actions]]
use = "method-6"
item = "Settings..."

[[actions]]
use = "method-24.b"
capture = "before_pick"

[[actions]]
action = "cgevent_click_element"
element = "button 1 of group 1 of group 1 of window \"TimeFlip Settings\""

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='manual-mode' AND message LIKE 'Manual timing: category%' AND debug_log_id > $before_pick ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "on face 13"
timeout_seconds = 30
```
- [x] Step 6: Confirm the manual segment is open and running.
The state the next step must not disturb: an unfinalised, unpaused row on manual mode's own face.
[Method: Number 24.l](../Methods.md#method-24).
```toml step
[[actions]]
use = "method-24.l"
column = "finalised"
expect = "0"

[[actions]]
use = "method-24.l"
column = "paused"
expect = "0"
```
- [x] Step 7: Click **Forget Device** on the Device tab, and confirm the pairing is gone.
The route this exists for: a cube whose PIN changed underneath the app (a battery pull reverts it to the
vendor default) cannot be reached and cannot be reset, so forgetting is the only way back -- and manual
mode is where the app has just put the user. Forgetting is local bookkeeping and reaches no radio, which
is why it is live here at all. Methods: [Number 10](../Methods.md#method-10),
[Number 13](../Methods.md#method-13).
```toml step
[[actions]]
use = "method-10"
tab = "Device"

[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        click (first button of group 3 of scroll area 1 of group 1 of window "TimeFlip Settings" whose value of attribute "AXIdentifier" is "forget-device")
    end tell
end tell'''

[[actions]]
action = "wait_for_sql"
query = "SELECT setting_value FROM setting WHERE setting_name='paired';"
expect_contains = "false"
timeout_seconds = 30
```
- [x] Step 8: Confirm the clock is still running, and still says so.
Forgetting used to clear the live reading along with the pairing, and every line of it did its own
damage to a session that had nothing to do with the cube: the status went to `.disconnected`, which
tears the menu bar's display down; the face went to unassigned, which drops the Faces tab's timer to
idle; and `isPaused` went true, claiming the session had stopped while the virtual device carried on
writing segments. Read three ways because the failure showed up differently in each: the row, the
Connection line, and the duration on screen actually moving. [Method: Number 27](../Methods.md#method-27).
```toml step
[[actions]]
use = "method-24.l"
column = "finalised"
expect = "0"

[[actions]]
use = "method-24.l"
column = "paused"
expect = "0"

[[actions]]
action = "applescript"
script = """
tell application "System Events"
    tell process "TimeFlip"
        set out to ""
        repeat with t in static texts of group 1 of scroll area 1 of group 1 of window "TimeFlip Settings"
            set out to out & (value of t) & "|"
        end repeat
        return out
    end tell
end tell"""
expect_contains = "Manual mode, no device"

[[actions]]
use = "method-27"
capture = "duration_after_forget"

[[actions]]
action = "shell"
command = "sleep 12"

[[actions]]
use = "method-27"
capture = "duration_later"

[[actions]]
action = "shell"
command = "test \"$duration_after_forget\" != \"$duration_later\" && echo moved || echo stuck"
expect = "moved"
```
### Bugs found and fixed - branch 'feature/dailyLimit'
2026-08-12 - The Connection row read returned nothing: it asked `group 3` of the scroll area, copied
from `12b` Scenario D, which reads the pairing section's **buttons**. The read-only rows -- Name,
Connection, Battery -- are `group 1`. The two assertions either side of it passed, so the step failed
on the one thing that was never about the app.
- [x] Step 9: Confirm the scan controls have taken the place of Forget and Reset.
The other half of what forgetting is for here: an unpaired app offers a single **Scan for Devices**
button, and that is what turns "the cube is unreachable" into something the user can act on without a
relaunch.
```toml step
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
expect_contains = "scan-for-devices=true"
```
- [x] Step 10: Close the Settings window, so the next scenario opens its own.
[Method: Number 23](../Methods.md#method-23).
```toml step
use = "method-23"
```

## Scenario B -- a launch with nothing paired starts in manual mode, unasked

**Preconditions:** nothing paired, and no Settings window open. Scenario A leaves it that way, and
Step 1 puts it that way regardless -- `00-test-setup` pairs the device whenever it finds the app
unpaired, so on a resume into this scenario the pairing Scenario A dropped is back.

- [x] Step 1: Put the real PIN back, drop any pairing, and relaunch.
The PIN goes back before anything pairs: pairing presents the factory default and then the *stored* PIN,
so a staged one would fail the pairing Scenario C is here to prove. The pairing is dropped in the
database rather than through the UI because this scenario is about what a launch does with `paired`
false, not about how it got there -- Forget is Scenario A's subject, and setup may have undone it.
Methods: [Number 3](../Methods.md#method-3), [Number 24.i](../Methods.md#method-24),
[Number 24.f](../Methods.md#method-24), [Number 2](../Methods.md#method-2).
```toml step
[[actions]]
action = "shell"
command = '''python3 -c "import json,os,sys;p=os.path.expanduser('~/Library/Application Support/TimeFlip/config.json');d=json.load(open(p));d['PIN']=sys.argv[1];json.dump(d,open(p,'w'),indent=2,sort_keys=True)" "$real_pin"'''

[[actions]]
action = "shell"
command = "python3 -c \"import json,os; print(json.load(open(os.path.expanduser('~/Library/Application Support/TimeFlip/config.json')))['PIN'])\""
expect = "$real_pin"

[[actions]]
use = "method-3"

[[actions]]
use = "method-24.i"
setting = "paired"
value = '{"paired":false}'

[[actions]]
use = "method-24.f"
setting = "paired"
field = "paired"
expect = "0"

[[actions]]
use = "method-24.b"
capture = "before_unpaired_launch"

[[actions]]
use = "method-2"
```
- [x] Step 2: Confirm it went straight into a manual session.
What it replaces is an app that sat inert until the user found the Device tab: no timer, nothing
recordable, a menu bar showing its own name. That is the state a brand-new user starts in and the state
anybody who forgets their device restarts into.
```toml step
[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='manual-mode' AND message LIKE 'Nothing paired at launch%' AND debug_log_id > $before_unpaired_launch ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "starting in manual mode"
timeout_seconds = 60

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='manual-mode' AND message LIKE 'Manual session started%' AND debug_log_id > $before_unpaired_launch ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "on face 13"
timeout_seconds = 60
```
### Bugs found and fixed - branch 'feature/dailyLimit'
2026-08-12 - Two faults in this scenario, one run apart. The first read the **oldest** `manual-mode`
row after the baseline, on the assumption that the entry line is a launch's first: it is not, because
`applicationDidFinishLaunching` sweeps up a manual row left open by a previous run before it decides
anything about pairing, so the step matched `Manual segment closed off` instead. Matches the message by
`LIKE`, newest-first, like every other step here. The second was the precondition: Step 1 relied on
Scenario A's Forget to have left the app unpaired, and `00-test-setup` pairs the device whenever it
finds it unpaired, so a resume into this scenario arrived paired and the launch had a device to reach.
Step 1 sets `paired` false itself now.
- [x] Step 3: Confirm nothing was asked.
The offer settles "your cube isn't answering -- keep trying, or time it yourself?", and with nothing
paired there is no such question: no device was expected, no scan has failed, nothing to retry. Both
halves are checked because they fail differently -- a dialog that was raised and dismissed leaves a log
row, and one still on screen leaves a window.
```toml step
[[actions]]
action = "sql_query"
query = "SELECT COUNT(*) FROM debug_log WHERE tag='manual-mode' AND message LIKE 'Offering manual mode:%' AND debug_log_id > $before_unpaired_launch;"
expect = "0"

[[actions]]
action = "applescript"
script = """
tell application "System Events"
    tell process "TimeFlip"
        return count of windows
    end tell
end tell"""
expect = "0"
```
- [x] Step 4: Confirm the dropdown's pause control is live with nothing paired.
The timer is the app's own here, so the item above it must not be dead: every rule behind it once read
"connected to a cube" and would have answered no. Nothing has been picked yet, so the session is stopped
and the item names the resume. [Method: Number 30](../Methods.md#method-30).
```toml step
use = "method-30"
expect_contains = "Resume=true"
```
- [x] Step 5: Pick a category and confirm the clock records against it.
The whole claim of starting here: the app is worth opening before a cube is ever bought. Methods:
[Number 6](../Methods.md#method-6), [Number 7](../Methods.md#method-7),
[Number 27](../Methods.md#method-27).
```toml step
[[actions]]
use = "method-6"
item = "Settings..."

[[actions]]
use = "method-24.b"
capture = "before_unpaired_pick"

[[actions]]
action = "cgevent_click_element"
element = "button 1 of group 1 of group 1 of window \"TimeFlip Settings\""

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='manual-mode' AND message LIKE 'Manual timing: category%' AND debug_log_id > $before_unpaired_pick ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "on face 13"
timeout_seconds = 30

[[actions]]
use = "method-24.l"
column = "finalised"
expect = "0"

[[actions]]
use = "method-24.l"
column = "paused"
expect = "0"
```

## Scenario C -- scanning and pairing from inside the session

**Preconditions:** Scenario B complete: an unpaired manual session with the clock running on face 13,
the Settings window open on Faces, and the real PIN back in `config.json`.

- [x] Step 1: Scan from the Device tab, and confirm the cube is listed.
The proof the radio survived: entering manual mode swaps the virtual device into the property every
discovery path used to cast, and the object itself was dropped with nothing else holding it. A listing
means the scan ran on a real `CBCentralManager` that is still there. Methods:
[Number 10](../Methods.md#method-10), [Number 13](../Methods.md#method-13).
```toml step
[[actions]]
use = "method-10"
tab = "Device"

[[actions]]
use = "method-24.b"
capture = "before_manual_scan"

[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        click (first button of group 3 of scroll area 1 of group 1 of window "TimeFlip Settings" whose value of attribute "AXIdentifier" is "scan-for-devices")
    end tell
end tell'''

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='scan' AND message LIKE 'listed:%' AND debug_log_id > $before_manual_scan ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "TimeFlip"
timeout_seconds = 60
```
- [x] Step 2: Note the open manual row, then click the discovered row to pair.
The row is a `Text` with an `.onTapGesture`, so it needs a real CGEvent click at its centre.
[Method: Number 9](../Methods.md#method-9).
```toml step
[[actions]]
use = "method-24.l"
column = "device_event_id"
capture = "manual_row"

[[actions]]
action = "sql_query"
query = "SELECT COUNT(*) FROM time_entry WHERE device_event_id = $manual_row;"
expect = "0"

[[actions]]
use = "method-24.b"
capture = "before_manual_pair"

[[actions]]
action = "cgevent_click_element"
element = 'first static text of group 3 of scroll area 1 of group 1 of window "TimeFlip Settings" whose name contains "TimeFlip"'

[[actions]]
action = "wait_for_sql"
query = "SELECT setting_value FROM setting WHERE setting_name='paired';"
expect_contains = "true"
timeout_seconds = 120
```
- [x] Step 3: Confirm the factory default was still presented first.
Pairing from a manual session is the same two-candidate sequence as pairing from anywhere else --
`PairingPasswordRules`, the default then the stored PIN and nothing else -- and it must not have picked
up anything of the manual session's on the way. `30 30 30 30 30 30` is `000000` on the wire.
```toml step
action = "sql_query"
query = "SELECT CASE WHEN (SELECT message FROM debug_log WHERE debug_log_id > $before_manual_pair AND message LIKE 'Probe logging in using password:%' ORDER BY debug_log_id LIMIT 1) LIKE '%30 30 30 30 30 30%' THEN 'ok' ELSE 'first candidate was not the factory default' END;"
expect = "ok"
```
- [x] Step 4: Confirm the session was stood down and its segment closed off.
The handover, and the ordering that keeps a manual segment and a cube's from ever describing the same
span: the virtual device goes before anything connects, and its open row is closed and converted on the
way out. Nothing else would ever close it -- a cube's row is closed by the frame after it and there is no
frame coming, which is why the quit path does the same thing.
```toml step
[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='manual-mode' AND message LIKE 'Manual session ending%' AND debug_log_id > $before_manual_pair ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "open segment closed: true"
timeout_seconds = 60

[[actions]]
action = "sql_query"
query = "SELECT finalised FROM device_event WHERE device_event_id = $manual_row;"
expect = "1"

[[actions]]
action = "wait_for_sql"
query = "SELECT COUNT(*) FROM time_entry WHERE device_event_id = $manual_row;"
expect = "1"
timeout_seconds = 60
```
- [x] Step 5: Confirm the app is now timing from the cube.
The mode is over: a live connection, and the pairing recorded. `isConnected` is what gates every command
that goes out over BLE, and manual mode is deliberately not it.
```toml step
[[actions]]
action = "wait_for_sql"
query = "SELECT json_extract(setting_value, '$.connected') FROM setting WHERE setting_name='connection';"
expect = "1"
timeout_seconds = 60

[[actions]]
use = "method-24.f"
setting = "paired"
field = "paired"
expect = "1"
```

## Teardown

**Preconditions:** Scenario C complete: paired and connected, Settings window open on the Device tab.

- [x] Step 1: Close the Settings window.
[Method: Number 23](../Methods.md#method-23).
```toml step
use = "method-23"
```
- [x] Step 2: Confirm `config.json` holds the real PIN.
Nothing here should have rotated it: the cube was reached on the stored PIN, which it already holds, and
only a cube answering on the factory default is rotated.
```toml step
action = "shell"
command = "python3 -c \"import json,os; print(json.load(open(os.path.expanduser('~/Library/Application Support/TimeFlip/config.json')))['PIN'])\""
expect = "$real_pin"
```
- [x] Step 3: Leave the device unlocked and unpaused.
Two scenarios here quit the app, and quitting pauses and locks the cube (`pause_on_lock`), so the state
the next checklist inherits has to be put back deliberately rather than assumed.
```toml step
action = "ensure_unlocked_unpaused"
```
