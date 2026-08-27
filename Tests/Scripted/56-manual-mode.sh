#!/bin/bash
# Manual mode with a device still paired: what a click may do before it is chosen, and what the app stops doing after.
#
# **The only script that needs the cube to go away**, which is why it needs a person twice: turning this Mac's
# Bluetooth off is the one way to make a paired cube unreachable without carrying it out of the building, and nothing
# on this machine may turn a radio off on somebody's behalf.
#
# **Two states, and what separates them is narrower than it used to be.**
#
#   1. **Paired, the link gone, and the app still looking.** A click on a category is refused: an app that quietly
#      started its own clock would record against one category while the cube records against whatever face it is
#      sitting on, and whichever was read later would look like the answer.
#   2. **Paired, and Stop Looking chosen.** Somebody has said to give up on the device. The app stops reaching for the
#      cube for the rest of the launch -- it does not go back to looking when the radio comes back, and it does not
#      put the question up again. **The click is still refused**, and that is the change this script now pins: the
#      answer settles the reconnect loop and does not turn the launch into its own clock.
#
# **Why the second state no longer starts the clock.** A launch decides once whether it follows a cube or is its own
# clock, and nothing moves it after that (`LaunchMode`). This script used to press the offer's second button and watch
# the same click go from refused to allowed; that was one launch being two things in turn, and the switching it needed
# is what was removed. The way to timing by hand is a forget and a restart, which is what the dialog now says.
#
# **Why a restart sits between them.** The offer only ever appears to a launch that has *never* reached its cube
# (`ManualModeOffer`), so losing the link mid-session retries quietly for ever and never asks. Getting the question on
# screen therefore takes a quit and a relaunch with the cube already out of reach, which is exactly the morning this
# feature exists for.
#
# **The offer is an app-modal `NSAlert`, not a sheet**, so `ax-alert.py` cannot see it -- that tool addresses `AXSheet`
# and this is a window of its own. It is pressed by title instead, which is unambiguous here because no other control
# in the app is called "Stop Looking" (the trap Method 12 records applies to sheets naming their button after the
# control that opened them). Whether an `AXPress` actuates a button inside a modal run loop is not something this
# suite has measured before, so the press is followed by a poll and a person is asked only if it did not take.
#
# **It leaves Bluetooth back on and the device forgotten**, both deliberately: `99-quit` wipes the cube so this run's
# timings cannot reach production, and it can do neither with the radio off.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
# What this script checks when everything passes. See `finish` in lib.sh for what a mismatch means.
EXPECTED_CHECKS=28
start "manual mode with a device paired: what it refuses, and what it stops doing"

# **No cube check here.** `00-setup` asked once and `50-device-scan` stops the run if the answer was no, so
# anything reaching this line has a cube: every script between them needs one, and none of them runs after 50
# has failed. A second gate here would be a branch that can never be taken, and an untaken branch is checks
# that silently do not run.


# **Whatever happens from here, the radio has to be back on when this script ends**, which `watch_bluetooth` in
# lib.sh is what arranges: `99-quit` wipes the cube so this run's timings cannot reach production, and it can do
# neither with the radio off. `BLUETOOTH_IS_OFF` is set below, once the radio is actually off, and cleared at the end
# once a scan has proved it back on -- so every failure between the two reaches the trap with it still set.
watch_bluetooth

open_settings
select_tab Device

# ---------------------------------------------------------------------------- a cube to lose
#
# **The one `55-device-face` put back**, inherited rather than paired for -- see `require_a_paired_cube` in lib.sh.
# That the app can reach it right now is a precondition and not a check: the radio going off below is what this
# script is about, and a cube that was never in reach cannot be taken out of it.

require_a_paired_cube "there is nothing to lose"

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
    fail "Bluetooth was not turned off, so the cube never went out of reach"
    close_settings
    finish
    exit $?
fi
# From here the trap above owns getting it back on, however this script ends.
BLUETOOTH_IS_OFF=1

expect_log "the app notices the cube has gone" "$dropped" "The cube went away%" 30
check "and records that it can no longer reach it" \
    "$(wait_sql "0" "SELECT json_extract(setting_value, '\$.connected') FROM setting WHERE setting_name = 'connection';" 20)" "0"
# **The pairing is untouched**, which is what makes the next section a test of anything: going out of range does not
# change which device this app is paired to, so what follows is a *paired* app with no cube.
check "the pairing survives it" "1" "$(setting paired paired)"

# ---------------------------------------------------------------------------- it is still the cube being shown
#
# **A cube that has gone quiet is not the app timing by hand**, and telling those apart on screen is the whole of the
# bug fixed on 2026-08-23. `deviceFace` goes with the link, and the reading then fell through to the app's own faces
# and built a session out of them: the menu bar drew a category on face 13 that nobody had picked, ticking, while the
# Device tab said the cube was unreachable and manual mode was off throughout. Two pictures of one question.
#
# What it draws now is the cube's own last word, out of `device_event`. The archive kept a `reconnecting` state for
# exactly this, "so the menu bar keeps showing the last known activity/icon instead of tearing down to an unpaired
# look" -- and it is asserted here rather than in `swift test` because the fall-through was invisible to a unit test
# that never had a real link to lose.

