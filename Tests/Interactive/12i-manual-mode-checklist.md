# Manual Mode Checklist

### Last run - 2026-08-12 16:32 on the branch 'feature/dailyLimit'

The half of manual mode that needs the airspace to be genuinely empty.

`Bench/12b` takes the route where the cube **is** found and refuses the app's PIN, staged by editing
`config.json`. This takes the other one: nothing eligible in range at all. They end at the same
dialog and are not the same test -- the app has to tell them apart, because "not in range" and
"there and refused" are different problems with different fixes, and one of them has already shipped
a bug where the answer given was the wrong one of the two.

Nothing in software can produce this state on the machine under test. A scan that finds nothing needs
the radio off, and turning the Mac's Bluetooth off from a script would take every other Bluetooth
device on the machine down with it. So it is asked for, and asked for once, with everything else
either side of it automated.

> **Before running this: your keyboard and pointing device must not be Bluetooth.**
> Switching Bluetooth off disconnects them along with the cube, and you would have no way to switch
> it back on. A laptop's built-in keyboard and trackpad are fine; a Magic Keyboard or Magic Mouse on
> a desktop Mac is not. If in doubt, skip this checklist rather than find out.

Requires a paired physical TimeFlip device and the app running with Developer Mode enabled and the
`debug` setting's `enabled` field `true`, same as every other checklist here.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Setup

**Preconditions:** the test database and the device connected, both established by
`Tests/00-test-setup.md`. `Bench/12b` has already run and restored `config.json`, so the PIN in that
file is the real one -- this scenario must fail on the radio, not on a password.

- [x] **(Claude)** Step 1: Confirm `db_type` reads **test**.
```toml step
use = "method-24.a"
setting = "db_type"
expect = '{"type":"test"}'
```
- [x] **(Claude)** Step 2: Confirm the app is currently connected to the cube.
The premise: the only thing that changes below is the radio. Starting from an already-unreachable
device would make every assertion here pass for a reason the checklist is not testing.
Read from the live `connection` setting rather than the newest `TimeFlip` log row, for the reason
`Bench/12b` Setup Step 3 records: the setup's closing unlock/unpause is logged under that same tag,
so the newest row is never the login, and asking whether the app is connected *now* is the question
this premise is actually about.
```toml step
use = "method-24.f"
setting = "connection"
field = "connected"
expect = "1"
```

## Scenario A -- nothing in range raises the offer, and says so

**Preconditions:** Setup complete: test database, device connected, `config.json` holding the real
PIN.

- [x] **(Claude)** Step 1: Quit the app before the radio goes off.
Quitting first keeps the disconnect out of the picture: what is under test is a **scan** that finds
nothing at startup, not a connection being lost. [Method: Number 3](../Methods.md#method-3).
```toml step
use = "method-3"
```
- [x] **(You)** Step 2: Turn Bluetooth off.
Menu bar Bluetooth icon, or System Settings -> Bluetooth. Detected automatically once the app is
launched below; this step only waits for you to say it is off.
```toml step
action = "ask_user"
prompt = "Turn Bluetooth OFF (do this only if your keyboard and mouse are NOT Bluetooth). Is it off? (y/n)"
```
- [x] **(Claude)** Step 3: Capture the log baseline, then launch.
```toml step
[[actions]]
use = "method-24.b"
capture = "before_radio_off_launch"

[[actions]]
use = "method-2"
```
- [x] **(Claude)** Step 4: Confirm the scan found **nothing**.
The line that separates this run from `12b`'s, where the same dialog is reached with the cube listed
by name.
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='scan' AND message LIKE 'eligible after scan:%' AND debug_log_id > $before_radio_off_launch ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "none"
timeout_seconds = 90
```
- [x] **(Claude)** Step 5: Confirm the offer blames the empty scan and not a PIN.
The other half of the pair `12b` Step 6 pins. Both wordings come from one place, chosen from what the
attempt actually counted rather than from which code path happened to get there first -- which is the
bug that made a refused PIN read as a range problem.
```toml step
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='manual-mode' AND message LIKE 'Offering manual mode:%' AND debug_log_id > $before_radio_off_launch ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "nothing eligible found in the scan"
timeout_seconds = 60
```
- [x] **(Claude)** Step 6: Confirm the dialog is on screen.
An `NSAlert` from an app with no window open, raised here with no radio at all -- the state a user
who has left their cube at home actually meets. [Method: Number 29](../Methods.md#method-29).
```toml step
action = "applescript"
script = """
tell application "System Events"
    tell process "TimeFlip"
        return name of every button of window 1
    end tell
end tell"""
expect_contains = "Switch to Manual Mode"
```
- [x] **(Claude)** Step 7: Take manual mode and confirm a session starts with no device at all.
`12b` proves the same thing with a cube sitting a metre away, refusing. This proves it with nothing
there, which is the case the feature exists for.
[Method: Number 29](../Methods.md#method-29).
```toml step
[[actions]]
use = "method-24.b"
capture = "before_offline_answer"

[[actions]]
use = "method-29"
button = "Switch to Manual Mode"

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='manual-mode' AND message LIKE 'Manual session started%' AND debug_log_id > $before_offline_answer ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "face 13"
timeout_seconds = 30

[[actions]]
action = "sql_query"
query = "SELECT COUNT(*) FROM debug_log WHERE tag='manual-mode' AND message LIKE 'Offering manual mode:%' AND debug_log_id > $before_offline_answer;"
expect = "0"
```
- [x] **(Claude)** Step 8: Confirm the menu bar draws the session rather than the bare app name.
Nothing has ever been reached this launch, and that is exactly the state the display rules used to
read as "nothing is happening". [Method: Number 27](../Methods.md#method-27).
```toml step
use = "method-27"
expect_contains = "0:00:00"
```
- [x] **(Claude)** Step 9: Quit, and confirm the mode does not survive it.
Quitting is the only way out, so the next launch has to come up trying for the device again rather
than remembering the choice -- which is why nothing about manual mode is persisted, and why there is
nowhere to persist it to. [Method: Number 3](../Methods.md#method-3).
```toml step
use = "method-3"
```

## Scenario B -- the radio comes back and so does the device

**Preconditions:** Scenario A complete: the app quit, Bluetooth still off.

- [x] **(You)** Step 1: Turn Bluetooth back on.
```toml step
action = "ask_user"
prompt = "Turn Bluetooth back ON. Is it on? (y/n)"
```
- [x] **(Claude)** Step 2: Relaunch and confirm the app reaches the cube again with no dialog.
The state the next checklist inherits, and the proof that manual mode was per-launch: this launch
had no memory of it and went straight back to the device. Methods:
[Number 2](../Methods.md#method-2), [Number 4](../Methods.md#method-4).
```toml step
[[actions]]
use = "method-24.b"
capture = "before_radio_on_launch"

[[actions]]
use = "method-2"

[[actions]]
use = "method-4"
since_id = "$before_radio_on_launch"
timeout_seconds = 120

[[actions]]
action = "sql_query"
query = "SELECT COUNT(*) FROM debug_log WHERE tag='manual-mode' AND message LIKE 'Offering manual mode:%' AND debug_log_id > $before_radio_on_launch;"
expect = "0"
```
