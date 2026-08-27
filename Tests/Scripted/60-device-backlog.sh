#!/bin/bash
# A cube that goes out of range while it is timing, is turned while nobody can hear it, and comes back.
#
# **The whole of what this is about is that the app does not guess.** The link goes, and the app keeps showing the
# category the cube was last on, in yellow, with the figure still counting -- because the cube is still timing whether
# this Mac can hear it or not, and the number on screen is worked out from the open row and this machine's clock. What
# it does *not* do is write any of that down. `device_event.duration_seconds` is the cube's own measurement and
# nothing else, so the row stands still for the whole outage, however long it is, and however far the figure above it
# has moved. An app that grew the row from the wall clock would be overwriting a measurement with a guess, and it
# would look right until the cube came back and disagreed.
#
# Then the link comes back, the app asks for the history as the first thing it does, and the cube says what actually
# happened: the stretch on the first face, measured by the cube, right through the outage; and the flip, as its own
# segment, with its own event number. Both arrive as rows for the first time. **Every record of that period comes from
# the device**, which is the claim this script exists to make.
#
# **Migrated from `Archive/Tests/Interactive/01i-history-refresh-checklist.md`, Scenario B**, which is the only place
# the previous suite tested this. Massaged rather than copied: the shape is its shape, and three things it recorded
# are kept because they cost a real run to learn.
#
#   1. **The flip cannot be detected, so it is the one step that asks.** Nothing is logged while disconnected, no data
#      flows, and there is no side effect to poll for until the reconnect -- so `ask_and_detect` cannot be used here
#      the way `55-device-face` uses it for a flip in front of a live link.
#   2. **A gap in the event numbers can be legitimate.** A pass over a face for less than `blip_time` is merged into
#      the surrounding segment by the cube's own filter, so this asks for the flip it named and checks that segment
#      rather than counting how many arrived.
#   3. Its own timing note is *not* kept, and that is a real difference rather than an oversight: the archive measured
#      3.5 to 4 minutes between the radio going off and the app recording the drop. This app notices in seconds --
#      `56-manual-mode` waits 30 for the same row and passes -- because the radio powering off reaches
#      `centralManagerDidUpdateState` directly. The timeouts below are generous, not four minutes long.
#
# **Runs after `59`, which leaves a launched app paired and logged in to its cube**, and before the wipe in `99`. It
# needs the radio, so it sits above 50 with everything else that does.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
# What this script checks when everything passes. See `finish` in lib.sh for what a mismatch means.
EXPECTED_CHECKS=21
start "a cube out of range: what the app shows, what it refuses to write, and what the cube backfills"

# **No cube check here.** `00-setup` asked once and `50-device-scan` stops the run if the answer was no, so anything
# reaching this line has a cube: every script between them needs one, and none of them runs after 50 has failed.

# **The radio has to be back on when this script ends**, whichever way it ends. See `watch_bluetooth` in lib.sh:
# `99-quit` wipes the cube so this run's timings cannot reach production, and it cannot do that with the radio off.
watch_bluetooth

# Whether the app believes the cube is locked, read off the menu bar rather than out of the log.
#
# **A live answer, which the log cannot give here.** `55-device-face` reads the newest `The cube is ...ocked and ...`
# row and can, because it takes its mark before pairing and a fresh link always writes one. Nothing in this script
# makes the cube speak, so the newest such row could be from any earlier script in the run -- and a stale "is locked"
# would send the repair below to unlock a cube that is already unlocked, then fail the script on the same stale row.
# The badge is what the app is drawing at this instant, spelled out for a screen reader (`StatusItemTitle.spoken`).
cube_is_locked() {
    case "$(status_item)" in
        *"device locked"*) return 0 ;;
        *) return 1 ;;
    esac
}

# Whether the cube is stopped, as the app's own record has it -- the source `CubeLock.togglePause` takes its direction
# from, so it is the one to ask before sending a click meant to go a particular way.
open_paused() {
    sql "SELECT paused FROM device_event WHERE finalised = 0 ORDER BY start_epoch DESC, device_event_id DESC LIMIT 1;"
}

# The cube's own open row: the stretch it is timing right now. Its faces only, because a manual segment carries the
# epoch as its event number and is very often the newest open row of any kind.
open_cube_row() {
    sql "SELECT device_event_id FROM device_event WHERE finalised = 0 AND device_face BETWEEN 1 AND 12 ORDER BY device_event_id DESC LIMIT 1;"
}

column_of() {
    sql "SELECT $1 FROM device_event WHERE device_event_id = $2;"
}

