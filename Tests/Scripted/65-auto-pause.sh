#!/bin/bash
# The cube's auto-pause delay, stepped on the Device tab, sent as 0x05, read back with 0x10, and only then written down.
#
# **What needs a real cube is the sequence, not the bytes.** Which bytes `0x05` carries and what a `0x10` answer has to
# say to count as a confirmation are `DeviceCommandRules`, pinned in `swift test` with no radio in sight. What cannot be
# tested there is the order the first rule in `CLAUDE.md` is about: the cube is told, the cube is asked, and the table
# is written only once the cube's own answer agrees. An app that wrote the row beside the send would pass every unit
# test in the repo and would be recording its own wish as the cube's state.
#
# **This one is confirmed rather than acknowledged, which is where it differs from `63`.** The LED pair have no read
# command in the spec at all, so what the app calls success there is the cube taking the bytes. Auto-pause has `0x10`,
# which reports the delay the cube is set to, so the row this script waits for is the cube saying what it is on rather
# than the app saying what it sent.
#
# **A cube is needed to change this setting at all**, which is worth knowing before reading a failure here: with
# nothing connected the command cannot go, so the field goes back and the table keeps what it had. The same is true of
# every other writing row on the tab.
#
# **The last section is the only place in the suite where the delay is watched doing something.** Everything before it
# is about the command; that one sets a minute, has the cube turned, and waits for the cube to stop itself. It asks for
# a pair of hands twice over -- a turn, and then a minute of leaving it alone -- and it says so on screen before it
# starts waiting.
#
# **Runs after `64`, which leaves a launched app logged in to the cube, and before the wipe in `99`.**
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
# What this script checks when everything passes. See `finish` in lib.sh for what a mismatch means.
EXPECTED_CHECKS=18
start "the cube auto-pause delay, sent to the cube, read back, and then written down"

# **No cube check here.** `00-setup` asked once and `50-device-scan` stops the run if the answer was no, so anything
# reaching this line has a cube.

# ---------------------------------------------------------------------------- arranging, not checking
#
# **The row is put back to its seed before anything opens.** Every pattern below names the number it expects, and a run
# inheriting a delay somebody left at 5 would step to 6 and match nothing.
#
# **Written with the window shut**, which is what makes it safe. An open Settings window is the source of truth for what
# it shows (`CLAUDE.md`), so writing underneath one would be the two-answers problem this script exists to check for.

# **The two faces this script may use**, as the physical labels `55` and `57` have them. Named here because the
# arranging below is about them as well as the section that turns the cube onto one.
MEETING_FACE=2
BREAK_FACE=8

close_settings
sql "UPDATE setting
        SET setting_value = json_set(setting_value, '\$.minutes', 0)
      WHERE setting_name = 'auto_pause_minutes';"
step "the auto-pause row starts at 0, which is off"

# **And no daily limit on any face the cube can rest on.** A category over its budget is stopped by the app
# (`DailyLimitWatch`), and a cube stopped that way is indistinguishable, in `device_event`, from one that stopped
# itself on the delay -- so while this script runs, no budget is in a position to make that reading.
#
# **Every cube face, not just the two turned to**, and 627 is the reason. `62-forced-pause` leaves the cube resting
# there on a category whose limit it has just spent, so the resume in `free_the_cube` below would be undone by the
# watch a second later and the relink would fail on a cube it could not get counting. Clearing it is safe by then:
# `62` has finished asserting everything it had to say about that budget, and the rows it recorded are untouched --
# this moves a setting, not a result.
sql "UPDATE category SET daily_limit = 0
      WHERE category_id IN (SELECT category_id FROM face WHERE face_id BETWEEN 1 AND 12);"
step "no face the cube can rest on carries a budget, so nothing but the delay can stop it"

require_a_paired_cube "there is no cube to send an auto-pause delay to"

# **Relinked rather than inherited, which is what the last section needs and nothing above it can promise.** The app
# pauses *and locks* the cube on its way out, always and both (`QuitSequence`), and only `free_the_cube` takes that
# off again -- so a run that reaches here after any uncovered quit meets a cube frozen on one face, which is exactly
# the state in which asking somebody to turn it is asking the impossible. Measured on a real run, 2026-08-29: the
# script sat waiting for a turn on a locked cube.
#
# `relink_a_cube` quits, relaunches, waits for the login and then takes the lock and the pause off in one gesture,
# which is how `55`, `57` and `60` all start. It is also why the budgets above are cleared first: the resume it waits
# for would be undone by the daily-limit watch on the face `62` leaves the cube sitting on.
if ! relink_a_cube; then
    fail "the app did not come back to the cube unlocked and counting, so there is nothing to time a delay against"
    finish
    exit 1
fi

open_settings
select_tab Device

