#!/bin/bash
# Manual mode with a device still paired: what a click may do before it is chosen, and what the app stops doing after.
#
# **The only script that needs the cube to go away**, which is why it needs a person twice: turning this Mac's
# Bluetooth off is the one way to make a paired cube unreachable without carrying it out of the building, and nothing
# on this machine may turn a radio off on somebody's behalf.
#
# **Two states, and they are opposites, which is the whole point.**
#
#   1. **Paired, the link gone, and manual mode not chosen.** The app has a cube and is looking for it. A click on a
#      category is refused: an app that quietly started its own clock would record against one category while the cube
#      records against whatever face it is sitting on, and whichever was read later would look like the answer.
#   2. **Paired, and manual mode chosen.** Somebody has said to get on without the device. Now the click starts the
#      clock, and the app stops reaching for the cube for the rest of the launch -- it does not go back to looking when
#      the radio comes back, and it does not put the question up again.
#
# **Why a restart sits between them.** The offer only ever appears to a launch that has *never* reached its cube
# (`ManualModeOffer`), so losing the link mid-session retries quietly for ever and never asks. Getting the question on
# screen therefore takes a quit and a relaunch with the cube already out of reach, which is exactly the morning this
# feature exists for.
#
# **The offer is an app-modal `NSAlert`, not a sheet**, so `ax-alert.py` cannot see it -- that tool addresses `AXSheet`
# and this is a window of its own. It is pressed by title instead, which is unambiguous here because no other control
# in the app is called "Switch to Manual Mode" (the trap Method 12 records applies to sheets naming their button after
# the control that opened them). Whether an `AXPress` actuates a button inside a modal run loop is not something this
# suite has measured before, so the press is followed by a poll and a person is asked only if it did not take.
#
# **It leaves Bluetooth back on and the device forgotten**, both deliberately: `99-quit` wipes the cube so this run's
# timings cannot reach production, and it can do neither with the radio off.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
start "manual mode with a device paired: what it refuses, and what it stops doing"

if ! device_required; then
    skip "no TimeFlip was made available, so there is no pairing to lose"
    finish
    exit 0
fi

setting() { sql "SELECT json_extract(setting_value, '\$.$2') FROM setting WHERE setting_name = '$1';"; }

# **Whatever happens from here, the radio has to be back on when this script ends.**
#
# This is the only script that turns a system service off, and every way out of it -- a check failing, a prompt
# declined, somebody pressing Ctrl-C -- is a way out that would otherwise leave it off. `99-quit` wipes the cube so
# this run's timings cannot reach production, and it can do neither without Bluetooth: an unwiped cube puts them in
# front of the next launch against the **real** database.
#
# A trap rather than a call at each exit, because the exits that matter are the ones nobody thought of.
BLUETOOTH_IS_OFF=0
restore_bluetooth() {
    [ "$BLUETOOTH_IS_OFF" = "1" ] || return 0
    BLUETOOTH_IS_OFF=0
    echo ""
    yellow "##############################################################################"
    yellow "##"
    yellow "##  TURN BLUETOOTH BACK ON"
    yellow "##"
    yellow "##  This script turned it off and is ending with it still off."
    yellow "##  99-quit wipes the cube so this run's timings cannot reach production,"
    yellow "##  and it cannot do that with the radio off."
    yellow "##"
    yellow "##############################################################################"
    echo ""
    [ -r /dev/tty ] || return 0
    printf '  Press Return once Bluetooth is back on: '
    read -r _ < /dev/tty || true
    echo ""
}
trap restore_bluetooth EXIT INT TERM

# The status item's line, which is where a reading that followed a cube would show up.
status_item() {
    python3 scripts/ax-dump.py --menu-bar 2>/dev/null | grep -m1 "id=status-item" || true
}

open_settings
select_tab Device

# ---------------------------------------------------------------------------- a cube to lose

link=$(mark)
if ! pair_a_cube; then
    skip "no cube could be paired, so there is nothing to lose ($PAIR_REASON)"
    close_settings
    finish
    exit 0
fi
pass "paired a cube to lose"
check "and the app can reach it" "1" "$(setting connection connected)"

