#!/bin/bash
# The app stopping the cube for a reason of its own: a face with nothing on it, and a category that has spent its day.
#
# **Two reasons, one cube, and the same command.** Both put `0x06 0x01` on the wire, so the app logs *why* under the
# `forced` tag and this script reads that rather than `The cube is paused` -- which a user's own click writes too.
#
# **Nothing here can be reached by `swift test`.** The decisions are hermetic and covered there (`ForcedPauseTests`,
# `DailyLimitEnforcementTests`); what is not is whether the command ever leaves the Mac. It did not, for the daily
# limit, for as long as that feature has existed: `DailyLimitWatch` was handed the app's own pause path, so with a
# cube on the other end the limit reached `closeOpenSegment`, was refused on the face, and logged that the row was
# left open. `12-daily-limit` stayed green throughout, because it sits below 50 and runs in manual mode where that
# wiring was the right one. That is the shape of fault this script exists for.
#
# **It runs on the face labelled 627**, which is a physical label on the cube this suite is developed against. Which
# `face_id` the cube reports for it is read back rather than assumed, so the script says what it found and a cube
# labelled differently fails on the face having a category rather than on a number that means nothing.
#
# **A pause is confirmed from `device_event`, not from the log alone.** Measured 2026-08-27 (finding 9 in
# `docs/timeflip2-firmware-observations.md`): a pause files a new history event on the cube, marked paused, and the
# cube announces nothing -- so the app fetches, and the row that arrives is the cube's own account of having stopped.
# Asserting the log alone would prove the app spoke, not that the cube listened.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
# What this script checks when everything passes. See `finish` in lib.sh for what a mismatch means.
EXPECTED_CHECKS=20
start "the app stopping the cube: a face with nothing on it, and a category that has spent its day"

# **No cube check here.** `00-setup` asked once and `50-device-scan` stops the run if the answer was no, so anything
# reaching this line has a cube.

# **The cube `61-lock-without-pause` left connected**, inherited like every device script from `52` on -- see
# `require_a_paired_cube` in lib.sh.
require_a_paired_cube "there is no cube to stop"

LIMIT_MINUTES=5
LIMIT_SECONDS=$(( LIMIT_MINUTES * 60 ))
REMAINING=5

# ---------------------------------------------------------------------------- a cube that can be turned
#
# **Nothing is repaired here, because there is nothing left to repair.** A locked cube silently refuses to change
# face, so every flip below would wait for ever with nothing to detect; a paused one reports the turn but files no
# history for it, and every check here reads `device_event`.
#
# Both used to be asked about and fixed. Neither can happen: `relink_a_cube` takes the lock and the pause off in one
# gesture, so every script from `52` inherits a cube that is unlocked and counting, and `00-setup` says which face it
# is resting on -- which matters more here than anywhere, this being the script that makes a face unassignable on
# purpose.

open_settings
select_tab Faces

# ---------------------------------------------------------------------------- 1. a face with nothing on it
#
# **The face is discovered, not declared.** 627 is printed on the cube; which face the firmware calls it is the
# cube's to say, so the flip is asked for and the answer read out of the app's own row.

base=$(mark)
if ! ask_and_detect \
    "SELECT message FROM debug_log WHERE debug_log_id > $base AND tag = 'face' AND message LIKE 'Face % is up';" \
    "Turn the cube so the face labelled 627 is up" \
    "That face has nothing assigned to it, which is the whole point of this section." \
    "Take as long as you like: this waits, it does not time out."
then
    fail "the cube was never turned to 627, so there is no unassigned face to stop on"
    close_settings
    finish
    exit $?
fi

FACE=$(dsql "SELECT message FROM debug_log WHERE debug_log_id > $base AND tag = 'face' AND message LIKE 'Face % is up' ORDER BY debug_log_id DESC LIMIT 1;" | sed -E 's/Face ([0-9]+) is up/\1/')
if [ -z "$FACE" ]; then
    fail "the cube reported a turn but not which face, so there is nothing to look up"
    close_settings
    finish
    exit 1
fi
step "the face labelled 627 is face $FACE as far as the cube is concerned"

# **Read from `face` at the moment it is needed**, which is also what the app does. `category_id` 0 is the seeded
# Unassigned row, which is a face with nothing on it rather than a face holding a category called Unassigned.
check "face $FACE has no category on it" "0" \
    "$(sql "SELECT category_id FROM face WHERE face_id = $FACE;")"

