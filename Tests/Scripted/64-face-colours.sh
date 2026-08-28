#!/bin/bash
# The cube lit in the colours its faces are assigned: `0x11`, twelve of them when a cube connects, and one when an
# edit changes what a face should show.
#
# **What needs a real cube is the timing, and it is the whole reason this script exists.** Which bytes `0x11` carries
# and how a category's colour scales into them is `FaceColourRules`, pinned in `swift test`; that twelve go one after
# another rather than at once is `FaceColourSync`, pinned there too against a pretend radio. What no hermetic test can
# see is *when* the first one is allowed to leave, and that is the thing that was wrong first: `onCubeReady` fires
# several round trips before the login has finished its own questions, and the `0x17` read it has outstanding does not
# set `isCommandInFlight` -- so a colour command hung off it is written over the login rather than refused. The check
# below reads the two rows and compares their ids.
#
# **There is no read-back for `0x11` at all.** The vendor spec defines none, so the app can only ever say the cube
# acknowledged the write. That is why every check here reads the `ble-tx` row -- what actually went on the wire -- and
# not only the app's account of having sent it.
#
# **This cube asks for its colours on every single connect**, measured over 26 of them on 2026-08-28: the systemState
# read is answered `02 02 00 00` about 480ms before the login settles, one per connect and never as a notification.
# So the request always arrives while the login is still talking, and is answered by the send that follows rather than
# by a run of its own. Twelve writes, not twenty-four, and the row says which case it met.
#
# **One edit path is exercised and there are three.** A face taking a category, a category being recoloured and a
# category being retired all reach `FaceColourSync.send(faces:because:)` with a different reason string; recolouring
# is the one that needs no cube-turning and takes nothing off a face for good, so it is the one driven here. What it
# proves for all three is that the path reaches the wire.
#
# **Runs after `63`, which leaves a launched app logged in to the cube, and before the wipe in `99`.**
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
# What this script checks when everything passes. See `finish` in lib.sh for what a mismatch means.
EXPECTED_CHECKS=12
start "the cube lit in its faces colours: twelve on connecting, and one when an edit changes a face"

# **No cube check here.** `00-setup` asked once and `50-device-scan` stops the run if the answer was no, so anything
# reaching this line has a cube.

require_a_paired_cube "there is no cube to light"

# ---------------------------------------------------------------------------- a face wearing a known colour
#
# **Discovered, not declared.** Which faces hold which categories is what the seeded database and every script above
# left behind, so the face is asked for rather than assumed -- and a run where no face holds a category at all fails
# here saying so, rather than further down on a colour that was never going to be sent.

FACE=$(sql "SELECT f.face_id FROM face f JOIN category c ON c.category_id = f.category_id
             WHERE f.face_id BETWEEN 1 AND 12 AND f.category_id >= 1 ORDER BY f.face_id LIMIT 1;")
if [ -z "$FACE" ]; then
    fail "no face holds a category, so there is no colour for this script to follow"
    finish
    exit $?
fi
CATEGORY=$(sql "SELECT category_id FROM face WHERE face_id = $FACE;")
NAME=$(sql "SELECT category_name FROM category WHERE category_id = $CATEGORY;")
WAS=$(sql "SELECT colour_id FROM category WHERE category_id = $CATEGORY;")
step "face $FACE holds $NAME (category_id $CATEGORY), whose colour is colour_id $WAS"

# The palette's own hex for the colour about to be picked, read from the table rather than written out here: these
# rows are the reference data the app draws from, and a second copy in a script is a second thing to keep in step.
NAVY=$(sql "SELECT device_hex FROM colour WHERE colour_name = 'Navy';")
NAVY_ID=$(sql "SELECT colour_id FROM colour WHERE colour_name = 'Navy';")

# ---------------------------------------------------------------------------- an edit reaches the cube
#
# **Recolouring a category is one command per face wearing it, and none for the rest.** The faces are asked of the
# table rather than assumed, which is what the app does too -- a category on no face is a swatch in a list and
# nothing on the cube.

open_settings
select_tab Categories

wearing=$(sql "SELECT COUNT(*) FROM face WHERE category_id = $CATEGORY AND face_id BETWEEN 1 AND 12;")

since=$(mark)
press "category-colour-$CATEGORY"
sleep 0.8
check_contains "the colour list opens on the row" "$(tree)" "id=colour-option-Navy"
press colour-option-Navy
sleep 1
check "picking Navy writes it to the category" "$NAVY_ID" \
    "$(sql "SELECT colour_id FROM category WHERE category_id = $CATEGORY;")"

expect_log "and the face wearing it is told its new colour" "$since" \
    "The cube took face $FACE $NAME $NAVY as rgb16 % ($NAME was recoloured), with no read-back to confirm it" 20
check "one command per face wearing it, and none for the rest" "$wearing" \
    "$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND tag = 'colour' AND message LIKE 'The cube took face %was recoloured%';")"

