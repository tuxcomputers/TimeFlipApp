# Device Rename Checklist

### Last run - 2026-08-10 12:47 on the branch 'feature/manualMode'

Covers renaming the cube: the three right-click targets that open the menu, the write itself, the
notice that explains why the new name does not show up everywhere, and the documented workaround
that makes it show up now.

**This one does need the cube.** The name lives on the device, `0x15` is a real BLE write, and the
whole point of Scenario C is what the hardware reports back afterward. `Tests/Interactive/09i` is a
stub: none of it needs a hand on the device.

**Automated coverage, deliberately not repeated here:** every decision about a submitted name is
unit-tested in `DeviceNameRulesTests` (length, character set, the no-op cases), and the notice's
lifecycle in `AppStateDeviceTabTests` (posted on a rename, surviving a stale reconnect, cleared when
the names agree). What is left is what those tests cannot see: whether the menu opens at all,
whether the device takes the name, and what it says its name is afterward.

## What the firmware does, and why this checklist looks odd

Renaming works, but nothing looks like it did, for two measured reasons
(`docs/timeflip2-firmware-observations.md`):

- the advertised name never changes, so a scan's *packet* says `TimeFlip v2.0` permanently
- the reported name is only read at connect time, so macOS hands out the old one for a reconnect
  or two

So Scenario C pairs with a row that may well show the **old** name. That is not a mistake in the
step, it is the behaviour being tested.

How long "a reconnect or two" lasts is not fixed, and the steps must not assume a particular
number. The forget in Scenario C is itself a connection and can refresh the cache: measured across
three runs of one build on 2026-08-10, the row showed the new name once and the old name twice, and
`peripheralDidUpdateName` landed on the forget's connection once and after the re-pair twice. The
steps therefore assert what is invariant (the advertised name, and where the app ends up) rather
than which connection a value arrives on.

## The row's accessibility shape

Read live on 2026-08-02; the steps below depend on it.

The Info section is `group 1 of scroll area 1 of group 1 of window "TimeFlip Settings"`, and the
Name row is its first two static texts: the label `Name`, then the name itself. While the inline
editor is open the name is a `text field` instead, which is how a step tells the editor is open.