# **The app's own reason, under its own tag.** `The cube is paused` is written by every pause including the user's;
# this row says the app decided it.
expect_log "so the app stops the cube itself" "$base" "Forced pause: face $FACE has no category%" 30
# And the cube's own account of it, which is the half a log line cannot give.
check "and the cube says it has stopped" "1" \
    "$(wait_sql "1" "SELECT paused FROM device_event WHERE finalised = 0 AND device_face BETWEEN 1 AND 12 ORDER BY device_event_id DESC LIMIT 1;" 30)"

# ---------------------------------------------------------------------------- 2. giving it a category starts it again
#
# **The case that needs a command.** A flip onto a face that has a category is lifted by the firmware with the app
# taking no part (measured 2026-08-12), but nothing physical happens here: the cube sits still and the *table* changes
# underneath it, so only the app can start it.
#
# **Created on the Faces tab, which is where making a category means saying what you are doing now**: it assigns what
# it makes to the face the cube is resting on. That is the whole of "assign 627 to the face", in one control.

NAME=627
assigned=$(mark)
press create-category
sleep 0.5
set_field category-name-field "$NAME"
press save-category
sleep 1.5
CATEGORY=$(dsql "SELECT message FROM debug_log WHERE debug_log_id > $assigned AND message LIKE '%Save new category%' ORDER BY debug_log_id LIMIT 1;" | sed -E 's/.*category_id ([0-9]+).*/\1/')
if [ -z "$CATEGORY" ]; then
    fail "could not create the category 627, so there is nothing to assign"
    close_settings
    finish
    exit 1
fi
step "627 is category_id $CATEGORY"

check "the face the cube is on now holds 627" "$CATEGORY" \
    "$(wait_sql "$CATEGORY" "SELECT category_id FROM face WHERE face_id = $FACE;" 10)"
expect_log "so the app starts the cube again, nothing physical having happened" "$assigned" "Forced pause lifted:%" 30
check "and the cube says it is running" "0" \
    "$(wait_sql "0" "SELECT paused FROM device_event WHERE finalised = 0 AND device_face BETWEEN 1 AND 12 ORDER BY device_event_id DESC LIMIT 1;" 30)"

# ---------------------------------------------------------------------------- 3. a category that has spent its day
#
# The cube goes onto Break first, so the budget below is seeded against a category nothing is currently timing.

BREAK_FACE=$(sql "SELECT f.face_id FROM face f JOIN category c ON c.category_id = f.category_id WHERE c.category_name = 'Break' AND f.face_id BETWEEN 1 AND 12 ORDER BY f.face_id LIMIT 1;")
if [ -z "$BREAK_FACE" ]; then
    fail "no cube face holds Break, so there is nowhere to park the cube while the budget is seeded"
    close_settings
    finish
    exit 1
fi

parked=$(mark)
if ! ask_and_detect \
    "$(on_face_now "$parked" "$BREAK_FACE")" \
    "Turn the cube to the Break face" \
    "That is face $BREAK_FACE. 627 is about to be given a five minute budget, and it must not be spending it yet." \
    "Take as long as you like: this waits, it does not time out."
then
    fail "the cube never reached Break, so 627 would spend its budget during the staging"
    close_settings
    finish
    exit $?
fi

# The limit goes in through the Categories tab, so the value under test is one the app wrote rather than one this
# script reached around it to insert.
select_tab Categories
set_field_focused "category-limit-$CATEGORY" "$LIMIT_MINUTES"
press_return
sleep 1
check "627 is given a ${LIMIT_MINUTES} minute budget" "$LIMIT_MINUTES" \
    "$(wait_sql "$LIMIT_MINUTES" "SELECT daily_limit FROM category WHERE category_id = $CATEGORY;" 10)"

