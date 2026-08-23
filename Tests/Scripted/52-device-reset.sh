#!/bin/bash
# Putting a cube back to how it left the factory, and proving it took.
#
# **The claim is not that `0xFF` was sent.** Sending it is the easy half and the app could always do that; what this
# script exists for is the half that was broken. A reset is only complete when the cube **lets the app in on the vendor
# PIN** -- a device still holding this app's PIN has plainly not been erased -- and none of that is reachable from
# `swift test`: the rules and the rows it writes are covered there in full, but whether the cube ever comes back, and
# how long it takes to, are questions only a cube can be asked.
#
# **This is the check that would have caught the bug it was written after.** On 2026-08-17 the reset reported nothing
# for 104 seconds and was abandoned, while the cube had in fact been wiped perfectly. The cause was the app waiting for
# the link to drop: the archive assumed a reset reboots the device and severs the connection, and on FW_v3.64 it does
# not (finding 6 in `docs/timeflip2-firmware-observations.md`). Every unit test passed throughout. So the assertions
# below are deliberately about the *sequence* rather than the outcome alone -- that the app lets go of the link itself,
# and that it keeps asking until the cube answers.
#
# **It wipes the cube, every run.** Face colours, task settings, the name and the PIN all go back to factory. That is
# recoverable in seconds -- the cube comes back on 000000, which is the first PIN a connect presents -- but it is a real
# change to somebody's device, so it is asked about before anything happens: by `ask_about_the_device`, once, in
# `00-setup` at the very top of the run, in a prompt that says in full what is erased. Answer anything but yes there
# and the run stops at `50-device-scan`, long before this.
#
# **It needs the cube twice**: connected first, because a reset is a command that has to arrive somewhere, and then
# again as it comes back. So it pairs from scratch rather than assuming an earlier script left a pairing behind.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
# What this script checks when everything passes. See `finish` in lib.sh for what a mismatch means.
EXPECTED_CHECKS=33
start "resetting a TimeFlip to factory settings"

# **The cube is already factory reset when this starts**, because `00-setup` pairs one and wipes it. That is not a
# rehearsal of this script: setup only drives the sequence and reads the end state, while everything below asserts
# each step of it. What it does mean is that this reset is the second of the run, on a cube 51 re-paired.
#
# **No cube check here.** `00-setup` asked once and `50-device-scan` stops the run if the answer was no, so
# anything reaching this line has a cube: every script between them needs one, and none of them runs after 50
# has failed. A second gate here would be a branch that can never be taken, and an untaken branch is checks
# that silently do not run.

open_settings
select_tab Device

# ---------------------------------------------------------------------------- a cube to reset
#
# **Paired from scratch by `pair_a_cube`**, not inherited. `51-device-connect` leaves a pairing behind on a passing run,
# but a script that depended on it would skip whenever `51` skipped and would silently test nothing after a reordering.
# The cost is one scan.
#
# An unusable radio is a skip, since it says nothing about the app. Anything else is a failure: this script's subject is
# what happens to a cube that is right there, so being unable to reach one is not a result.

pair_a_cube
case $? in
    0) pass "paired a cube to reset" ;;
    2)
        fail "the radio is unusable, so there is nothing to reset ($PAIR_REASON)"
        finish
        exit $?
        ;;
    *)
        fail "could not pair a cube, so there is nothing to reset: $PAIR_REASON"
        close_settings
        finish
        exit 1
        ;;
esac

# The name is read before the reset takes it away, so the assertion further down has something to compare against.
name_before=$(sql "SELECT IFNULL(json_extract(setting_value, '\$.name'), '') FROM setting WHERE setting_name = 'device_name';")
grey "  the cube is calling itself '$name_before'"

# ---------------------------------------------------------------------------- the button, and what it asks first
#
# **Reset is the one control on this tab gated on the connection**, and Forget beside it is deliberately not: one is a
# command that has to reach the hardware, the other is the app's own rows. That difference is worth a check, because a
# live Reset with nothing connected would report a wipe that never left the Mac.

