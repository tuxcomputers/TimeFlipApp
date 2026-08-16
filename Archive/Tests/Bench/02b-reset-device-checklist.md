# Reset Device Checklist

### Last run - 2026-08-12 16:32 on the branch 'feature/dailyLimit'

Covers the Device tab's **Reset Device** button (factory reset, command `0xFF`) -- confirms it
actually wipes the device's own event-number counter, not just app-side/DB state, by comparing the
device's event numbering before and after a real reset. A reset intentionally ends with the device
**forgotten / "Not paired"**: `TimeFlipBLEDevice.factoryReset()` just *sends* 0xFF (the device gives
no usable ack and reboots), then the app reconnects, and a successful re-login with the factory
default password confirms the wipe -- that login is deliberately **not** treated as a pairing, so
the app drops the connection into the pristine never-paired state ("Resetting..." -> "Not paired").
Continuing to use the device therefore requires a fresh Scan/re-pair, which this checklist also
exercises.

Every step here is Claude-driven against a connected device -- launching/quitting the app, driving
Preferences-window controls via System Events, and reading `sqlite3`/`debug_log` -- see
`../Methods.md` for the verified mechanics. The one part that requires a physical face flip
(generating a *real* post-reset event to see the device's own low numbering) lives in
`Tests/Interactive/02i-reset-device-checklist.md`, run after the whole Bench phase.

**Do not reset the device before this checklist starts** -- the reset is the test itself, not
setup. Requires Developer Mode enabled, the `debug` setting's `enabled` field `true` (see
`011_setting.sql`), and a device that is *already paired*, with some pre-existing event history on
it, going into Setup below.

