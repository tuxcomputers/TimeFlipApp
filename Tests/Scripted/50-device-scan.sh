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
#
# **Asked by `device_required`, which asks once a run.** In script order this is normally the one that does
# the asking and the later device scripts inherit the answer; run on its own, it asks for itself.
if ! device_required; then
    fail "no TimeFlip was made available, so the scan has nothing to find"
    finish
    exit $?
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
# the state callback that follows.
#
# That gap is normally a few milliseconds. **Once, ever, it is however long somebody takes to read a dialogue**: the
# first time this app asks for the radio, macOS asks the user about it. Measured on 2026-08-16 -- run 24 met the
# prompt and checked the button 1.5 seconds in, found it still reading "Scan for Devices", and reported a dead
# button when the app was waiting for an answer. **It does not recur**: once allowed, the app scans without asking,
# a rebuild included. So the long wait below is for a case that happens on one machine one time, and costs nothing
# on every run after it.
# **`Scan started` is the row that means the radio is listening**, as opposed to `Scan requested`, which means only
# that the button was pressed. Waiting on the state callback instead looks equivalent and is not: it fires when the
# state *changes*, so it is written on the first scan of a session and never again, which is exactly how
# `51-device-connect` failed on its first run.
grey "  waiting for the radio to come up..."
if wait_for "$since" "%Scan started%" 60 >/dev/null; then
    pass "the radio answered, and the scan is running"
else
    # **Bluetooth being off is not this app's failure**, and is the one empty list that means nothing about the scan.
    # Checked here rather than before the button: an unusable radio leaves the button reading "Scan for Devices"
    # perfectly correctly, so a check on the title reports the wrong thing, and the reason is written the moment the
    # radio refuses -- so if a scan never started, this is why.
    unavailable=$(dsql "SELECT message FROM debug_log WHERE debug_log_id > $since AND message LIKE 'Scan unavailable:%' ORDER BY debug_log_id DESC LIMIT 1;")
    if [ -n "$unavailable" ]; then
        fail "the radio is unusable, so nothing can be found ($unavailable)"
        finish
        exit $?
    fi
    fail "the radio never answered in 60s -- is the macOS Bluetooth permission prompt waiting?"
    finish
    exit 1
fi

# The button says what pressing it would do, so while a scan runs it offers to stop.
check_contains "and the button offers to stop it" "$(tree | grep -m1 'id=device-scan ' || true)" "Stop Scan"

# **The wait is the test.** Nothing is pressed here: what is being checked is that an advertisement arrives and
# survives the filter. Bounded just past the scan's own window (`BluetoothRadio.timeoutSeconds`, ten seconds), because
# waiting longer than the radio listens is waiting for something nothing is looking for any more. That is still six
# times the slowest advertisement measured (2.12s across eight scans), so a timeout here is a real absence -- a cube
# that is asleep, or not in the room -- rather than bad luck.
grey "  listening for advertisements..."
found=$(wait_for "$since" "%: peripheral %" 13)
if [ -n "$found" ]; then
    pass "a device answered the scan"
else
    fail "the scan ran its full 10 seconds and no TimeFlip answered it -- is the cube awake?"
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
# to "Unnamed device" rather than to blank, so an empty title here means the label never reached the row.
#
# **A title, not a value**, because the row is a button: the whole of it is how you reach the device, so the name is
# what the button is called rather than a label's contents. `51-device-connect` is what presses it.
name=$(tree | grep -m1 "id=device-scan-result-" | sed -E 's/.*title=([^ ]*.*)$/\1/')
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

# **The radio, not the intention.** The row above is the window saying it wants the scan stopped; this is the scanner
# saying it has. They are two rows because they are two things, and only the second one means CoreBluetooth was
# actually told.
#
# The check that used to sit here counted `Scan requested` rows since a baseline taken *before* the press, so it
# counted the scan it had just started and failed on 1 against 0 (run 25). It was measuring nothing either way: a
# request is not what "left scanning" means.
expect_log "and the radio was actually told" "$since" "%Scan stopped%"

# **The timeout.** The only way to prove it is to wait it out: a cube that is awake answers in about a second, so
# nothing shorter than the bound itself distinguishes a scan that ends from one that merely has not been stopped yet.
# The bound is `BluetoothRadio.timeoutSeconds`, ten seconds, plus a few for the write behind it -- it used to be thirty,
# and waiting that out was the slowest thing in this suite for no gain that a measurement could find.
select_tab Device
since=$(mark)
press device-scan
sleep 1
grey "  waiting out the 10 second scan timeout..."
if wait_for "$since" "%Scan timed out%" 15 >/dev/null; then
    pass "a scan nobody stops ends by itself"
else
    fail "the scan was still running 20 seconds in, so the timeout did not fire"
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