cube_face=$(sql "SELECT device_face FROM device_event WHERE device_face BETWEEN 1 AND 12 ORDER BY device_event_id DESC LIMIT 1;")
cube_category=$(sql "SELECT c.category_name FROM face f JOIN category c ON c.category_id = f.category_id WHERE f.face_id = ${cube_face:-0};")
if [ -n "$cube_category" ]; then
    check_contains "the menu bar still names the cube's category, not one of the app's faces" \
        "$(status_item)" "$cube_category"
    # **Yellow is the whole of what "showing it without standing behind it" looks like**, and this is the only place
    # in the suite that can produce the state: the line is still drawing the cube's last face, and the colour is what
    # says nobody can confirm it any more. The two failures it rules out are the two that look identical on a
    # screenshot -- green, which would be the app claiming a live reading from a radio that is off, and cyan, which
    # would be the fall-through to the app's own faces this section exists to catch.
    #
    # It also pins that yellow takes the line whole rather than sharing it: a limit's red or a battery flash showing
    # through here would be a colour left over from before the drop.
    expect_colours "and the line turns yellow, nothing about it being confirmable any more" \
        "name yellow, glyph label, figure yellow" 30
else
    # A cube whose face holds no category is a real state and not a failure: what matters is that the item is not
    # showing a manual session instead, which the check below covers either way.
    pass "the cube's face holds no category, so there is no name to keep showing (face ${cube_face:-none})"
    # The same claim in the state that has nothing to draw: with no category there is no reading to colour, so the
    # line is the ordinary text colour rather than a yellow one. Cyan here would still be the fall-through.
    expect_colours "and the line is the ordinary text colour, there being no reading to colour" \
        "name label, glyph label, figure label" 30
fi

# **The app's own clock is what must not appear.** `05-faces-timing` times Break by hand earlier in the run, so a
# fall-through would put exactly that on the item -- which is why this names the manual faces' categories rather than
# a fixed word.
manual_category=$(sql "SELECT c.category_name FROM face f JOIN category c ON c.category_id = f.category_id WHERE f.face_id IN (13, 14) ORDER BY f.face_id DESC LIMIT 1;")
if [ -n "$manual_category" ] && [ "$manual_category" != "$cube_category" ]; then
    if [[ "$(status_item)" == *"$manual_category"* ]]; then
        fail "the menu bar fell through to the app's own face and is showing $manual_category"
    else
        pass "and it has not fallen through to the app's own face ($manual_category)"
    fi
else
    pass "no manual face holds a different category, so there is nothing to have fallen through to"
fi

# ---------------------------------------------------------------------------- and a click is refused
#
# **No offer is on screen here**, and that is `ManualModeOffer`'s rule rather than a timing accident: this launch has
# reached its cube, so a drop is retried quietly for ever and the question is never put. So the window is usable, which
# is the only reason this state can be driven at all.
#
# **The face being drawn does not make it clickable**, which is the other half of the fix above: the tab shows the
# cube's last known face and refuses a click on it, because nothing can be sent to a cube nobody can hear. Letting the
# face survive the drop turned this refusal into an assignment until `isDeviceReachable` was split out from it.

BREAK=$(sql "SELECT category_id FROM category WHERE category_name = 'Break';")
open_before=$(sql "SELECT COUNT(*) FROM device_event WHERE finalised != 1;")
# **Both manual faces as they stand, not as they ought to stand.** `05-faces-timing` starts Break by hand, so one of
# them may well be holding it already when this runs -- and a check that asserted "no manual face holds Break" would
# fail on a rotation an earlier script left behind rather than on anything this click did.
faces_before=$(sql "SELECT group_concat(face_id || ':' || category_id, ',') FROM face WHERE face_id IN (13, 14) ORDER BY face_id;")
# **The refusal is drawn, not merely logged.** The rows go dead when a click would do nothing, so this is checked
# before pressing: the row being disabled is the whole of what tells somebody why nothing happens, and it used to be
# invisible. `ax-dump.py` prints `disabled` only when a control is off, so the word appearing on the row is the check.
check_contains "the category rows are drawn dead" "$(element "category-row-$BREAK")" "disabled"

since=$(mark)
press "category-row-$BREAK"
sleep 1.5

# Pressed anyway, to prove the drawing and the behaviour agree. A dead row does not actuate, so there is no log line
# to wait for here -- what is checked is that nothing moved.
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
press_title "Stop Looking"
sleep 2