# **A precondition rather than a second copy of the claim.** That the field follows `isCubeConnected` is `56`'s, which
# reads it live and then dead either side of one drop; what this needs to know is only that the arrows below can be
# pressed at all, since a refusal from a dead control would look exactly like a cube refusing a command.
check "the Auto-pause field is live, so the presses below mean something" "0" \
    "$(tree | grep -cE "id=device-auto-pause[[:space:]].*disabled" || true)"

# ---------------------------------------------------------------------------- turning it on
#
# **The arrow rather than the field**, as `08-app-settings`, `59-double-tap` and `63` do: the arrows are what a person
# uses, and what the field ends up holding is read back out of the table anyway.
#
# **0x05 0x00 0x01 is one minute, high byte then low.** The order is the archive's and the way round `0x10` answers, so
# a transposition would show up here as 256 minutes on the wire.

since=$(mark)
press device-auto-pause-up
expect_log "stepping Auto-pause sends 0x05 to the cube" "$since" \
    "command withResponse: 05 00 01"
expect_log "and the app says what it sent" "$since" \
    "Auto-pause: sending 1m"
expect_log "and asks the cube whether it took, rather than believing the write" "$since" \
    "Asking whether it took: 10" 30
expect_log "and the cube's own answer is what confirms it" "$since" \
    "The cube confirms it took: auto-pause 1m" 30
expect_log "and only then is the row written" "$since" \
    "Auto-pause: the table now holds 1m" 30

# **The order of those last two, read as row ids rather than trusted from the order they were waited for.**
# `expect_log` polls, so two patterns can both match rows that arrived the other way round -- and the whole of what this
# script adds over `swift test` is that the table follows the cube rather than accompanying it.
confirmed=$(dsql "SELECT MIN(debug_log_id) FROM debug_log WHERE debug_log_id > $since AND message LIKE 'The cube confirms it took: auto-pause 1m';")
stored=$(dsql "SELECT MIN(debug_log_id) FROM debug_log WHERE debug_log_id > $since AND message LIKE 'Auto-pause: the table now holds 1m';")
if [ -n "$confirmed" ] && [ -n "$stored" ] && [ "$stored" -gt "$confirmed" ]; then
    pass "the table was written after the cube confirmed it, not beside it"
else
    fail "the confirmation was row ${confirmed:-none} and the write row ${stored:-none}"
fi

wait_for_value "SELECT json_extract(setting_value, '\$.minutes') FROM setting WHERE setting_name = 'auto_pause_minutes';" "1" 10
check "the table holds the stepped delay" "1" "$(setting auto_pause_minutes minutes)"

# ---------------------------------------------------------------------------- turning it off again
#
# **0 is the vendor protocol's own way of disabling it**, not an absence: `0x05 0x00 0x00` is a command like any other
# and the cube answers `0x10` with 0 minutes. So this is a real round trip rather than the app declining to send, and
# it puts the seeded row back on the way past.

since=$(mark)
press device-auto-pause-down
expect_log "stepping it back to zero sends the delay off" "$since" \
    "command withResponse: 05 00 00"
expect_log "and the cube confirms it is off" "$since" \
    "The cube confirms it took: auto-pause 0m" 30
wait_for_value "SELECT json_extract(setting_value, '\$.minutes') FROM setting WHERE setting_name = 'auto_pause_minutes';" "0" 10
check "and the row is back to 0, which is off" "0" "$(setting auto_pause_minutes minutes)"

# ---------------------------------------------------------------------------- the floor
#
# **0 is the bottom of the field's range** (`DeviceCommandRules.autoPauseRange`), which the command clamps to as well.
# A step that cannot move reports nothing, so what is checked is that nothing at all went out: a field that sent its
# floor again on every press would be a command and a read-back per click for no change.

since=$(mark)
press device-auto-pause-down
sleep 2
check "stepping below zero sends nothing" "0" \
    "$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND message LIKE 'Auto-pause: sending%';")"
check "and leaves the row where it was" "0" "$(setting auto_pause_minutes minutes)"

# ---------------------------------------------------------------------------- and the cube acts on it
#
# **The only check in the suite that watches the delay do anything.** Everything above proves the cube took `0x05` and
# reports the number back through `0x10`; a firmware that stored the value and ignored it would pass every one of them.
# So this sets a minute, has the cube turned so the countdown starts from a known moment, and waits for it to stop.
#
# **Turned rather than left where it is**, because the vendor's own note is that the delay timer restarts on every face
# change. A cube that has been still for ten minutes says nothing about when the minute began.
#
# **Three faces are used in this suite and only three**: Meeting, Break, and the one labelled 627. So this reads which
# of them the cube is lying on and asks for one of the others, the way `55-device-face` and `57-cube-pause` pick their
# target.
#
# **627 is where the cube is lying, so it is the one face that cannot be the target**: a turn onto the face it is
# already on gives `ask_and_detect` nothing to detect. Its spent budget could have been cleared the way the two above
# were, and that would remove the app's reason to stop a cube resting there -- but it would still be the wrong face to
# ask for, for the reason a turn is asked for at all.
#
# **The cube is unlocked and counting when this starts**, which the relink at the top of the script is for: locked, it
# could not be turned at all, and stopped, the wait below would match on a cube that had been still since before the
# delay was set. The check after the turn is what says the clock this delay has to stop was actually going.