# ---------------------------------------------------------------------------- a cube that can be turned
#
# **All of this is repair, and none of it is a check.** Whether the cube arrived locked or paused is not this script's
# subject, and counting it would make `EXPECTED_CHECKS` a property of the state the hardware was left in rather than of
# the script (`57-cube-pause` records the run that was refused for exactly that). Each repair is followed by a guard
# that fails the script outright if it did not take, which is the check that was ever worth having.
#
# **Both have to happen before the radio goes off**, which is the ordering that matters here and nowhere else: the app
# unlocks and resumes a cube by sending it a command, and there is no link to send one over once this script has taken
# it away. A cube left locked would silently refuse the flip below, and a paused one would record nothing to backfill.

# **No Settings window anywhere in this script.** Everything it reads is the menu bar and the two databases, and the
# window would only be one more thing on screen while the radio goes off.

if cube_is_locked; then
    unlocking=$(mark)
    click_left
    sleep 0.8
    press toggle-cube-lock
    if wait_for "$unlocking" "The cube is unlocked" 20 >/dev/null; then
        grey "  the cube arrived locked, and was unlocked so it can be turned below"
    fi
    # The badge is drawn on the item's own tick, so the guard below is given a tick to see the unlock in. Without it
    # a repair that worked could still be read as a cube that would not unlock.
    sleep 1.5
fi

if cube_is_locked; then
    fail "the cube is still locked, and a locked cube silently refuses to change face"
    finish
    exit 1
fi

if [ "$(open_paused)" = "1" ]; then
    resuming=$(mark)
    click_right
    sleep 1.5
    if wait_for "$resuming" "The cube is running" 20 >/dev/null; then
        grey "  the cube arrived paused, and was started again so there is something to backfill"
    fi
    # **The row lands after the log line, not with it.** A resume sends `0x06` and then asks for history, and it is
    # the fetch that rewrites `paused` -- so the guard below is polled onto rather than read once. Its own timeout is
    # not checked: the guard is what reports a resume that did not take, and reporting it twice would be one failure
    # wearing two descriptions.
    wait_for_value "SELECT paused FROM device_event WHERE finalised = 0 ORDER BY start_epoch DESC, device_event_id DESC LIMIT 1;" "0" 30
fi

if [ "$(open_paused)" = "1" ]; then
    fail "the cube is still paused, so it would record nothing while it is out of range"
    finish
    exit 1
fi

# **The two seeded faces, read from the table rather than written down here.** Which category a face holds is `face`'s
# answer, and a check comparing the screen against a name spelled out in this script would be agreeing with itself.
MEETING_FACE=2
BREAK_FACE=8
name_on_face() {
    sql "SELECT category_name FROM category WHERE category_id = (SELECT category_id FROM face WHERE face_id = $1);"
}
meeting=$(name_on_face $MEETING_FACE)
break_name=$(name_on_face $BREAK_FACE)

if [ -z "$meeting" ] || [ -z "$break_name" ]; then
    fail "one of the two seeded faces holds no category, so there would be no name to keep showing"
    finish
    exit 1
fi

# Face A is wherever it is resting, so long as that is one of the two; face B is the other. A cube found on some third
# face is turned onto one first -- detected rather than confirmed, there being a live link at this point to detect it
# over.
resting=$(sql "SELECT device_face FROM device_event WHERE device_face BETWEEN 1 AND 12 ORDER BY device_event_id DESC LIMIT 1;")
if [ "${resting:-0}" != "$MEETING_FACE" ] && [ "${resting:-0}" != "$BREAK_FACE" ]; then
    settling=$(mark)
    if ! ask_and_detect \
        "SELECT message FROM debug_log WHERE debug_log_id > $settling AND tag = 'face' AND message = 'Face $MEETING_FACE is up';" \
        "Turn the cube so the $meeting face is up" \
        "That is face $MEETING_FACE. It is resting on face ${resting:-none}, which holds no category to follow." \
        "This is the starting position, not the turn this script is about -- that one comes later."
    then
        fail "the cube was left on a face with no category, so there was nothing to follow out of range"
        finish
        exit 1
    fi
    resting=$MEETING_FACE
fi

if [ "$resting" = "$BREAK_FACE" ]; then
    FACE_A=$BREAK_FACE;   NAME_A="$break_name"
    FACE_B=$MEETING_FACE; NAME_B="$meeting"
else
    FACE_A=$MEETING_FACE; NAME_A="$meeting"
    FACE_B=$BREAK_FACE;   NAME_B="$break_name"
fi
grey "  the cube is on face $FACE_A ($NAME_A), and will be turned to face $FACE_B ($NAME_B) out of range"

# **The figure has to be able to move in the seconds this watches**, or the quiet window below proves nothing about it.
if [ "$(sql "SELECT json_extract(setting_value, '\$.enabled') FROM setting WHERE setting_name = 'display_seconds';")" != "1" ]; then
    fail "display_seconds is off, so the figure moves once a minute and a short window cannot show it moving"
    finish
    exit 1
