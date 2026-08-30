#!/bin/bash
# Renaming the cube from the Device tab: 0x15 to the hardware, the row written only after it, and the cube still
# found afterwards.
#
# **What needs a real cube is what a rename cannot be told.** Which bytes `0x15` carries, which names are refused and
# what the refusals say are all pinned in `swift test` with no radio in sight (`DeviceCommandRulesTests`,
# `DeviceNameRulesTests`). Three things cannot be:
#
# - that the cube takes the command at all, this being the one write on the tab with no read-back of any kind -- the
#   command result characteristic is never updated for `0x15`, checked at +250 ms, +500 ms, +1 s and +2 s after a
#   rename (finding 2, `docs/timeflip2-firmware-observations.md`);
# - that the app can still find the cube afterwards, which is the regression the previous app actually shipped:
#   renaming a cube to Hazza on 2026-08-01 made every reconnect time out from the next launch onwards, because
#   reconnecting is a scan and the filter matched one name;
# - that nothing is written down until the cube has taken it, which is the first rule in `CLAUDE.md` and the reason
#   the row ids are compared below rather than the two rows merely both being present.
#
# **The name goes back at the end**, and not because anything after this depends on it: `99-quit` wipes the cube and
# clears the row with it. It goes back so a run stopped between here and there leaves the cube as it was found.
#
# **Runs after `65`, which leaves a launched app logged in to the cube, and before the wipe in `99`.**
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
# What this script checks when everything passes. See `finish` in lib.sh for what a mismatch means.
EXPECTED_CHECKS=21
start "renaming the cube from the Device tab"

require_a_paired_cube "there is no cube to rename"

# **The name this script gives the cube**, and the hex `0x15` carries it as: the command, the length, then ASCII.
# Spelled out rather than derived so the pattern below is the bytes somebody can check against the spec by eye.
TEST_NAME="Facet cube"
TEST_BYTES="15 0A 46 61 63 65 74 20 63 75 62 65"

original=$(setting device_name name)
if [ -z "$original" ]; then
    # **Stopped rather than checked**, the way a missing pairing is: the cube has told this Mac no name, so the Name
    # row correctly will not open (`DeviceNameRules.renameRefusal`) and there is nothing here to exercise. That is a
    # bench that has not connected properly rather than an answer about the app.
    red "  the cube has never said what it is called, so there is no name to change"
    red "  every script from 51 onwards runs on a cube that has, so this is a link that never completed"
    finish
    exit 2
fi
step "the cube is called $original, which is what it will be called again by the end"

open_settings
select_tab Device

# ---------------------------------------------------------------------------- the row opens
#
# **Clicking the name is the way in**, the same gesture the Categories tab renames with and the App tab names its
# calendar with. The archive put this behind a right-click menu with one item in it, which is a gesture nobody finds.
#
# **It opens only because a cube is connected.** The gate is `DeviceNameRules.renameRefusal`, and the states it
# refuses are covered without a cube in `13-device-tab` -- what cannot be checked there is the live case, since
# nothing is ever paired below `50`.

press device-name
wait_for_element device-name-field 5
check "clicking the name opens a field, there being a cube to rename" "1" "$(on_tab device-name-field)"

# ---------------------------------------------------------------------------- a name the cube cannot hold
#
# **Refused at submit, not swallowed as it is typed.** An emoji that vanished on the keystroke reads as a broken
# keyboard; left visible and refused with a reason, the alert can say whose limit it is -- the vendor spec defines the
# field as "18 symbols MAX. ASCII coding", so this is the TimeFlip's rule and the app says so.
#
# **And nothing reaches the cube**, which is the half a screenshot would not show: a name that cannot be encoded is
# stopped in front of the radio rather than failing at it.

since=$(mark)
set_field_focused device-name-field "Cube 🎲"
press_return
sleep 1

message=$(python3 scripts/ax-alert.py --message 2>/dev/null)
check_contains "a name the device cannot store is refused with a reason" "$message" "The TimeFlip can only store plain"
check_contains "and the alert says whose limit it is" "$message" "not something this app has decided"
check_contains "and what will work instead" "$message" "18 characters"
check "and nothing was sent to the cube" "0" \
    "$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND message LIKE 'Renaming the cube to%';")"
check "so the stored name is untouched" "$original" "$(setting device_name name)"

press_sheet OK
sleep 1

# ---------------------------------------------------------------------------- the rename itself
#
# **The one command on this tab with no read-back at all.** Auto-pause is confirmed by `0x10` and the double-tap
# registers by `0x17`; this is acknowledged and nothing more, and the row the app writes says exactly that rather
# than claiming a confirmation nobody made.

since=$(mark)
press device-name
wait_for_element device-name-field 5
set_field_focused device-name-field "$TEST_NAME"
press_return

