#!/bin/bash
# Looking for a TimeFlip, and finding one.
#
# **The only script in this suite that needs the radio**, and the only one whose result depends on something being
# in the room. Everything else here drives a window and reads tables; this one asks CoreBluetooth to listen and
# asserts that a real cube answered, which is the whole point of it: `swift test` covers every decision the filter
# makes and cannot tell you that a single real advertisement ever reaches it.
#
# **Massaged from the archive's technique, not its steps.** `Archive/Tests/Bench/09b-device-rename-checklist.md`
# Step 2 and `16b-manual-mode-pairing-checklist.md` Scenario C both scan and then poll `debug_log` for a `scan` row,
# and that is exactly right: the app writes the row when the advertisement actually arrived, so the wait is as fast
# as the hardware and still correct on a slow one. What did not survive is how they got there -- both hunted the
# button through `first button of group 3 of scroll area 1`, because nothing was addressable, and both matched a
# `listed:%` message this app does not write.
#
# **A missing cube is a failure, not a skip.** The instruction this was written from is that it should find the
# device, so a scan that runs and hears nothing is the thing being reported. A radio that is off or that Facet is
# not allowed to use *is* skipped, because that says nothing about the app: it is the one case where an empty list
# is somebody else's answer. `ScanUnavailable` is the same distinction inside the app.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
start "scanning for a TimeFlip, and finding one"

# The cube has to be there, and only a person can put it there. Declining skips the whole script rather than
# failing it, so the suite stays runnable on a machine with no hardware near it.
if ! action_required \
    "Put your TimeFlip within a few metres of this Mac, and make sure it is awake." \
    "1. Flip the cube onto any face -- a sleeping cube does not advertise, so it cannot be found." \
    "2. Check Bluetooth is on." \
    "3. Press y and leave everything alone; the scan runs by itself." \
    "" \
    "Answer anything else to skip this script. The rest of the run is unaffected."; then
    skip "no TimeFlip was made available, so the scan has nothing to find"
    finish
    exit 0
fi

open_settings
select_tab Device

check_contains "the Device tab is on show" "$(tree)" "id=device-scan"

# ---------------------------------------------------------------------------- the scan
#
# **Filtered, which is the default and the interesting case.** The filter matches the vendor name, the name the cube
# is carrying, and the one before that -- so a device listed here has passed `DeviceScanRules.isEligible` against a
# real advertisement rather than against a value a test made up. That is the claim this script exists for.

since=$(mark)
press device-scan
sleep 1.5

expect_log "pressing Scan starts a filtered scan" "$since" "%Scan requested, TimeFlip only%"

# The button says what pressing it would do, so while a scan runs it offers to stop.
check_contains "and the button offers to stop it" "$(tree | grep -m1 'id=device-scan ' || true)" "Stop Scan"

# **Bluetooth being off is not this app's failure**, and is the one empty list that means nothing about the scan.
# Checked before the wait rather than after it, so an unusable radio costs a second instead of the full timeout.
unavailable=$(sql "SELECT message FROM debug_log WHERE debug_log_id > $since AND message LIKE 'Scan unavailable:%' ORDER BY debug_log_id DESC LIMIT 1;")
if [ -n "$unavailable" ]; then
    skip "the radio is unusable, so nothing can be found ($unavailable)"
    press device-scan
    finish
    exit 0
fi

# **The wait is the test.** Nothing is pressed here: what is being checked is that an advertisement arrives and
# survives the filter. Twenty-five seconds is generous for a cube that is awake and close, and an advertising
# interval is measured in fractions of a second, so a timeout here is a real absence rather than bad luck.
grey "  listening for advertisements..."
found=$(wait_for "$since" "%: peripheral %" 25)
if [ -n "$found" ]; then
    pass "a device answered the scan"
else
    fail "the scan ran for 25 seconds and no TimeFlip answered it"
    press device-scan
    finish
    exit 1
fi

# **Both names, out of the app's own line**, because the scan list is exactly where they disagree: a rename changes
# the GAP name and never the advertised one, so a cube renamed on this desk still advertises `TimeFlip v2.0`. Which
# of the two the row carries is worth having in the record whichever way it comes out.
grey "  $found"

# ---------------------------------------------------------------------------- what the tab shows
#
# The row on screen, not just the log line: a device found and not drawn is the case a log-only check misses, and
# the list is the only part of this feature the user ever sees.

listed=$(tree | grep -c "id=device-scan-result-" || true)
if [ "${listed:-0}" -ge 1 ]; then
    pass "and it is listed on the tab ($listed device(s))"
else
    fail "the app logged a device but drew no row for it"
fi

# A row with no words in it would pass the count above and tell the user nothing. `DeviceScanRules.label` falls back
# to "Unnamed device" rather than to blank, so an empty value here means the label never reached the row.
name=$(tree | grep -m1 "id=device-scan-result-" | sed -E 's/.*value=([^ ]*.*)$/\1/')
if [ -n "$name" ]; then
    pass "the row carries a name ($name)"
else
    fail "the listed device has no name against it"
fi

# ---------------------------------------------------------------------------- stopping
#
# Left off rather than left running: the next script quits the app, and a scan still going when it does is a radio
# this run switched on and never switched off.

since=$(mark)
press device-scan
sleep 1

expect_log "pressing it again stops the scan" "$since" "%Scan stopped%"
check_contains "and the button offers to scan again" "$(tree | grep -m1 'id=device-scan ' || true)" "Scan for Devices"

finish