# **Seeded straight into the tables, which every other script here is forbidden from doing.** It is right here for the
# reason `12-daily-limit` gives for the same seed: recording four minutes fifty-five by driving the app would mean
# sitting there for four minutes fifty-five. What goes in is an ordinary finished segment on one of the app's own
# faces and the entry it produced, so the total the app reads is reached the same way any other total is.
#
# **Marked synced**, so the Google sweep has nothing to do with it: a fixture rather than time somebody wants in their
# calendar.
# **What 627 has recorded already, which is never nothing.** Section 2 put the category on the face the cube was
# resting on and the app started the cube again, so every second between that and the flip to Break is against this
# category -- and how many there are depends entirely on how long somebody took to pick the cube up.
#
# **Run 114 (2026-08-27) failed here for exactly that**, expecting 295 and finding 309: fourteen seconds of 627,
# against a check that assumed the seed was all there was. Seeding a fixed amount cannot work when the starting point
# is a person's reaction time, so the seed is the difference and the assertion is the total it adds up to.
#
# Waited for rather than read straight away: the stretch on 627 has to be closed and swept into `time_entry` before it
# can be counted, and reading between those two would seed too much. A blip that never becomes an entry is fine and
# needs no special case -- it contributes nothing, and the arithmetic below is the same.
wait_sql "0" "SELECT COUNT(*) FROM device_event WHERE finalised = 0 AND device_face = $FACE;" 30 >/dev/null
sleep 2
already=$(sql "SELECT CAST(IFNULL(SUM(duration_seconds), 0) AS INTEGER) FROM time_entry WHERE category_id = $CATEGORY;")
already=${already:-0}
step "627 already has ${already}s against it from the stretch it was just timed on"

seeded=$(( LIMIT_SECONDS - REMAINING - already ))
if [ "$seeded" -le 0 ]; then
    fail "627 already has ${already}s of its ${LIMIT_SECONDS}s budget, so there is nothing left to seed -- was the cube left on 627 for five minutes?"
    close_settings
    finish
    exit 1
fi
zone=$(sql "SELECT timezone_id FROM timezone ORDER BY timezone_id LIMIT 1;")
zone=${zone:-0}
started=$(( $(date +%s) - seeded - 60 ))
# Shifted back until the identity is free: `(event_number, start_epoch)` is unique and here both are this one number.
while [ -n "$(sql "SELECT 1 FROM device_event WHERE event_number = $started AND start_epoch = $started;")" ]; do
    started=$(( started - 1 ))
done
ended=$(( started + seeded ))

sql "INSERT INTO device_event (
         event_number, event_type_id, device_face, start_time, timezone_id,
         start_epoch, duration_seconds, paused, finalised, processed
     ) VALUES (
         $started, 1, 13, strftime('%Y-%m-%dT%H:%M:%S', $started, 'unixepoch', 'localtime'), $zone,
         $started, $seeded, 0, 1, 1
     );"
event=$(sql "SELECT device_event_id FROM device_event WHERE start_epoch = $started AND event_number = $started;")
# Read back before anything is built on it: `sql` reports a refused write on stderr and answers nothing on stdout, so
# without this the failure reaches the screen and the script carries on regardless.
if [ -z "$event" ]; then
    fail "the seeded segment would not insert, so 627 has no budget spent and nothing below means anything"
    close_settings
    finish
    exit 1
fi

sql "INSERT INTO time_entry (
         category_id, device_event_id, started_at, start_timezone_id,
         ended_at, end_timezone_id, duration_seconds, synced_to_google_calendar
     ) VALUES (
         $CATEGORY, $event,
         strftime('%Y-%m-%dT%H:%M:%S', $started, 'unixepoch', 'localtime'), $zone,
         strftime('%Y-%m-%dT%H:%M:%S', $ended, 'unixepoch', 'localtime'), $zone,
         $seeded, 1
     );"

check "627 is $(( LIMIT_SECONDS - REMAINING ))s into its ${LIMIT_SECONDS}s budget, so ${REMAINING}s are left" \
    "$(( LIMIT_SECONDS - REMAINING ))" \
    "$(sql "SELECT CAST(IFNULL(SUM(duration_seconds), 0) AS INTEGER) FROM time_entry WHERE category_id = $CATEGORY;")"

close_settings

spending=$(mark)
if ! ask_and_detect \
    "$(on_face_now "$spending" "$FACE")" \
    "Turn the cube back to the face labelled 627" \
    "It has ${REMAINING} seconds of budget left. Put it down and leave it: the clock runs it out by itself." \
    "Take as long as you like: this waits, it does not time out."
then
    fail "the cube never went back to 627, so its budget was never spent"
    finish
    exit $?
fi

step "waiting for 627 to run out of budget (${REMAINING}s of it, plus the fetch that notices)..."
expect_log "the budget runs out and the app stops the cube" "$spending" "Daily limit reached: 627%" 60
check "and the cube says it has stopped" "1" \
    "$(wait_sql "1" "SELECT paused FROM device_event WHERE finalised = 0 AND device_face BETWEEN 1 AND 12 ORDER BY device_event_id DESC LIMIT 1;" 60)"