# ---------------------------------------------------------------------------- the link goes
#
# **Turned off rather than walked away from**, because a scripted run has to be able to do this again tomorrow. What
# the app sees is the same either way: `centralManagerDidUpdateState` reports a radio that is no longer powered on, and
# every peripheral goes with it.

select_tab Faces

dropped=$(mark)
if ! action_required \
    "Turn Bluetooth OFF on this Mac" \
    "The menu bar's Bluetooth control, or System Settings -> Bluetooth." \
    "This is the only way to put a paired cube out of reach without carrying it away." \
    "Leave it off until this script asks for it back -- it will."
then
    skip "Bluetooth was not turned off, so the cube never went out of reach"
    close_settings
    finish
    exit 0
fi
# From here the trap above owns getting it back on, however this script ends.
BLUETOOTH_IS_OFF=1

expect_log "the app notices the cube has gone" "$dropped" "The cube went away%" 30
check "and records that it can no longer reach it" \
    "$(wait_sql "0" "SELECT json_extract(setting_value, '\$.connected') FROM setting WHERE setting_name = 'connection';" 20)" "0"
# **The pairing is untouched**, which is what makes the next section a test of anything: going out of range does not
# change which device this app is paired to, so what follows is a *paired* app with no cube.
check "the pairing survives it" "1" "$(setting paired paired)"

# ---------------------------------------------------------------------------- and a click is refused
#
# **No offer is on screen here**, and that is `ManualModeOffer`'s rule rather than a timing accident: this launch has
# reached its cube, so a drop is retried quietly for ever and the question is never put. So the window is usable, which
# is the only reason this state can be driven at all.

BREAK=$(sql "SELECT category_id FROM category WHERE category_name = 'Break';")
open_before=$(sql "SELECT COUNT(*) FROM device_event WHERE finalised != 1;")
# **Both manual faces as they stand, not as they ought to stand.** `05-faces-timing` starts Break by hand, so one of
# them may well be holding it already when this runs -- and a check that asserted "no manual face holds Break" would
# fail on a rotation an earlier script left behind rather than on anything this click did.
faces_before=$(sql "SELECT group_concat(face_id || ':' || category_id, ',') FROM face WHERE face_id IN (13, 14) ORDER BY face_id;")
since=$(mark)
press "category-row-$BREAK"
sleep 1.5

expect_log "a click is refused while a device is paired and manual mode has not been chosen" "$since" \
    "%was not started -- a device is paired, and manual mode has not been chosen"
check "so no segment is opened" "$open_before" "$(sql "SELECT COUNT(*) FROM device_event WHERE finalised != 1;")"
# The failure that would matter most: falling through to the manual path, which writes the category onto the next
# manual face -- so a refused click would quietly rearrange the rotation on its way to doing nothing.
check "and the manual faces are left exactly as they were" "$faces_before" \
    "$(sql "SELECT group_concat(face_id || ':' || category_id, ',') FROM face WHERE face_id IN (13, 14) ORDER BY face_id;")"

# ---------------------------------------------------------------------------- the restart that asks
#
# The offer is a startup-only question, so getting it on screen takes a launch that begins with the cube already out of
# reach. That is the morning this whole feature is for.

close_settings
quit_app
sleep 1

launched=$(mark)
ensure_app_running

expect_log "a paired app still goes looking for its cube" "$launched" "Paired, so going to look for the cube" 30
expect_log "and, finding nothing, offers manual mode rather than retrying behind a silent menu bar" "$launched" \
    "Offering manual mode:%" 60

# ---------------------------------------------------------------------------- taking it
#
# Pressed by title, then polled. A press that does not actuate and a press that did are both silent, and the row is the
# only thing that tells them apart -- so the person is asked only after the automated attempt has been shown not to
# have worked.

chosen=$(mark)
press_title "Switch to Manual Mode"
sleep 2

if ! wait_for "$chosen" "Manual mode chosen;%" 5 >/dev/null; then
    grey "  the alert did not answer to an AXPress, so asking for a hand"
    if ! action_required \
        "Click **Switch to Manual Mode** on the dialog" \
        "The app could not find your TimeFlip, and is asking what to do about it." \
        "Do not click Retry: this script is about what happens after manual mode is taken."
    then
        skip "the offer was not answered, so nothing below it could be checked"
        finish
        exit 0
    fi