reset_line=$(element device-reset)
check_contains "the paired tab offers Reset Device" "$reset_line" "title=Reset Device"
case "$reset_line" in
    *disabled*) fail "Reset is dead with a cube connected, so it can never be pressed" ;;
    *) pass "and it is live, a cube being connected" ;;
esac
check_contains "Forget Device is offered beside it" "$(element device-forget)" "title=Forget Device"
# The scan controls are gone, which is the swap this section makes on being paired.
check "and the Scan button is not, a device being paired" "" "$(element device-scan)"

since=$(mark)
press device-reset
sleep 1

expect_log "pressing it is recorded" "$since" "Button clicked: Reset Device"

# **Asked before anything is sent, unlike Forget.** The difference is what it costs to be wrong: forgetting changes
# nothing on the cube, and this erases it.
if ! alert_is_open; then
    fail "Reset sent no confirmation, so a press would wipe the cube with nothing asked"
    close_settings
    finish
    exit 1
fi
pass "it asks before wiping anything"

check_contains "the sheet says what is about to happen" "$(python3 scripts/ax-alert.py --message 2>/dev/null)" "cannot be undone"

# **Cancel is drawn first and that is AppKit's doing, not the code's**: a button titled Cancel is relocated to the left
# whatever order it was added in, which is why the key equivalents are set by hand. Asserted in the drawn order so a
# future change that lets Return land on the destructive answer fails here.
check "the sheet offers exactly Cancel and Reset Device, in that order" "Cancel|Reset Device" "$(alert_buttons)"

# ---------------------------------------------------------------------------- declining it
#
# **Checked before the real thing, because it is the answer that must change nothing.** A confirmation that wipes the
# cube either way is worse than none: somebody who read it and thought better of it has been overruled.

since=$(mark)
press_sheet Cancel
sleep 1

expect_log "cancelling says so" "$since" "The reset was called off"
check "and nothing was sent to the cube" "0" "$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND tag = 'ble-tx' AND message LIKE 'command %FF%';")"
check "the app still has its device" "1" "$(sql "SELECT json_extract(setting_value, '\$.paired') FROM setting WHERE setting_name = 'paired';")"
if alert_is_open; then
    fail "the sheet is still up after Cancel, so every later press lands on nothing"
    close_settings
    finish
    exit 1
fi

# ---------------------------------------------------------------------------- the reset itself

since=$(mark)
press device-reset
sleep 1
press_sheet "Reset Device"

expect_log "the command goes out on the command characteristic" "$since" "Sending the factory reset command" 20
# The bytes, as bytes. One byte and no arguments, which is the whole of 0xFF.
sent=$(dsql "SELECT message FROM debug_log WHERE debug_log_id > $since AND tag = 'ble-tx' AND message LIKE 'command %' ORDER BY debug_log_id LIMIT 1;")
check_contains "and it is 0xFF, on its own" "$sent" "command withResponse: FF"
expect_log "the cube acknowledges the write" "$since" "command: write acknowledged" 20

# **The assertion the bug is named after.** The app must let go of the link itself rather than waiting for the cube to
# drop it, because on this firmware the cube does not: the link stayed up for 104 seconds while nothing happened. If a
# future change goes back to waiting for a disconnect, this is the line that says so.
expect_log "the app lets go of the link rather than waiting for the cube to" "$since" "Reset sent; letting go of the link%" 20
expect_log "and drops it deliberately" "$since" "Disconnecting from %the cube is being reset"

# **Then it keeps asking.** The cube goes on answering its old PIN for several seconds after acknowledging the reset
# (8.5s and 11s across two measured runs), so a single attempt is not enough and the retry is the feature rather than a
# safety net. Only that the loop runs is asserted, not how many times: that is the cube's business and it varied.
expect_log "it goes looking for the cube on the vendor PIN" "$since" "Trying the vendor PIN%" 30