# ---------------------------------------------------------------------------- 4. flipping back onto a spent category
#
# **What has been spent stays spent for the day**, so coming back to the face is coming back to a category with no
# budget. The flip itself resumes the cube in firmware, which is exactly why the app has to stop it again: without
# this the way round a hard limit would be to turn the cube over and turn it back.

away=$(mark)
if ! ask_and_detect \
    "$(on_face_now "$away" "$BREAK_FACE")" \
    "Turn the cube to the Break face" \
    "Break has no budget set, so the cube is meant to carry on running there." \
    "Take as long as you like: this waits, it does not time out."
then
    fail "the cube never left 627, so there is no flip back to test"
    finish
    exit $?
fi

check "the cube runs on Break, which has no budget to spend" "0" \
    "$(wait_sql "0" "SELECT paused FROM device_event WHERE finalised = 0 AND device_face BETWEEN 1 AND 12 ORDER BY device_event_id DESC LIMIT 1;" 60)"

backagain=$(mark)
if ! ask_and_detect \
    "$(on_face_now "$backagain" "$FACE")" \
    "Turn the cube back to the face labelled 627 one last time" \
    "Its budget is already spent, so the app should stop it again within a second or two of the turn." \
    "Take as long as you like: this waits, it does not time out."
then
    fail "the cube never went back to 627, so the flip onto a spent category was never made"
    finish
    exit $?
fi

expect_log "coming back to a spent category stops the cube again" "$backagain" "Daily limit reached: 627%" 60
check "and the cube says it has stopped" "1" \
    "$(wait_sql "1" "SELECT paused FROM device_event WHERE finalised = 0 AND device_face BETWEEN 1 AND 12 ORDER BY device_event_id DESC LIMIT 1;" 60)"

# ---------------------------------------------------------------------------- 5. and the gestures cannot spend it
#
# **A limit is only as hard as the set of paths that can send `0x06 0x02`**, and two of them were not refusing. Both
# were reported off a real cube on 2026-08-27, after everything above this had been green for a run:
#
# - **A single click on the right half.** Both routers asked the limit through `ManualTimerRules.isClickable`, which
#   answers about the app's own clock, and a cube leaves that `.idle` however busy it is -- so every cube click fell
#   past the one place the limit was consulted. `StatusItemClickRouter` had even documented the exemption, and had
#   been right when it was written: the limit was not enforced against a cube at all until earlier the same day.
# - **A double click.** Unlocking resumes, so lock-then-unlock started the cube whatever the budget said.
#
# **This costs no flips**, which is why it is here rather than in a script of its own: everything above leaves the
# cube sitting on 627 with its budget spent, which is exactly the state both gestures have to refuse.
#
# The cube ends unlocked and stopped, which is what `99-quit` wants and what the limit means.

since=$(mark)
click_right
sleep 3
check_contains "a single click at a spent cube is routed to nothing" \
    "$(dsql "SELECT message FROM debug_log WHERE debug_log_id > $since AND tag = 'click' ORDER BY debug_log_id DESC LIMIT 1;")" \
    "ignore"
check "and no resume went down the wire" "0" \
    "$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND tag = 'command' AND message = 'Sending 06 02';")"

# **Locking is not the limit's business**, so the gesture stays live. Proved rather than assumed, because refusing it
# would be the failure mode on the other side: a cube nobody could lock.
since=$(mark)
double_click_right
expect_log "a double click still locks it, the lock being no concern of the limit" "$since" "The cube is locked" 30

# **And unlocking is never refused either**, which is the half that matters most: it is the one way out of a state
# this app cannot otherwise reach. What must not ride along with it is the resume.
since=$(mark)
double_click_right
expect_log "unlocking still works, so the cube is never stranded shut" "$since" "The cube is unlocked" 30
expect_log "but it is left stopped, and the app says why" "$since" "The cube is left stopped:%daily limit" 30
check "so still no resume down the wire" "0" \
    "$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND tag = 'command' AND message = 'Sending 06 02';")"
check "and the cube is still stopped, which is what a spent budget means" "1" \
    "$(wait_sql "1" "SELECT paused FROM device_event WHERE finalised = 0 AND device_face BETWEEN 1 AND 12 ORDER BY device_event_id DESC LIMIT 1;" 30)"

finish