The label is at the left edge of the row and the name is hard against the right, so the middle of
the row is inside neither and is reached with `anchor_dx` ([Method 26](../Methods.md#method-26)).

## Scenario A -- the three right-click targets

**Preconditions:** the device paired and connected, Settings open on the Device tab.

All three must open the app's own Rename menu. The name itself is the one that needs proving: it is
a `LabeledContent` value, which is selectable on macOS, and selectable text answers a right-click
with macOS's "Look Up" menu unless selection is turned off. That is exactly what it did before
`.textSelection(.disabled)` was added.

- [x] Step 1: Restart the app, open Settings on the Device tab, and confirm the cube is not already
      called `Chomper`.
      The quit has to come first. `Tests/00-test-setup.md` leaves the app running, so a step that
      only launches starts a **second** instance: two status items, two BLE clients. That is
      exactly what an inlined launch here did on 2026-08-02. The quit no-ops when nothing is
      running, so this both restarts and cold-starts. Methods:
      [Number 3](../Methods.md#method-3) to quit, [Number 2](../Methods.md#method-2) to start.

      The `Chomper` check is here because Scenario C's last step renames the cube back, so a run
      that starts on `Chomper` means the previous one did not finish. It matters because renaming
      to the name the device already has is a deliberate no-op: Scenario B would pass while
      writing nothing.
```toml step
[[actions]]
use = "method-3"

[[actions]]
use = "method-2"

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Login accepted%' AND debug_log_id > $current_log_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Login accepted"
timeout_seconds = 40

[[actions]]
action = "click_menu_item"
item = "Settings..."

[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        click (first radio button of radio group 1 of group 1 of toolbar 1 of window "TimeFlip Settings" whose description is "Device")
        delay 0.5
        return "fields=" & ((count of text fields of group 1 of scroll area 1 of group 1 of window "TimeFlip Settings") as string)
    end tell
end tell'''
expect_contains = "fields=0"

[[actions]]
action = "sql_query"
query = "SELECT CASE WHEN setting_value LIKE '%Chomper%' THEN 'STALE-FROM-PREVIOUS-RUN' ELSE 'ready' END FROM setting WHERE setting_name = 'device_name';"
expect_contains = "ready"
```
- [x] Step 2: Right-click the name itself and confirm Rename opens the editor.
      The name is `static text 2` of the row. Escape closes the editor again so the next step
      starts from the same place.
```toml step
[[actions]]
action = "cgevent_context_menu_pick"
element = "static text 2 of group 1 of scroll area 1 of group 1 of window \"TimeFlip Settings\""
anchor = 0.5

[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        return "fields=" & ((count of text fields of group 1 of scroll area 1 of group 1 of window "TimeFlip Settings") as string)
    end tell
end tell'''
expect_contains = "fields=1"

[[actions]]
action = "cgevent_key"
keycode = 53
activate = "TimeFlip"
```
- [x] Step 3: Right-click the "Name" label and confirm the same menu opens.
```toml step
[[actions]]
action = "cgevent_context_menu_pick"
element = "static text 1 of group 1 of scroll area 1 of group 1 of window \"TimeFlip Settings\""
anchor = 0.5

[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        return "fields=" & ((count of text fields of group 1 of scroll area 1 of group 1 of window "TimeFlip Settings") as string)
    end tell
end tell'''
expect_contains = "fields=1"

[[actions]]
action = "cgevent_key"
keycode = 53
activate = "TimeFlip"
```
- [x] Step 4: Right-click the bare middle of the row and confirm the menu opens there too.
      This is the part that belongs to the row's `contentShape(Rectangle())` and to no element,
      hence the pixel offset off the label.
```toml step
[[actions]]
action = "cgevent_context_menu_pick"
element = "static text 1 of group 1 of scroll area 1 of group 1 of window \"TimeFlip Settings\""
anchor = 0.5
anchor_dx = 250

[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        return "fields=" & ((count of text fields of group 1 of scroll area 1 of group 1 of window "TimeFlip Settings") as string)
    end tell
end tell'''
expect_contains = "fields=1"

[[actions]]
action = "cgevent_key"
keycode = 53
activate = "TimeFlip"
```

## Scenario B -- writing the name

**Preconditions:** Scenario A finished, so the editor is closed and the device is connected.

- [x] Step 1: Rename the device to `Chomper`, confirm the write went out, and confirm nothing
      re-reads the command result afterward.
      `15 07` is the opcode and the length, then `Chomper` in ASCII. The device never updates the
      command result characteristic for `0x15`, so there is nothing to wait for and the app does not
      try. A re-read loop that once did lived on the `timeflip2-firmware-diagnosis` branch and cost
      four seconds a rename; the count is scoped to this step because a database that once ran that
      build still holds its rows (Note: the sleep is what makes the count meaningful -- the last
      rung of that loop landed at +2s).
```toml step
[[actions]]
action = "cgevent_context_menu_pick"
element = "static text 2 of group 1 of scroll area 1 of group 1 of window \"TimeFlip Settings\""
anchor = 0.5

[[actions]]
action = "applescript"
script = '''
tell application "TimeFlip" to activate
tell application "System Events"
    delay 0.3
    keystroke "a" using command down
    keystroke "Chomper"
    delay 0.3
    keystroke return
end tell'''

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='ble-tx' AND message LIKE '%15 07 43 68 6F 6D 70 65 72%' AND debug_log_id > $current_log_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "15 07 43 68 6F 6D 70 65 72"
timeout_seconds = 10

[[actions]]
action = "shell"
command = "sleep 3"

[[actions]]
action = "sql_query"
query = "SELECT COUNT(*) FROM debug_log WHERE message LIKE '%commandResult re-read%' AND debug_log_id > $current_log_id;"
expect = "0"
```
- [x] Step 2: Confirm the name was stored and is on screen.
```toml step
[[actions]]
action = "sql_query"
query = "SELECT setting_value FROM setting WHERE setting_name = 'device_name';"
expect_contains = "Chomper"

[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        return "name=" & (value of static text 2 of group 1 of scroll area 1 of group 1 of window "TimeFlip Settings" as string)
    end tell
end tell'''
expect_contains = "name=Chomper"
```
- [x] Step 3: Confirm the notice appeared, naming both the new name and the one the device will
      keep reporting.
```toml step
[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        return (value of static text 3 of group 1 of scroll area 1 of group 1 of window "TimeFlip Settings" as string)
    end tell
end tell'''
expect_contains = "Renamed to"
```

## Scenario C -- the workaround, end to end

**Preconditions:** Scenario B finished, so the device is renamed and still connected.

This is the procedure documented for users under "Renaming Your Device" in
`docs/configuration.md`. It runs here so the documentation cannot quietly go stale.

- [x] Step 1: Forget the device and confirm the notice goes with it.
      Forget also resets the device password to the factory default and proves it with a real
      login, which is what makes the re-pair below work.
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
query = "SELECT message FROM debug_log WHERE message LIKE 'Device password confirmed reset to default%' AND debug_log_id > $current_log_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "confirmed reset to default"
timeout_seconds = 20

[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        return "name=" & (value of static text 2 of group 1 of scroll area 1 of group 1 of window "TimeFlip Settings" as string) & " texts=" & ((count of static texts of group 1 of scroll area 1 of group 1 of window "TimeFlip Settings") as string)
    end tell
end tell'''
expect_contains = "name=Not paired texts=6"
```
- [x] Step 2: Scan, and confirm the cube is still **advertising** the vendor name.
      This is the finding, on screen: `0x15` changes the GAP name and never the advertised one, so
      the packet says `TimeFlip v2.0` however many times the cube is renamed. That is what the
      assertion reads, because it is the half that is actually invariant.
      The row's *label* is `CBPeripheral.name`, which is a cache, and it is deliberately not
      asserted here. It is usually a connection behind, but the forget above is itself a connection
      and can refresh it: on 2026-08-10 the same scan showed `Chomper` on one run and the old name
      on two others. Step 3 therefore picks the row by position rather than by either name.
```toml step
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
query = "SELECT message FROM debug_log WHERE tag='scan' AND message LIKE 'listed:%' AND message LIKE '%looking-for=Chomper%' AND debug_log_id > $current_log_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "advert=TimeFlip v2.0"
timeout_seconds = 30
```
- [x] Step 3: Click that row and pair with it.
      The row says one thing and the cube is called another; the peripheral is the same either way.
      **Addressed by position, not by the name it happens to be showing.** It used to click
      `whose value is "TimeFlip v2.0"`, which assumes the reported name has not caught up yet, and
      that is not reliable: on 2026-08-10 the forget's own connection had already refreshed it, so
      the row read `Chomper` and the selector matched nothing. `cgevent_click_element` fails a step
      when its element is missing, but the assertion below it is a login, and the app was already
      logging in on its own, so the run sailed past a click that never landed.
      `static text 1` of the section is the "Click a device below to pair with it." header, so the
      first device row is `static text 2`. The count is asserted first: exactly one device, so the
      index cannot land on somebody else's cube.
```toml step
[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        return "rows=" & ((count of static texts of group 3 of scroll area 1 of group 1 of window "TimeFlip Settings") as string)
    end tell
end tell'''
expect_contains = "rows=2"

[[actions]]
action = "cgevent_click_element"
element = "static text 2 of group 3 of scroll area 1 of group 1 of window \"TimeFlip Settings\""

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Login accepted%' AND debug_log_id > $current_log_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Login accepted"
timeout_seconds = 40
```
- [x] Step 4: Confirm the window ends up showing the name the cube is actually carrying.
      The connect-time read is the stale one, and `peripheralDidUpdateName` is the only signal that
      ever reports the real name. **Which connection it arrives on is not fixed**, so this asserts
      the outcome rather than the timing: measured 2026-08-10, it fired on the forget's connection
      in one run and only after the re-pair in two others, on the same build and the same cube. A
      step that required the second of those would fail on a healthy app roughly a third of the
      time, which is what it did.
      What must hold either way is that the re-pair does not *lose* the name. It used to: the
      re-pair adopted the cached pre-rename name over the real one, and the name report that would
      have corrected it was then dropped by a guard comparing against the value that overwrite had
      just replaced. Both are fixed (`shouldAdoptReportedName` takes the peripheral's identity now,
      so re-pairing the same cube keeps our name), and this step is what proves it on hardware.
```toml step
[[actions]]
action = "wait_for_sql"
query = "SELECT setting_value FROM setting WHERE setting_name = 'device_name';"
expect_contains = "Chomper"
timeout_seconds = 30

[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        return "name=" & (value of static text 2 of group 1 of scroll area 1 of group 1 of window "TimeFlip Settings" as string)
    end tell
end tell'''
expect_contains = "name=Chomper"
```
- [x] Step 5: Confirm the notice did not come back.
      It belongs to a rename, not to a name that disagrees. The re-pair is the cure, not another
      symptom.
```toml step
[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        return "texts=" & ((count of static texts of group 1 of scroll area 1 of group 1 of window "TimeFlip Settings") as string)
    end tell
end tell'''
expect_contains = "texts=6"
```
- [x] Step 6: Rename the cube back to `TimeFlip v2.0`.
      Leaves the device where the next run expects it, and is the one step that has to happen even
      if something above failed: a cube left on a test name is a cube the next run silently
      no-ops against (Scenario A Step 1 is what catches that).
```toml step
[[actions]]
action = "cgevent_context_menu_pick"
element = "static text 2 of group 1 of scroll area 1 of group 1 of window \"TimeFlip Settings\""
anchor = 0.5

[[actions]]
action = "applescript"
script = '''
tell application "TimeFlip" to activate
tell application "System Events"
    delay 0.3
    keystroke "a" using command down
    keystroke "TimeFlip v2.0"
    delay 0.3
    keystroke return
end tell'''

[[actions]]
action = "wait_for_sql"
query = "SELECT setting_value FROM setting WHERE setting_name = 'device_name';"
expect_contains = "TimeFlip v2.0"
timeout_seconds = 10
```
