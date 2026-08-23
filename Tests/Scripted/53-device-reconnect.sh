#!/bin/bash
# Getting back to the cube by itself: at launch, with nobody watching.
#
# **This is the one check in the suite that runs with the window shut, and that is the whole claim.** A paired app has no
# Scan button (`DevicePairingRules.showsScanControls`), so until this feature existed a pairing survived a quit and the
# next launch had no way to use it: `paired` said there was a cube, `connection.connected` said it was unreachable, and
# Forget Device was the only way out. What is being proved here is that nothing needs pressing -- the app looks for its
# own cube because the table says it has one.
#
# **Every assertion is a table or a log row, and deliberately not the screen.** The Settings window is not opened until
# the reconnect has already been checked, because opening it is exactly the thing that must not be necessary. A check
# that read the Device tab would pass just as well against an app that only reconnects when somebody looks.
#
# **A relaunch is the test, not a reset of it.** `quit_app` runs the app's own quit sequence, which lets the cube go and
# writes `quit_request`; the launch after it starts from a table that says paired, disconnected. That is the state a
# morning starts in, and it is not reachable any other way.
#
# **Massaged from `Archive/Tests/00-test-setup.md` Step 6**, which confirmed the app had reconnected by waiting for a
# fresh `Login accepted` after a restart and prompting if it never came. The technique is right and is kept: poll the log
# for the app's own row rather than asking anybody whether it worked. What is not kept is its place -- it was a
# precondition inside a setup checklist, establishing a connection so that other features could be tested, and the
# reconnect itself was never the thing under test. Here it is.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
start "reconnecting to a paired TimeFlip at launch"

if ! device_required; then
    fail "no TimeFlip was made available, so there is nothing to reconnect to"
    finish
    exit $?
fi

open_settings
select_tab Device

# ---------------------------------------------------------------------------- a cube to come back to
#
# **Paired from scratch by `pair_a_cube`**, for `52-device-reset`'s reason: a script that inherited `51`'s pairing would
# skip whenever `51` skipped and would silently test nothing after a reordering. The cost is one scan.
#
# A cube that cannot be paired is a skip rather than a failure here, unlike in `52`. This script's claim is about what
# happens to a pairing across a quit, and with no pairing there is no claim to test either way.

if ! pair_a_cube; then
    pair_verdict "there is nothing to come back to"
    close_settings
    finish
    exit $?
fi
pass "paired a cube to come back to"

# One row per setting, the value being JSON, which is what `08-app-settings` reads them with too.
setting() { sql "SELECT json_extract(setting_value, '\$.$2') FROM setting WHERE setting_name = '$1';"; }

paired_uuid=$(setting device_uuid uuid)
grey "  paired to ${paired_uuid:-unknown}"

check "the cube is reachable before the quit" "$(setting connection connected)" "1"

# ---------------------------------------------------------------------------- the quit
#
# The window is closed first so the relaunch has nothing on screen: the app is about to be asked to reach its cube with
# no window at all, and a Settings window left open would make this the same test `51` already does.

close_settings
since=$(mark)
quit_app
sleep 1

expect_log "quitting lets the cube go" "$since" "%Quit: let go of the device%"
check "and records the app is no longer connected" "$(setting connection connected)" "0"
# The pairing is what the next launch works from, so it has to have survived the quit. `011_setting.sql` says it does;
# this is the one moment that claim is actually load-bearing.
check "the pairing survives it" "$(setting paired paired)" "1"

# ---------------------------------------------------------------------------- the launch that does it by itself

since=$(mark)
ensure_app_running
grey "  launched; nothing will be pressed from here until the reconnect is checked"

expect_log "a paired app decides for itself to look for its cube" "$since" "Paired, so going to look for the cube" 20
# **A scan, not a connect**, which is the fact this feature turns on: CoreBluetooth will not hand back a peripheral by
# identifier, so "reach the cube we are paired to" has to scan for it. See `BluetoothRadio.reach`.
expect_log "and goes looking by scanning, since that is the only way to a peripheral" "$since" "Reaching for %scanning%" 20
expect_log "the radio actually starts listening" "$since" "%Scan started%" 20