**Runs after `01b-history-refresh-checklist.md`, deliberately** -- that checklist's own Setup is
what does the production-history-sync-then-switch-to-test-database pre-flight ([Method: Number 21](../Methods.md#method-21)); this file just confirms the test DB is still active rather
than repeating that pre-flight. The reset step below is irreversible on real hardware, but doesn't
need a live pause-and-confirm before it -- `01b`'s pre-flight already synced real device history to
`production.sqlite` first, so nothing real is at risk.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Setup

- [x] Step 1: Confirm `db_type` still reads `{"type":"test"}` and the device is connected.
(The database is left active by `01b-history-refresh-checklist.md`. If it reads `production`, `01b`'s
Setup needs (re-)running first rather than switching databases from here.)
The connection half was prose only until 2026-08-12. It proves one thing exactly: the cube holds whatever
PIN the app has stored, since connecting presents that PIN and never guesses (`PairingPasswordRules`).
**It does not prove the cube is off the factory default**, and reading it that way is what let a reset
cube through to Scenario B. A reset puts `000000` on the device *and* in `config.json`, so the two agree
and the app connects perfectly well to a cube sitting on the default. (What supplied the pairing it
connected *as* was a copy of production's `paired`/`device_uuid`/`device_name` into the fresh
`test.sqlite`. That copy is gone since 2026-08-12 -- setup pairs for real now -- so this particular route
in is closed, but the reasoning stands: a connection says the stored PIN is right, not that it is not the
default.)
So Scenario B's premise needs both halves: connected, **and** a stored PIN that is not the default, which
Scenario A Step 2 checks. Either alone is satisfied by the state that broke this file.
```toml step
[[actions]]
use = "method-24.a"
setting = "db_type"
expect = "{\"type\":\"test\"}"

[[actions]]
use = "method-24.f"
setting = "connection"
field = "connected"
expect = "1"
```
- [x] Step 2: Note the device's current event counter as the pre-reset baseline.
Query `device_event` by `device_event_id DESC` for the latest `event_number`, and/or read a `history` fetch's `device_last_event=`. It must be > 0 -- `01b`'s Setup backfill should already guarantee this. (Note: `device_event` has no timestamp column named `logged_at` -- use `start_epoch`/`start_time` if a time is needed, or omit entirely and just order by `device_event_id DESC`.)
```toml step
use = "method-24.c"
column = "event_number"
capture = "n_pre_reset"
```

## Scenario A -- Forget Device forgets, and does nothing else

**Preconditions:** test DB active, device paired and connected, established in Setup above.

Forgetting is local bookkeeping (`AppState.forgetDevice`): it drops the pairing and touches neither
the cube's PIN nor the stored one. Until 2026-08-11 it reset the cube's password over `0x30` first and
refused to unpair unless that was confirmed, which made it useless in the one situation it exists for
-- a cube the app cannot log in to. The proof that it leaves the **device's** PIN alone is Scenario B:
the cube is still on its rotated PIN there, which is why a wrong stored PIN cannot pair with it.

- [x] Step 1: Open Settings on the Device tab.
Methods: [Number 6](../Methods.md#method-6), [Number 10](../Methods.md#method-10).
```toml step
[[actions]]
use = "method-6"
item = "Settings..."

[[actions]]
use = "method-10"
tab = "Device"
```
- [x] Step 2: Confirm the stored PIN reads `123456`. If it reads `000000`, pair the cube and start again.
Checked, never written, and the difference is Scenario B's whole premise. `123456` is not this machine's
PIN, it is the compiled constant a dev build rotates onto any cube it pairs with on the factory default
(`DeveloperMode.devicePassword`), so a stored `123456` means the cube has been through a pairing and is
*off* the default -- which is what makes a wrong PIN unable to reach it later. A stored `000000` means it
has not, and the fix is to pair the cube (Device tab, Scan, click it), not to edit anything here.
**Writing the right value here was tried, on 2026-08-12, and made things worse.** A write cannot move the
*cube*, only what the app believes, so it turned a truthful mismatch into a silent lie: Setup Step 1 had
just proved the cube held the stored PIN by connecting with it, this step replaced that PIN, and Scenario
B then set out to watch a pairing fail against a cube that accepted the first candidate it was offered.
The stored PIN and the live connection are only evidence together, and only while nothing rewrites either.
(In a production build the stored password is in the Keychain instead; the two are the same role, and
`AppState.loadDevicePassword` picks between them.)
```toml step
action = "shell"
command = '''python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/Library/Application Support/TimeFlip/config.json')))['PIN'])"'''
expect = "123456"
```
- [x] Step 3: Click **Forget Device**, and confirm it unpaired without touching a password.
The count asserts an absence, which is the whole point of the change: no `0x30` write, no rotation, no
confirming re-login. The Name row dropping to `Not paired` is the positive half.
[Method: Number 13](../Methods.md#method-13).
```toml step
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
timeout_seconds = 20

[[actions]]
action = "sql_query"
query = "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $current_log_id AND (message LIKE '%reset to default%' OR message LIKE 'Rotating device password%' OR message LIKE 'Device password confirmed%');"
expect = "0"
```
- [x] Step 4: Confirm the stored PIN still reads `123456`.
Forgetting must not rewrite it. It used to write the factory default here, which is how a Forget came
to stamp `000000` over a hand-set PIN on 2026-08-01, so `000000` is the specific wrong answer this is
watching for. Nothing follows it: the file is untouched, so there is nothing to undo.
```toml step
action = "shell"
command = '''python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/Library/Application Support/TimeFlip/config.json')))['PIN'])"'''
expect = "123456"
```

## Scenario B -- pairing tries two PINs, in order, and fails when neither is right

**Preconditions:** Scenario A complete -- the app unpaired, the Settings window open on the Device tab,
and the cube still holding the PIN this app rotated onto it (which is what makes the failure below
meaningful).

Pairing presents the factory default first, then the stored password, and nothing else
(`PairingPasswordRules`). This scenario breaks the stored one on purpose so both are refused, which
pins three things at once: that the failure is reported rather than papered over, that the cube was
left on its own PIN by the forget above, and -- once the real PIN is restored -- that a cube reached on
the **stored** password is not rotated, because its PIN is already the one on record.

- [x] Step 1: Point `config.json` at a PIN the cube does not have, and relaunch so the app loads it.
`123457`, one digit off the PIN the cube is actually on, so it is obviously deliberate in a log. The relaunch is what
makes it take effect: the file is read at startup (`AppState.applyDeveloperConfig`). Methods:
[Number 3](../Methods.md#method-3), [Number 2](../Methods.md#method-2).
```toml step
[[actions]]
action = "shell"
command = '''python3 -c "import json,os;p=os.path.expanduser('~/Library/Application Support/TimeFlip/config.json');d=json.load(open(p));d['PIN']='123457';json.dump(d,open(p,'w'),indent=2)"'''

[[actions]]
use = "method-3"

[[actions]]
use = "method-2"

[[actions]]
action = "shell"
command = '''python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/Library/Application Support/TimeFlip/config.json')))['PIN'])"'''
expect = "123457"
```
- [x] Step 2: Open Settings on the Device tab and scan.
An unpaired app shows a single **Scan for Devices** button where the Forget/Reset pair was. Methods:
[Number 6](../Methods.md#method-6), [Number 10](../Methods.md#method-10),
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
script = '''
tell application "System Events"
    tell process "TimeFlip"
        click (first button of group 3 of scroll area 1 of group 1 of window "TimeFlip Settings" whose value of attribute "AXIdentifier" is "scan-for-devices")
    end tell
end tell'''

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='scan' AND message LIKE 'listed:%' AND debug_log_id > $current_log_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "TimeFlip"
timeout_seconds = 60
```
- [x] Step 3: Click the discovered row, and confirm the pairing is refused.
[Method: Number 9](../Methods.md#method-9) -- the row is a `Text` with an `.onTapGesture`, so it needs a
real CGEvent click at its centre.
```toml step
[[actions]]
use = "method-24.b"
capture = "before_pair_attempt_id"

[[actions]]
action = "cgevent_click_element"
element = 'first static text of group 3 of scroll area 1 of group 1 of window "TimeFlip Settings" whose name contains "TimeFlip"'

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE message LIKE 'Probe login commandResult raw bytes: 01%' AND debug_log_id > $before_pair_attempt_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "rejected"
timeout_seconds = 90
```
- [x] Step 4: Confirm both PINs were presented, in order, and only those two.
The rule itself, read off the wire: `30 30 30 30 30 30` is `000000` and `31 32 33 34 35 37` is
`123457`. Two probe logins, no third -- a dev build used to append two more candidates here.
**Waits for the second, rather than reading once.** Step 3 returns on the *first* refusal, and the
second candidate is deliberately a second behind it (`probeSettleSeconds`, because CoreBluetooth will
not reconnect to a peripheral it is still tearing down), so an immediate count catches one probe and
reads it as a missing candidate. Waiting for two is also still a real assertion that there is no
third: the two `ORDER BY` reads below pin which is which, and a third would have to be identical to
one of them to slip past all three.
```toml step
[[actions]]
action = "wait_for_sql"
query = "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $before_pair_attempt_id AND message LIKE 'Probe logging in using password:%';"
expect = "2"
timeout_seconds = 30

[[actions]]
action = "sql_query"
query = "SELECT CASE WHEN (SELECT message FROM debug_log WHERE debug_log_id > $before_pair_attempt_id AND message LIKE 'Probe logging in using password:%' ORDER BY debug_log_id LIMIT 1) LIKE '%30 30 30 30 30 30%' THEN 'ok' ELSE 'first candidate was not the factory default' END;"
expect = "ok"

[[actions]]
action = "sql_query"
query = "SELECT CASE WHEN (SELECT message FROM debug_log WHERE debug_log_id > $before_pair_attempt_id AND message LIKE 'Probe logging in using password:%' ORDER BY debug_log_id DESC LIMIT 1) LIKE '%31 32 33 34 35 37%' THEN 'ok' ELSE 'second candidate was not the stored PIN' END;"
expect = "ok"
```
- [x] Step 5: Confirm the app is still unpaired.
A refused pairing must leave it exactly as it was, rather than half-adopting a device it never reached.
```toml step
use = "method-24.a"
setting = "paired"
expect_contains = "false"
```
- [x] Step 6: Put `123456` back, relaunch, and pair -- on the **stored** password this time.
The cube is on that PIN, so the default is refused and the second candidate gets in.
**Written out rather than captured from Scenario A.** `123456` is not this machine's PIN, it is the
compiled constant a dev build rotates onto every cube it pairs with on the factory default
(`DeveloperMode.devicePassword`), so it is knowable without reading anything -- which is the point:
this scenario stages a wrong PIN, so it is the one that has to restore a right one, and a value
captured in an earlier scenario is a value that can arrive wrong. A run halted between Step 1 and here
leaves `123457` in the file, and a capture taken afterwards would restore the fixture as though it
were real. Methods: [Number 3](../Methods.md#method-3), [Number 2](../Methods.md#method-2),
[Number 6](../Methods.md#method-6), [Number 10](../Methods.md#method-10),
[Number 13](../Methods.md#method-13), [Number 9](../Methods.md#method-9).
```toml step
[[actions]]
use = "method-24.b"
capture = "before_restore_id"

[[actions]]
action = "shell"
command = '''python3 -c "import json,os;p=os.path.expanduser('~/Library/Application Support/TimeFlip/config.json');d=json.load(open(p));d['PIN']='123456';json.dump(d,open(p,'w'),indent=2)"'''

[[actions]]
use = "method-3"

[[actions]]
use = "method-2"

[[actions]]
use = "method-6"
item = "Settings..."

[[actions]]
use = "method-10"
tab = "Device"

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
query = "SELECT message FROM debug_log WHERE tag='scan' AND message LIKE 'listed:%' AND debug_log_id > $current_log_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "TimeFlip"
timeout_seconds = 60

[[actions]]
action = "cgevent_click_element"
element = 'first static text of group 3 of scroll area 1 of group 1 of window "TimeFlip Settings" whose name contains "TimeFlip"'

[[actions]]
action = "wait_for_sql"
query = "SELECT setting_value FROM setting WHERE setting_name='paired';"
expect_contains = "true"
timeout_seconds = 90
```
- [x] Step 7: Confirm that pairing did **not** rotate the cube's PIN.
The other half of the rule: a cube reached on the stored password already holds the PIN on record, so
rotating it would change a device PIN nobody asked to change and rewrite a stored password that was
already right. Only a cube on the factory default is rotated, which Scenario C's re-pair exercises.
```toml step
[[actions]]
action = "sql_query"
query = "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $before_restore_id AND message LIKE 'Rotating device password%';"
expect = "0"

[[actions]]
action = "shell"
command = '''python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/Library/Application Support/TimeFlip/config.json')))['PIN'])"'''
expect = "123456"
```
### Bugs found and fixed - branch 'feature/dailyLimit'
2026-08-12 - Step 4 counted the probe logins the instant Step 3 returned, and Step 3 returns on the
**first** refusal: the second candidate is a second behind it by design (`probeSettleSeconds`), so the
count read 1 and reported a missing candidate against a pairing that had presented both, in order, and
failed exactly as the scenario wanted. It waits for two now. Both PINs are also written out rather than
captured: Scenario A's capture was feeding Scenario B's restore, a cross-scenario dependency in the one
file most likely to be resumed mid-way, and a run halted with the fixture staged would have had the
fixture captured as the real PIN and written back permanently. `123456` and `123457` are now literals
everywhere they appear, and Setup Step 1's connection check -- prose until now -- is a step, because a
live connection is the only proof the cube holds the stored PIN.
2026-08-12 - Scenario A Step 2 was briefly made to *write* `123456` rather than check it, which broke
Scenario B on the next run: the cube was on the factory default, Setup Step 1 had just proved that by
connecting with a stored `000000`, and the write replaced the one honest piece of evidence with a value
the cube did not hold. Scenario B then watched for a refusal from a cube that accepted `000000` on the
first candidate, and rotated its PIN in the process. A write can only move what the app believes, so it
is back to a check, and a stored `000000` now means what it should: the cube needs pairing before this
file can say anything.

## Scenario C -- factory reset wipes the device's own event counter and ends never-paired

**Preconditions:** test DB active, device paired and connected, the pre-reset baseline noted (> 0)
noted -- the baseline from Setup, and the pairing re-established by Scenario B, which this scenario
runs straight on from.

- [x] Step 1: Open Settings (status-item menu -> "Settings...")
and switch to the Device tab (selected by name). Methods: [Number 6](../Methods.md#method-6), [Number 10](../Methods.md#method-10).
```toml step
[[actions]]
use = "method-6"
item = "Settings..."

[[actions]]
use = "method-10"
tab = "Device"
```
- [x] Step 2: Click **Reset Device** and confirm the destructive-action dialog.
 The button is an `AXButton` in the pairing section's `AXGroup`, right of **Forget Device**. [Method: Number 16](../Methods.md#method-16) -- **Cancel** is button 1, **Reset Device** (the destructive confirm) is button 2. (Note: the pairing section shows **Forget/Reset** whenever the app is paired, and a single **Scan for Devices** button when it isn't. Pairing is durable, so after a restart the buttons are there as soon as the window opens rather than waiting on the history backfill -- but the first action below still waits for the Reset button to exist before clicking, since clicking `button 2` when only Scan is present fails with `-1719 Invalid index`.)
```toml step
[[actions]]
action = "applescript"
script = '''
tell application "System Events"
 tell process "TimeFlip"
 set deadline to (current date) + 60
 repeat
 if (exists button 2 of group 3 of scroll area 1 of group 1 of window "TimeFlip Settings") then
 return "ready"
 end if
 if (current date) > deadline then
 return "timeout: pairing section still shows no Reset Device button (device not confirmed-paired)"
 end if
 delay 1
 end repeat
 end tell
end tell'''
expect = "ready"

[[actions]]
use = "method-24.b"
capture = "before_reset_id"

[[actions]]
action = "applescript"
script = '''
tell application "System Events"
 tell process "TimeFlip"
 click button 2 of group 3 of scroll area 1 of group 1 of window "TimeFlip Settings"
 delay 0.5
 click button 2 of sheet 1 of window "TimeFlip Settings"
 end tell
end tell'''
```
- [x] Step 3: Confirm the reset sequence via `debug_log`
(`TimeFlip` tag): a `"Factory reset (0xFF) sent; ... awaiting device reboot to confirm via default-password login"` row, then reconnect/login attempts, then `"Factory reset confirmed: device is back on the default password; returning to never-paired state"`.
      **The wait has to outlast the app's own budget, not the reset's typical duration.**
      `ApplicationDelegate.factoryResetConfirmTimeout` is 120s, and until it expires the app is still
      legitimately retrying, so any step budget below it can fail while the feature is working. 150s
      leaves the app's verdict, either message, as the thing that decides this step.
      The query matches the give-up line as well, so a genuine failure reports what the app actually
      concluded instead of `(no rows)`.
```toml step
[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Factory reset (0xFF) sent%' AND debug_log_id > $before_reset_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Factory reset (0xFF) sent"
timeout_seconds = 30

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' AND (message LIKE 'Factory reset confirmed%' OR message LIKE 'Factory reset NOT confirmed%') AND debug_log_id > $before_reset_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Factory reset confirmed: device is back on the default password; returning to never-paired state"
timeout_seconds = 150

[[actions]]
action = "sql_query"
query = "SELECT debug_log_id FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Factory reset confirmed%' AND debug_log_id > $before_reset_id ORDER BY debug_log_id DESC LIMIT 1;"
capture = "confirmed_id"
```
- [x] Step 4: Confirm the UI reaches the pristine never-paired state.
 During the confirm window the `Connection` row reads `Resetting...` (the Forget/Reset buttons replaced by a "Resetting device…" progress row); it then settles with `Name` = `Not paired`, `Connection` = `Not paired`, and `Battery` = `Not paired` (all greyed). It must **not** end on `Reconnecting...` or `Connected`.
```toml step
action = "applescript"
script = '''
tell application "System Events"
 tell process "TimeFlip"
 set n to value of static text 2 of group 1 of scroll area 1 of group 1 of window "TimeFlip Settings"
 set c to value of static text 4 of group 1 of scroll area 1 of group 1 of window "TimeFlip Settings"
 end tell
end tell
return n & "|" & c'''
expect_contains = "Not paired"
```
- [x] Step 5: Confirm no auto-reconnect follows the forget
 no further `TimeFlip` `"Login accepted"` / reconnect rows after the `"returning to never-paired state"` row, until the manual re-pair below. (Scope this on `debug_log_id > $confirmed_id` -- the id of that row, captured in Step 3 -- **not** `before_reset_id`: the confirm sequence itself relogins to test the password and logs one or two `"Login accepted, code=0x02"` rows before it settles, which a pre-reset baseline would wrongly flag as an auto-reconnect.)
```toml step
action = "sql_query"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Login accepted%' AND debug_log_id > $confirmed_id ORDER BY debug_log_id DESC LIMIT 1;"
expect = "(no rows)"
```
- [x] Step 6: Click **Scan for Devices** and wait for the device to appear in the list.
 The device is a `static text` matching its name, e.g. `"TimeFlip v2.0"`, under "Click a device below to pair with it.". [Method: Number 13](../Methods.md#method-13). (Note: the device can take a few seconds to show up in the scan, so the read below polls once a second for up to 6s and returns as soon as a `TimeFlip` row appears, rather than reading the list
 once after a fixed delay.)
```toml step
[[actions]]
action = "applescript"
script = '''
tell application "System Events"
 tell process "TimeFlip"
 click button 1 of group 3 of scroll area 1 of group 1 of window "TimeFlip Settings"
 end tell
end tell'''

[[actions]]
action = "applescript"
script = '''
tell application "System Events"
 tell process "TimeFlip"
 set deadline to (current date) + 6
 repeat
 set names to name of every static text of group 3 of scroll area 1 of group 1 of window "TimeFlip Settings"
 repeat with n in names
 if (n as string) contains "TimeFlip" then return (n as string)
 end repeat
 if (current date) > deadline then return (names as string)
 delay 1
 end repeat
 end tell
end tell'''
expect_contains = "TimeFlip"
```
- [x] Step 7: Click the discovered device's row to select and pair
(it is on the factory default PIN `000000` now). [Method: Number 9](../Methods.md#method-9) -- a coordinate CGEvent click on the row's centre (`cgevent_click_element`), since the row is a `Text`+`.onTapGesture` an AX press won't actuate. Wait for the pairing to **complete**, not merely for the first login: a fresh pair logs in with the default PIN, then rotates the device password and logs `"Device password confirmed set to: <pw>"` (`> current_log_id`) about a second later. Waiting for *that* marker (not the earlier `"Login accepted"`, which fires mid-rotation) is what keeps Step 8's `Connected` check from racing the rotation. If the automated click doesn't land, the prompt asks you to click the row yourself.
```toml step
[[actions]]
action = "cgevent_click_element"
element = 'first static text of group 3 of scroll area 1 of group 1 of window "TimeFlip Settings" whose name contains "TimeFlip"'

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Device password confirmed set to:%' AND debug_log_id > $current_log_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Device password confirmed set to:"
prompt = "Pairing the device automatically -- if it doesn't complete within a few seconds, click its row in the discovered list yourself."
timeout_seconds = 60
```
- [x] Step 8: Confirm the Device tab shows the device paired and connected again
 read the `Connection` row (`Connected`), `Name` (the device name, no longer "Not paired"), and `Battery` (a `%`, no longer "Not paired").
 ```toml step
action = "applescript"
script = '''
tell application "System Events"
 tell process "TimeFlip"
 return value of static text 4 of group 1 of scroll area 1 of group 1 of window "TimeFlip Settings"
 end tell
end tell'''
expect = "Connected"
```
- [x] Step 9: Confirm the device's own event counter was wiped by the reset
 the first `history` fetch after re-pairing (Steps 6-8 above) reads `device_last_event=nil` (a wiped counter with no events yet), not resuming from the pre-reset baseline. (`MAX(event_number)` in the local `device_event` table still reads old rows -- a reset doesn't delete rows recorded locally before it -- so query by `device_event_id DESC`, and rely on the live `device_last_event=nil` for the wipe evidence. This must run **after** the re-pair, not before: the app stops history fetches while forgotten (see Step 5), so the only post-reset fetch is the one the re-pair's startup triggers. Seeing a *real* post-reset event with the device's own low numbering needs a physical flip -- that's the Interactive counterpart.)
```toml step
use = "method-24.e"
action = "wait_for_sql"
tag = "hist-check"
since_id = "$before_reset_id"
expect_contains = "device_last_event=nil"
timeout_seconds = 30
```
- [x] Step 10: Close the Settings window
(opened in Scenario A Step 1) so the next checklist starts with no stray window open. [Method: Number 23](../Methods.md#method-23).
```toml step
use = "method-23"
```