grey "  waiting for the cube to finish erasing and answer (up to 140s)..."
verdict=$(wait_for "$since" "Reset: %" 140)
case "$verdict" in
    *confirmed*) pass "the cube let the app in on the vendor PIN, which is the wipe proved" ;;
    *notConfirmed*)
        fail "the cube never came back on the vendor PIN -- the command went, but the app cannot say the wipe happened"
        close_settings
        finish
        exit 1
        ;;
    *notSent*)
        fail "the reset command was never sent"
        close_settings
        finish
        exit 1
        ;;
    *)
        fail "no verdict on the reset within 140s"
        close_settings
        finish
        exit 1
        ;;
esac

# **A confirming login is not a pairing**, which is the archive's rule: the cube is a pristine unpaired device now, and
# treating the proof as a pairing would leave the app holding the very thing it was told to give up.
expect_log "and it lets go once the wipe is proved" "$since" "Disconnecting from %the reset is over"
check "the login that proved it did not pair anything" "0" "$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND message LIKE 'Paired with %';")"

# ---------------------------------------------------------------------------- what a confirmed reset wrote

expect_log "the reset is written down" "$since" "Reset the cube and forgot it"

check "the app no longer has a device" "0" "$(sql "SELECT json_extract(setting_value, '\$.paired') FROM setting WHERE setting_name = 'paired';")"
check "and does not remember which one it was" "" "$(sql "SELECT IFNULL(json_extract(setting_value, '\$.uuid'), '') FROM setting WHERE setting_name = 'device_uuid';")"
check "the connection is down with it" "0" "$(sql "SELECT json_extract(setting_value, '\$.connected') FROM setting WHERE setting_name = 'connection';")"

# **What the cube said it was goes too**, and this is the row a plain Forget also clears: only what a cube answers is
# ever written, so a second cube exposing no Device Information service would otherwise wear this one's firmware.
check "what the cube said it was is cleared" "" "$(sql "SELECT IFNULL(json_extract(setting_value, '\$.firmware'), '') FROM setting WHERE setting_name = 'device_info';")"

# **The name is taken out of use but kept in the scan filter**, which is this app's departure from the archive. A wiped
# cube answers to the vendor default, so the remembered name is wrong about the hardware and must not be presented as
# its name -- but 0xFF has no usable acknowledgement, and a wipe that silently failed leaves a cube still carrying the
# old name. `previous_name` is already in the filter, so keeping it there covers both outcomes.
check "the cube's name is no longer presented as its name" "" "$(sql "SELECT IFNULL(json_extract(setting_value, '\$.name'), '') FROM setting WHERE setting_name = 'device_name';")"
if [ -n "$name_before" ]; then
    check "but it is kept where a scan can still match it" "$name_before" "$(sql "SELECT IFNULL(json_extract(setting_value, '\$.previous_name'), '') FROM setting WHERE setting_name = 'device_name';")"
else
    pass "the cube never told this Mac its name, so there was none to keep"
fi

# ---------------------------------------------------------------------------- what the tab says
#
# **Read off the tab, not off the table.** The rows above prove what was written; these prove the window went back to
# the table and drew what it now says, which is the other half of `CLAUDE.md`'s rule about reading back after a write.

check_contains "the tab says the cube was reset" "$(element device-scan-status)" "back to factory settings"
check_contains "the Name row is back to Not paired" "$(element device-name)" "Not paired"
# Nothing is paired, so the app has nothing to follow and times by hand again.
check_contains "and the Connection row says manual mode" "$(element device-connection)" "Manual mode"

# The swap goes back the other way: with no device there is a cube to look for again.
check_contains "the Scan button is back" "$(element device-scan)" "title=Scan for Devices"
check "and Reset is gone with the pairing" "" "$(element device-reset)"

close_settings
finish