fi

INTERVAL=$(sql "SELECT json_extract(setting_value, '\$.seconds') FROM setting WHERE setting_name = 'fetch_history_interval_seconds';")
INTERVAL=${INTERVAL:-10}

check "the app can reach its cube" "1" "$(setting connection connected)"

ROW_A=$(open_cube_row)
if [ -n "$ROW_A" ]; then
    pass "the cube is timing $NAME_A (device_event id $ROW_A, event $(column_of event_number "$ROW_A"))"
else
    fail "the cube has no open segment, so there is nothing for it to go on timing out of range"
    finish
    exit 1
fi

N_A=$(column_of event_number "$ROW_A")
DURATION_BEFORE=$(column_of duration_seconds "$ROW_A")
ROWS_BEFORE=$(sql "SELECT COUNT(*) FROM device_event;")

expect_colours "and the menu bar draws it green, a cube being what is behind the figure" \
    "name green, glyph label, figure green"

# ---------------------------------------------------------------------------- the link goes
#
# **Turned off rather than walked away from**, because a scripted run has to be able to do this again tomorrow. What
# the app sees is the same either way: `centralManagerDidUpdateState` reports a radio that is no longer powered on,
# and every peripheral goes with it.

dropped=$(mark)
if ! action_required \
    "Turn Bluetooth OFF on this Mac" \
    "The menu bar's Bluetooth control, or System Settings -> Bluetooth." \
    "This is the only way to put a paired cube out of reach without carrying it away." \
    "Leave the cube alone for now -- the turn comes once the app has noticed the drop."
then
    fail "Bluetooth was not turned off, so the cube never went out of reach"
    finish
    exit $?
fi
# From here the trap owns getting it back on, however this script ends.
BLUETOOTH_IS_OFF=1

expect_log "the app notices the cube has gone" "$dropped" "The cube went away%" 60
check "and records that it can no longer reach it" "0" \
    "$(wait_sql "0" "SELECT json_extract(setting_value, '\$.connected') FROM setting WHERE setting_name = 'connection';" 30)"

# ---------------------------------------------------------------------------- fat, dumb and happy
#
# The state this script is named for. The app has no cube and knows it, and goes on drawing the last thing the cube
# said -- which is still a true account of what the cube is doing, it has simply stopped being confirmable. Yellow is
# the whole of how that is said on screen.

check_contains "the menu bar goes on naming $NAME_A, which is what the cube last said" \
    "$(status_item)" "$NAME_A"
expect_colours "and the line turns yellow, nothing about it being confirmable any more" \
    "name yellow, glyph label, figure yellow" 30

# **One window, watched long enough for the history timer to fire in it.** Everything below is about the same stretch
# of time: the figure moving, the timer firing, nothing being fetched, and the row standing still.
quiet=$(mark)
menu_before=$(status_item)
row_duration_before=$(column_of duration_seconds "$ROW_A")
grey "  watching for $((INTERVAL + 6))s, which is long enough for the history timer to come round..."
sleep $((INTERVAL + 6))
menu_after=$(status_item)
row_duration_after=$(column_of duration_seconds "$ROW_A")

# **The figure is worked out, not stored**, which is why it moves while the row it is drawn from does not: it is
# `time_entry` plus the open segment measured from its own `start_epoch` against this machine's clock. The cube goes
# on timing whether this Mac can hear it or not, so freezing the figure would be showing a number the reconnect is
# about to disagree with.
if [ "$menu_before" != "$menu_after" ]; then
    pass "the figure carries on counting while the cube is out of reach"
else
    fail "the figure stood still ($menu_after), so the app stopped following a cube that has not stopped timing"
fi

expect_log "the history timer goes on firing, there being an open segment to follow" "$quiet" "History timer fired%" 30
# **Fired, and asked nobody.** The tick does two things and only one of them applies here: it refreshes the app's own
# open segments, and it asks the cube for history *if there is a cube on the other end* (`main.swift`). With none, the
# ingestor is never called at all -- so the absence of this row is the app declining to invent an answer.
check "but nothing is fetched, there being nothing to ask" "0" \
    "$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $quiet AND message LIKE 'Fetching history%';")"
# **The row is the cube's measurement and nothing else.** `refreshOpenSegment` writes only to the app's own faces
# (13 and 14), so a cube's row cannot be grown from this machine's clock however long the outage runs.
check "and the cube's own row is left exactly where it was" "$row_duration_before" "$row_duration_after"

# ---------------------------------------------------------------------------- the turn nobody can see
#
# **The one step that asks rather than detects**, and the archive learned it the same way: nothing is logged while
# disconnected, no data flows, and there is no side effect to poll for until the reconnect. A `ask_and_detect` here
# would wait for ever on a row that cannot be written.