grey "  waiting for the cube to answer the launch scan..."
# **The remembered identifier is what may cut the window short, and nothing else is.** Any other cube is collected and
# the scan runs its ten seconds out, because a device that is not the one this app remembers cannot be known to be its
# own until it has taken the PIN. So this row is the ordinary case going fast, and its absence would be a reconnect
# that still arrives, several seconds later.
expect_log "the cube turns up and the scan is done with it" "$since" "%the remembered device turned up%" 20
# **An order, worked out before anything is connected to.** Trying each device as it advertised put a connect, a scan
# being stopped and a modal dialog inside one another: the reach was ended by the very step about to try its first
# candidate, and the tail of that connect then overwrote the retry made from the dialog, wedging the app for the rest
# of the launch (measured 2026-08-23, `BluetoothRadio.beginTryingWhatWasFound`). Collect, then try, is the archive
# shape that fixed it, and this row is the seam between the two halves.
expect_log "and an order is worked out before anything is connected to" "$since" \
    "% device(s) to ask, in the order they will be asked" 20
expect_log "the app opens a link to it" "$since" "Connecting to %" 20
expect_log "and the cube lets it in" "$since" "%PIN accepted%" 60

# **Reconnected, not paired**, and the distinction is the point of `recordReconnection`: the pairing rows already say
# this, so a reconnect writes the connection row and nothing else. A "Paired with" line here would be a record of a
# pairing that did not happen, on every launch, for ever.
expect_log "it is recorded as getting back to the device, not as a new pairing" "$since" "Reconnected to %" 20

already=$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND message LIKE 'Paired with %';")
check "nothing is recorded as a fresh pairing" "$already" "0"

check "the table says the cube is reachable again" \
    "$(wait_sql "1" "SELECT json_extract(setting_value, '\$.connected') FROM setting WHERE setting_name = 'connection';" 15)" "1"
check "and it is still the same device" "$(setting device_uuid uuid)" "$paired_uuid"

# **Nothing was pressed to get here.** The window has been shut since before the quit, so if it is still shut then every
# row above was written by an app deciding for itself. This is the assertion the whole script exists for.
if settings_is_open; then
    fail "the Settings window is open, so this proved nothing about an app nobody is watching"
else
    pass "and none of it needed the Settings window, which has been shut throughout"
fi

# ---------------------------------------------------------------------------- what the tab says afterwards
#
# Now the window may be opened: the claim above is already settled, and what the tab shows is a separate question. It is
# worth asking because the reconnect wrote the row with no pane in existence to redraw -- the values a window shows are
# read when it opens (`CLAUDE.md`), and this is that rule doing something load-bearing.

open_settings
select_tab Device

check_contains "the tab reads as connected, from the row the reconnect wrote" "$(element device-connection)" "Connected"
check_contains "and the Scan button is still gone, the app having a device" "$(tree)" "id=device-forget"

# ---------------------------------------------------------------------------- and it stops when there is no device
#
# The other half of the gate. `paired` is read from the table on every attempt, so forgetting a device has to stop the
# loop without the button knowing the loop exists -- and the launch after a forget must not scan at all. An app that went
# looking anyway would be a radio running for the life of a launch that has no cube, and nothing on screen saying so.

since=$(mark)
press device-forget
sleep 1
close_settings

expect_log "forgetting the device drops the link" "$since" "%Disconnecting from %the device was forgotten%"
check "and unpairs" "$(setting paired paired)" "0"

since=$(mark)
quit_app
sleep 1
ensure_app_running

expect_log "a launch with nothing paired says so" "$since" "Nothing paired, so there is no cube to follow" 20

scans=$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND message LIKE 'Reaching for %';")
check "and does not go looking for one" "$scans" "0"

finish