since=$(mark)
press device-auto-pause-up
expect_log "the delay goes back on for the cube to act on" "$since" \
    "The cube confirms it took: auto-pause 1m" 30

# **The face it is not already on**, which is `55-device-face`'s own correction to itself: asking for the one it is
# resting on leaves the poll with nothing to detect and the run sits there while somebody stares at a cube that is
# already right. The name is read from the table, so no check here agrees with a string spelled out in this script.
resting=$(dsql "SELECT message FROM debug_log WHERE tag = 'face' AND message LIKE 'Face % is up' ORDER BY debug_log_id DESC LIMIT 1;" | sed -n 's/^Face \([0-9]*\) is up$/\1/p')
if [ "${resting:-0}" = "$BREAK_FACE" ]; then turn_to=$MEETING_FACE; else turn_to=$BREAK_FACE; fi
turn_name=$(sql "SELECT category_name FROM category WHERE category_id = (SELECT category_id FROM face WHERE face_id = $turn_to);")
step "the cube is resting on face ${resting:-unknown}, so it is being sent to face $turn_to (${turn_name:-unassigned})"

turned=$(mark)
if ask_and_detect \
    "SELECT message FROM debug_log WHERE debug_log_id > $turned AND tag = 'face' AND message = 'Face $turn_to is up';" \
    "Turn the cube so the $turn_name face is up, then leave it alone" \
    "That is face $turn_to. It has a category on it, which matters: an empty face stops the cube by itself." \
    "If it is already there, turn it away and back, so the app sees the change." \
    "THEN DO NOT TOUCH IT. This script waits about a minute for the cube to stop itself," \
    "and every turn starts that minute over."
then
    # **The clock has to be going before a delay can stop it.** The relink handed this section a counting cube and the
    # turn keeps it counting, but neither is worth assuming: without this the wait below would pass on a cube that had
    # been stopped since before the delay was set, which is the whole failure this section exists to be better than.
    check "the cube is counting on the new face, so there is a running clock for the delay to stop" "0" \
        "$(wait_sql "0" "SELECT paused FROM device_event WHERE finalised = 0 AND device_face BETWEEN 1 AND 12 ORDER BY device_event_id DESC LIMIT 1;" 30)"

    # **A minute for the delay, plus the history timer coming round to notice.** Nothing announces an auto-pause: the
    # cube files the stretch with `Side + 128` and the app finds it on its next fetch, which is the seeded interval.
    step "the cube was turned, so now waiting up to 150s: a minute for the cube to stop itself, then the history timer to see it..."
    if wait_for_value "SELECT paused FROM device_event WHERE finalised = 0 AND device_face BETWEEN 1 AND 12 ORDER BY device_event_id DESC LIMIT 1;" "1" 150; then
        pass "the cube stopped itself once the minute was up, which is the delay actually doing something"
    else
        fail "the cube never stopped itself, so the delay it confirmed had no effect on the hardware"
    fi
    # **The check that makes the one above mean anything.** Three things in this app pause a cube -- a face with no
    # category, a spent daily limit, and the menu bar -- and all of them say so on their way past. Silence here is what
    # says the cube did it on its own.
    check "and nothing in the app asked it to" "0" \
        "$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $turned AND message = 'The cube is paused';")"
else
    fail "nobody was there to turn the cube, so it was never started for the delay to stop"
    fail "and so it was never watched stopping itself"
    fail "and nothing could be said about whether the app would have been the one to stop it"
fi

# ---------------------------------------------------------------------------- putting the delay back
#
# **The delay off, and the cube left where the delay put it.** Turning it off is what matters: it is this script's own
# setting, and a minute left on it would stop the cube again under whatever runs next. The cube itself stays stopped,
# which is what `62` handed this range and what `63` and `64` passed along, and `99-quit` wipes it regardless.
#
# **Not resumed from the menu bar**, though it easily could be: a right click toggles, so it would have to read the
# record to know which way it was going, and a click sent on a wrong reading would hand the wipe a cube that had
# started counting again for no reason anybody could see afterwards.

since=$(mark)
press device-auto-pause-down
expect_log "the delay goes off again, so nothing stops the cube after this" "$since" \
    "The cube confirms it took: auto-pause 0m" 30

close_settings
finish