if ! wait_for "$chosen" "Stop looking chosen;%" 5 >/dev/null; then
    step "the alert did not answer to an AXPress, so asking for a hand"
    if ! action_required \
        "Click **Stop Looking** on the dialog" \
        "The app could not find your TimeFlip, and is asking what to do about it." \
        "Do not click Retry: this script is about what happens after the app gives up."
    then
        fail "the offer was not answered, so nothing below it could be checked"
        finish
        exit $?
    fi
fi

expect_log "choosing it stops the loop for the rest of the launch" "$chosen" "Stop looking chosen;%" 60
check "the device is still this app's device" "1" "$(setting paired paired)"
# **The launch is not turned into its own clock**, which is the half of the old behaviour that was removed. A `mode`
# row saying otherwise would be the switching coming back.
check "and the launch is not turned into its own clock" "0" \
    "$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $chosen AND tag = 'mode' AND message LIKE 'Launch mode:%';")"

# ---------------------------------------------------------------------------- and the click is still refused
#
# The same click as before, in the same state of the table, answered the same way -- which is the point. Giving up on
# the cube settles the reconnect loop and nothing else: this is still a launch with a cube on record, so there is still
# nothing for a click to start.

open_settings
select_tab Faces
since=$(mark)
open_before=$(sql "SELECT COUNT(*) FROM device_event WHERE finalised != 1;")
press "category-row-$BREAK"
sleep 1.5

# The drawing has to agree with the refusal. A live-looking row that does nothing is the worse of the two failures:
# it invites the click rather than explaining why there is nothing to click.
case "$(element "category-row-$BREAK")" in
    "") fail "there is no category row to check" ;;
    *disabled*) pass "the category rows stay dead, the launch still having a cube on record" ;;
    *) fail "the category rows went live after Stop Looking, which is the switching coming back" ;;
esac

check "no clock starts" "0" \
    "$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND message LIKE 'Timing: started%';")"
check "and no segment is opened" "$open_before" \
    "$(sql "SELECT COUNT(*) FROM device_event WHERE finalised != 1;")"

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
    fail "Bluetooth was left off, so what the app does when the cube comes back was not checked"
    finish
    exit $?
fi
# Said to be back on. The scan at the end of this script is what actually proves it, and until that passes the trap
# stays armed -- a person answering a prompt is not evidence, which is this suite's whole first principle.

step "watching for 40s to see whether the app reaches for the cube..."
sleep 40

check "the app does not go back to looking for the cube" "0" \
    "$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $quiet AND message LIKE 'Looking for the cube again%';")"
check "it starts no scan of its own" "0" \
    "$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $quiet AND message LIKE '%Scan started%';")"
check "and reaches for nothing" "0" \
    "$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $quiet AND message LIKE 'Reaching for %';")"
# **The offer does not come back either.** Being asked again would be the app inviting somebody to decide something
# they have already decided.
check "the question is not put again" "0" \
    "$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $quiet AND message LIKE 'Offering manual mode:%';")"
check "so nothing is connected" "0" "$(setting connection connected)"
# **The menu bar says the app's own name and nothing else**, which is what this state actually looks like: a launch
# that follows a cube, with no cube to follow and no licence to start its own clock. A category appearing here would
# mean either the cube crept back in or the app started timing by hand, and both are the failure.
check_contains "and the menu bar shows the app rather than a category" "$(status_item)" "Facet"

# ---------------------------------------------------------------------------- the way back out
#
# **Forgetting the device is half of the way out, and every check below is about that half.** The other half is the
# restart, which is what actually changes the mode: a launch that decided `.device` stays one until it closes, so the
# app is still not going to time anything between here and the end of this section. The restart comes with the pairing
# put back at the foot of the script, which is where the mode is decided again.
#
# It is also what `99-quit` needs, since it cannot wipe a cube this script left unreachable.

open_settings
select_tab Device
since=$(mark)
press device-forget
sleep 1.5

check "forgetting the device gives the pairing up" "0" "$(setting paired paired)"
# **Nothing about the mode is logged here, and that is the app being right.** Forgetting a cube is exactly the kind of
# tidying-up that used to reset the mode along with the pairing -- it was one of three callers that did -- and a launch
# that changed what it was at this point would be the switching coming back through the back door.
#
# The whole `mode` tag is asserted rather than one message, because what must not happen is any mode row at all: the
# only one a launch writes is the line `LaunchMode.decided` writes at startup.
check "and the launch is still what it was, no mode row of any kind" "0" \
    "$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND tag = 'mode';")"
# Still the app's own name: a forget does not hand the clock over any more than the offer did.
check_contains "so the menu bar still shows the app rather than a category" "$(status_item)" "Facet"
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

# ---------------------------------------------------------------------------- putting the cube back
#
# The forget above is a check, and the scan just now was the radio proving itself, so this script ends with nothing
# paired and `57-cube-pause` starts from a cube. The scan is waited out first: pressing Scan while one is running
# stops it, and `pair_a_cube` presses it.

restore_the_pairing

close_settings
finish