# ---------------------------------------------------------------------------- a cube connecting
#
# **A relaunch is the trigger, not a reset.** `quit_app` runs the app's own quit sequence, which lets the cube go, and
# the launch behind it reconnects -- which is what `53-device-reconnect` establishes and this borrows.

close_settings
quit_app
since=$(mark)
ensure_app_running

expect_log "the cube answers the opening questions on reconnecting" "$since" \
    "The cube has answered the opening questions" 60

settled=$(dsql "SELECT MIN(debug_log_id) FROM debug_log WHERE debug_log_id > $since AND message = 'The cube has answered the opening questions';")

# Waited for rather than counted straight away: twelve commands are twelve round trips, and the last of them lands
# well after the row that says the first went out.
wait_for_value "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND tag = 'ble-tx' AND message LIKE 'command withResponse: 11 %';" "12" 60
sent=$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND tag = 'ble-tx' AND message LIKE 'command withResponse: 11 %';")
check "connecting puts twelve 0x11 commands on the wire" "12" "$sent"

# **The check the whole script is for.** A colour command written before the login settled goes over the top of the
# `0x17` read it still has out, and nothing refuses it -- so what is compared is the id of the first colour command
# against the id of the row saying the login is done.
first=$(dsql "SELECT MIN(debug_log_id) FROM debug_log WHERE debug_log_id > $since AND tag = 'ble-tx' AND message LIKE 'command withResponse: 11 %';")
if [ -n "$first" ] && [ -n "$settled" ] && [ "$first" -gt "$settled" ]; then
    pass "and not one of them before the login had finished its own questions"
else
    fail "the first colour command was row ${first:-none} and the login settled at row ${settled:-none}"
fi

# **Each face named, rather than a total of twelve.** Twelve rows could be one face told twelve times, which is what
# a queue that failed to advance would look like from a count. `face 1 ` does not match `face 12 `, the trailing space
# being what tells them apart.
told=0
for f in $(seq 1 12); do
    [ "$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND tag = 'colour' AND message LIKE 'The cube took face $f %';")" = "1" ] \
        && told=$((told + 1))
done
check "every face is told exactly once" "12" "$told"

# **This cube asks on every connect**, so the row naming the request is the expected one rather than the exception.
# A cube that stopped asking would take the other branch, which is a real answer and not a failure: it would mean the
# colours had stuck. Both are read, and the line says which.
asked=$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND tag = 'colour' AND message LIKE '%the cube connected, having asked for them%';")
if [ "${asked:-0}" -gt 0 ]; then
    pass "the cube had asked for its colours, and the connecting send answered it"
else
    pass "the cube did not ask for its colours this time, so the connecting send stands alone"
fi

# **Read again rather than reusing the count above**, which is the whole of what this check adds: the request is
# answered by the connecting send, so a second run of twelve would land after it and a stale variable would miss it.
sleep 3
check "and it is answered once, not twice over" "12" \
    "$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND tag = 'ble-tx' AND message LIKE 'command withResponse: 11 %';")"

# ---------------------------------------------------------------------------- what each face was told
#
# **The colour on the wire is the category's, and a face holding nothing goes dark.** Both halves matter: `0x11` takes
# an RGB triple with no separate enable, so black is the only way to say off, and a face left lit would mean a
# category that is not there still showing on the cube.

expect_log "the face wearing the category carries its hex" "$since" \
    "The cube took face $FACE $NAME $NAVY as rgb16 %" 20

dark=$(sql "SELECT f.face_id FROM face f WHERE f.face_id BETWEEN 1 AND 12 AND f.category_id = 0 ORDER BY f.face_id LIMIT 1;")
if [ -z "$dark" ]; then
    fail "every face holds a category, so there is no unlit face to check"
else
    expect_log "and a face holding nothing is sent off" "$since" \
        "The cube took face $dark no category off as rgb16 0000,0000,0000%" 20
fi

# ---------------------------------------------------------------------------- putting the colour back
#
# **Not a check.** The category is left the colour this script found it wearing, for `04-categories`' reason: a run
# that leaves its subject somewhere new makes the next run's starting state the last run's ending state, and the
# colour column is the one thing here that persists past the wipe in `99`.

open_settings
select_tab Categories
if [ "$WAS" = "0" ]; then
    press "category-colour-$CATEGORY"
    sleep 0.8
    press colour-option-Navy
else
    press "category-colour-$CATEGORY"
    sleep 0.8
    press "colour-option-$(sql "SELECT colour_name FROM colour WHERE colour_id = $WAS;")"
fi
sleep 1
step "$NAME is back on colour_id $(sql "SELECT colour_id FROM category WHERE category_id = $CATEGORY;")"

close_settings
finish
