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
    "The FIRST scan on a new build makes macOS ask whether Facet may use Bluetooth." \
    "If that prompt appears, allow it -- until you do, the radio never answers and" \
    "this script fails with the scan never starting." \
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
sleep 0.5

expect_log "pressing Scan starts a filtered scan" "$since" "%Scan requested, TimeFlip only%"

# **Waited for, not slept through**, which is the rule the archive wrote down and this script broke on its first run.
# Pressing the button does not start a scan: `start` builds the central manager and returns, and the scan begins in
# the state callback that follows. On the first use of a new build that gap holds the macOS Bluetooth permission
# prompt, so it is as long as somebody takes to answer -- run 24 checked the button 1.5 seconds in, found it still
# reading "Scan for Devices", and reported a dead button when the app was waiting for an answer.
grey "  waiting for the radio to come up..."
if wait_for "$since" "%Bluetooth state:%" 60 >/dev/null; then
    pass "the radio answered"
else
    fail "the radio never answered in 60s -- is the macOS Bluetooth permission prompt waiting?"
    finish
    exit 1
fi

# **Bluetooth being off is not this app's failure**, and is the one empty list that means nothing about the scan.
# Checked before the button rather than after it: an unusable radio leaves the button reading "Scan for Devices"
# perfectly correctly, so checking the title first reports the wrong thing.
unavailable=$(sql "SELECT message FROM debug_log WHERE debug_log_id > $since AND message LIKE 'Scan unavailable:%' ORDER BY debug_log_id DESC LIMIT 1;")
if [ -n "$unavailable" ]; then
    skip "the radio is unusable, so nothing can be found ($unavailable)"
    finish
    exit 0
fi

# The button says what pressing it would do, so while a scan runs it offers to stop.
check_contains "and the button offers to stop it" "$(tree | grep -m1 'id=device-scan ' || true)" "Stop Scan"

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

# ---------------------------------------------------------------------------- stopping, three ways
#
# **A scan has to end by itself as well as on request**, because the ways it can be abandoned outnumber the ways it
# can be stopped deliberately. Until it was bounded there was none of this: the radio listened until somebody pressed
# the button again, and closing the window left it listening for the rest of the session with no control on screen to
# stop it and nothing saying it was happening.

since=$(mark)
press device-scan
sleep 1

expect_log "pressing it again stops the scan" "$since" "%Scan stopped%"
check_contains "and the button offers to scan again" "$(tree | grep -m1 'id=device-scan ' || true)" "Scan for Devices"

# **Leaving the tab.** The list it is filling is on the Device tab and nowhere else, so a scan running behind the
# Report tab is a radio on with no way to see it.
since=$(mark)
press device-scan
sleep 1.5
select_tab Report
sleep 1

expect_log "leaving the Device tab stops the scan" "$since" "%Stopping the scan: the Report tab was selected%"
check "and nothing is left scanning" "0" \
    "$(sql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND message LIKE 'Scan requested%';")"

# **The timeout.** The one that costs this script real time, and the only way to prove it: a cube that is awake
# answers in about a second, so nothing shorter than the bound itself distinguishes a scan that ends from one that
# merely has not been stopped yet. Thirty seconds plus a few for the write behind it.
select_tab Device
since=$(mark)
press device-scan
sleep 1
grey "  waiting out the 30 second scan timeout..."
if wait_for "$since" "%Scan timed out%" 40 >/dev/null; then
    pass "a scan nobody stops ends by itself"
else
    fail "the scan was still running 40 seconds in, so the timeout did not fire"
fi
check_contains "and the button offers to scan again" "$(tree | grep -m1 'id=device-scan ' || true)" "Scan for Devices"

# **Closing the window** is the third way, and the one the archive handled that this app first did not. Checked last
# because it leaves the window shut, which is where `99-quit` wants it anyway.
since=$(mark)
press device-scan
sleep 1.5
close_settings
sleep 1

expect_log "closing the window stops the scan" "$since" "%Stopping the scan: the Settings window closed%"

finish