expect_log "the rename goes out as 0x15, its length, then ASCII" "$since" \
    "command withResponse: $TEST_BYTES"
expect_log "and the app says what it sent" "$since" \
    "Renaming the cube to $TEST_NAME"
expect_log "and the cube taking the write is all the evidence there is" "$since" \
    "The cube took the write; nothing can read this command back" 30
expect_log "and only then is the name written down" "$since" \
    "The cube is called $TEST_NAME: renamed from the Device tab" 30

# **The order of those last two, read as row ids rather than trusted from the order they were waited for.**
# `expect_log` polls, so two patterns can both match rows that arrived the other way round -- and what this script
# adds over `swift test` is that the table follows the cube rather than accompanying it.
sent=$(dsql "SELECT MIN(debug_log_id) FROM debug_log WHERE debug_log_id > $since AND message LIKE 'Renaming the cube to $TEST_NAME';")
stored=$(dsql "SELECT MIN(debug_log_id) FROM debug_log WHERE debug_log_id > $since AND message LIKE 'The cube is called $TEST_NAME:%';")
if [ -n "$sent" ] && [ -n "$stored" ] && [ "$stored" -gt "$sent" ]; then
    pass "the row was written after the command went out, not beside it"
else
    fail "the send was row ${sent:-none} and the write row ${stored:-none}"
fi

wait_for_value "SELECT json_extract(setting_value, '\$.name') FROM setting WHERE setting_name = 'device_name';" "$TEST_NAME" 10
check "the table holds the new name" "$TEST_NAME" "$(setting device_name name)"
# **The name it was called before it stays in the scan filter**, which is not sentiment: the GAP name macOS reports
# is one connection stale after a rename, so the scan straight after one is still seeing the old name.
check "and the name before it, which is what the next scan will still be seeing" "$original" \
    "$(setting device_name previous_name)"
check_contains "the Name row shows what the table now holds" "$(element device-name)" "$TEST_NAME"

# **Said at the moment somebody is watching**, because everywhere else will go on showing the old name: the cube
# never changes its advertised name, so a Bluetooth scan lists it as a TimeFlip for ever.
message=$(python3 scripts/ax-alert.py --message 2>/dev/null)
check_contains "and the app says the scan will go on showing the old name" "$message" "advertising"
press_sheet OK
sleep 1

# ---------------------------------------------------------------------------- and the cube is still findable
#
# **The failure this section exists for lost a cube entirely.** Reconnecting is a scan, not a lookup of the stored
# peripheral uuid, so a filter matching only the vendor name loses a renamed cube on the very next launch -- which is
# what the previous app shipped. `DeviceScanRules` matches the vendor default, the remembered name and the one before
# it, and this is the only place that claim meets real hardware.

close_settings
if relink_a_cube; then
    pass "the app found its cube again after the rename and got back to it"
else
    fail "the app could not get back to the cube after renaming it, which is the failure the previous app shipped"
fi

# **And the rename survives that connection, whichever name it reported.** macOS re-reads the GAP name only on
# connecting and can hand out the *previous* one for a connection or two -- so the app may well have just been told
# the cube is called what it was called before the rename. `DevicePairingRules.adoption` is what refuses that, and
# this is the check that says so against real firmware rather than against a string in a unit test: without it the
# tab and the scan filter would swap back to the old name here, and swap forward again on some later connection.
reported=$(dsql "SELECT message FROM debug_log WHERE tag = 'pair' AND message LIKE 'The cube reports the name%' ORDER BY debug_log_id DESC LIMIT 1;")
step "the reconnect ${reported:+reported the name from before the rename, which was refused}${reported:-reported nothing that contradicted the rename}"
check "the rename stands after a reconnect" "$TEST_NAME" "$(setting device_name name)"
check "and the name before it is still there for the scan filter" "$original" "$(setting device_name previous_name)"

# ---------------------------------------------------------------------------- putting the name back
#
# **A rename like any other**, which is why it is checked rather than done quietly: renaming twice is the case where
# `previous_name` has something to displace, and it is the one thing about the row that is easy to get wrong.

open_settings
select_tab Device

since=$(mark)
press device-name
wait_for_element device-name-field 5
set_field_focused device-name-field "$original"
press_return

expect_log "renaming it back reaches the cube too" "$since" \
    "The cube is called $original: renamed from the Device tab" 30
wait_for_value "SELECT json_extract(setting_value, '\$.name') FROM setting WHERE setting_name = 'device_name';" "$original" 10
check "the cube is called what it was called again" "$original" "$(setting device_name name)"
check "and the test name is what the filter now keeps behind it" "$TEST_NAME" \
    "$(setting device_name previous_name)"

press_sheet OK
sleep 1

close_settings
finish