if ! action_required \
    "Turn the cube so the $NAME_B face is up" \
    "That is face $FACE_B. The Mac still has Bluetooth off, which is the point." \
    "The cube records this itself. Nothing will appear on screen, and nothing should." \
    "Leave it on that face -- it is what the app has to find when the link comes back."
then
    fail "the cube was not turned, so there is no backlog for the reconnect to bring in"
    finish
    exit $?
fi

# **Nothing reached the table**, which is the other half of the claim: the app cannot know about a turn it could not
# hear, and an app that had written anything here would have written a guess.
check "nothing reached device_event while the cube was out of range" "$ROWS_BEFORE" \
    "$(sql "SELECT COUNT(*) FROM device_event;")"

# ---------------------------------------------------------------------------- and it comes back
#
# The app reaches for its own cube on a backoff (`DeviceReconnector`), so nothing needs pressing: the radio coming
# back is enough. The first thing a fresh link does is ask for the history, which is what brings the outage in.

back=$(mark)
if ! action_required \
    "Turn Bluetooth back ON" \
    "The app reaches for its own cube by itself, so there is nothing to press." \
    "Everything below is what the cube says happened while nobody could hear it."
then
    fail "Bluetooth was left off, so the backlog was never brought in"
    finish
    exit $?
fi

check "the app reaches its cube again" "1" \
    "$(wait_sql "1" "SELECT json_extract(setting_value, '\$.connected') FROM setting WHERE setting_name = 'connection';" 120)"
# Proven by the app, not by somebody saying so, which is this suite's first principle -- so the trap can stand down.
BLUETOOTH_IS_OFF=0

expect_log "and asks for the history as the first thing it does" "$back" "Fetching history (the link came up)%" 120
expect_log "the fetch comes back" "$back" "History fetch done (the link came up):%" 60

# ---------------------------------------------------------------------------- what the cube says happened
#
# **Every one of these rows is the cube's own account.** The stretch on the first face was measured by the cube right
# through the outage; the turn arrived as its own segment with its own event number. Neither existed in this table
# until the link came back.

# `wait_sql` rather than `wait_for_value`: this one answers with what it last saw, so a failure says what the row
# actually held instead of an empty string.
check "the stretch on $NAME_A is closed off" "1" \
    "$(wait_sql "1" "SELECT finalised FROM device_event WHERE device_event_id = $ROW_A;" 60)"

DURATION_AFTER=$(column_of duration_seconds "$ROW_A")
# Compared with `awk`, the column being a real number: the cube reports fractions of a second and `[ -gt ]` is integer
# arithmetic, which would refuse the value rather than compare it.
if awk "BEGIN{exit !(${DURATION_AFTER:-0} > ${DURATION_BEFORE:-0})}"; then
    pass "and its duration came from the cube, covering the time nobody could see (${DURATION_BEFORE}s -> ${DURATION_AFTER}s)"
else
    fail "the stretch on $NAME_A did not grow (${DURATION_BEFORE}s -> ${DURATION_AFTER}s), so the outage was never backfilled"
fi

# **A segment of its own, above the event number the outage started at.** Asked for by event number rather than by
# counting rows: a pass over a third face for less than `blip_time` is merged by the cube's own filter, so how many
# segments arrive is the cube's business and not this script's claim.
# Waited on as a yes/no rather than as an id, because a row that has not arrived yet answers with an empty string and
# an empty string is what a broken query answers with too. Ingestion lands a moment after the fetch comes back, so
# this is polled rather than read once.
arrived=$(wait_sql "yes" \
    "SELECT CASE WHEN COUNT(*) > 0 THEN 'yes' ELSE 'no' END FROM device_event WHERE device_face = $FACE_B AND event_number > ${N_A:-0};" 60)
NEW_B=""
[ "$arrived" = "yes" ] && NEW_B=$(sql "SELECT device_event_id FROM device_event WHERE device_face = $FACE_B AND event_number > ${N_A:-0} ORDER BY device_event_id DESC LIMIT 1;")
if [ -n "$NEW_B" ]; then
    pass "the turn arrived as its own segment on $NAME_B (id $NEW_B, event $(column_of event_number "$NEW_B"))"
else
    fail "no segment for face $FACE_B above event ${N_A:-0}, so the turn nobody could see never reached the table"
fi

check "and it is the open one, the cube still being on that face" "0" "$(column_of finalised "${NEW_B:-0}")"

# The two surfaces, which is where all of this is actually for. The category on show is the one the cube is on now,
# and the colour says the reading behind it is live again.
check_contains "the menu bar names $NAME_B now" "$(status_item)" "$NAME_B"
expect_colours "and the line is green again, the reading being confirmable once more" \
    "name green, glyph label, figure green" 30

finish