fi

expect_log "choosing it stops the loop for the rest of the launch" "$chosen" "Manual mode chosen;%" 60
expect_log "and the mode is recorded as on, with the pairing untouched" "$chosen" "Manual mode: on,%" 10
check "the device is still this app's device" "1" "$(setting paired paired)"

# ---------------------------------------------------------------------------- now the click is allowed
#
# The same click as before, in the same state of the table, answered differently because somebody answered.

open_settings
select_tab Faces
since=$(mark)
press "category-row-$BREAK"
sleep 1.5

expect_log "the same click now starts the clock" "$since" "Timing: started \"Break\"%"
check "and a segment is open" "1" "$(sql "SELECT COUNT(*) FROM device_event WHERE finalised != 1;")"
check_contains "the menu bar is timing it" "$(status_item)" "Break"

# ---------------------------------------------------------------------------- and the radio is left alone
#
# **The claim being tested is an absence**, so it is measured over a window rather than at an instant: the backoff
# would have reached out again within thirty seconds at the very most, and the radio coming back is the event most
# likely to provoke it.

close_settings
quiet=$(mark)
if ! action_required \
    "Turn Bluetooth back ON" \
    "The cube is in range again, and the app should carry on ignoring it." \
    "Nothing will appear to happen. That is the check."
then
    skip "Bluetooth was left off, so what the app does when the cube comes back was not checked"
    finish
    exit 0
fi
# Said to be back on. The scan at the end of this script is what actually proves it, and until that passes the trap
# stays armed -- a person answering a prompt is not evidence, which is this suite's whole first principle.

grey "  watching for 40s to see whether the app reaches for the cube..."
sleep 40

check "the app does not go back to looking for the cube" "0" \
    "$(sql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $quiet AND message LIKE 'Looking for the cube again%';")"
check "it starts no scan of its own" "0" \
    "$(sql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $quiet AND message LIKE '%Scan started%';")"
check "and reaches for nothing" "0" \
    "$(sql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $quiet AND message LIKE 'Reaching for %';")"
# **The offer does not come back either.** Being asked again would be the app inviting somebody to decide something
# they have already decided.
check "the question is not put again" "0" \
    "$(sql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $quiet AND message LIKE 'Offering manual mode:%';")"
check "so nothing is connected" "0" "$(setting connection connected)"
# The menu bar is still drawing what the app is timing by hand. A cube that had crept back in would be drawn instead,
# with no clock, so the figure is what says the reading is still the manual one.
check_contains "and the menu bar is still timing by hand" "$(status_item)" "Break"

# ---------------------------------------------------------------------------- the way back out
#
# Two ways out and this is the one a script can take: forgetting the device. (The other is quitting and starting the
# app, which every later run does anyway -- the mode is per-launch and in memory, so a relaunch works it out again from
# `paired`.) It is also what `99-quit` needs, since it cannot wipe a cube this script left unreachable.

open_settings
select_tab Device
since=$(mark)
press device-forget
sleep 1.5

check "forgetting the device gives the pairing up" "0" "$(setting paired paired)"
expect_log "and manual mode stays on, now for its own reason" "$since" "Manual mode: on, no device is paired" 10
# The Scan button is hidden while a cube is paired, so its coming back is the whole of what "and reconnect" means.
if [ -n "$(element device-scan)" ]; then
    pass "the Scan button is back, which is the way to a cube again"
else
    fail "no Scan button after forgetting the device, so there is no way back to a cube"
fi

# **A scan, run for its own sake**: it proves the radio really is back on, which every script after this one depends
# on -- `99-quit` cannot wipe the cube without it, and an unwiped cube puts this run's timings in front of the next
# launch against production.
since=$(mark)
press device-scan
if wait_for "$since" "%Scan started%" 30 >/dev/null; then
    pass "and the radio answers, so Bluetooth is really back on"
    # Proven, so the trap has nothing left to do.
    BLUETOOTH_IS_OFF=0
else
    fail "the radio did not come up -- is Bluetooth still off? 99-quit cannot wipe the cube without it"
fi
sleep 11
press device-scan

close_settings
finish
