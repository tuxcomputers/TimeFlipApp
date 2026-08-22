#!/bin/bash
# The Faces tab: picking a category starts the clock on it, and pausing stops it.
#
# **With no cube paired the app is its own source**, timing on faces 13 and 14 (`ManualTimerRules`), so
# what is checked here is the same machinery a device drives -- a segment opens in `device_event`, grows,
# and closes -- reached through the app rather than through a radio.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
start "starting, pausing and resuming the clock"

open_settings
select_tab Faces

# A category of this run's own, so what is timed below cannot be confused with a category somebody was
# already using. Created here rather than reused from 04, which retires and reinstates the one it makes.
NAME=$(next_name Timing)
since=$(mark)
press create-category
sleep 0.5
set_field category-name-field "$NAME"
press save-category
sleep 1.5
ID=$(dsql "SELECT message FROM debug_log WHERE debug_log_id > $since AND message LIKE '%Save new category%' ORDER BY debug_log_id LIMIT 1;" | sed -E 's/.*category_id ([0-9]+).*/\1/')
if [ -z "$ID" ]; then
    fail "could not create a category to time against"
    finish
    exit 1
fi
pass "a category to time against ($NAME, id $ID)"

# ---------------------------------------------------------------------------- creating one starts it
#
# **On this tab, making a category is saying what you are doing now.** Typing a name here and then having to
# click the row you just made is saying it twice, so the create assigns it to a face and starts it. The
# Categories tab's identical control deliberately does not (`04` makes several and starts none of them):
# there, a name is a list being maintained rather than a day being recorded.

expect_log "creating it on the Faces tab starts timing it" "$since" "Timing: started \"$NAME\"%"
expect_log "and says which face it went to" "$since" "%(category_id $ID) on face %"

# ---------------------------------------------------------------------------- starting, by picking a row
#
# The other way in, and still the ordinary one: a category that already exists is started by clicking it.
# **Break is used rather than the category just made**, because that one is already running and clicking it
# is the no-op checked below rather than a start.

BREAK=$(sql "SELECT category_id FROM category WHERE category_name = 'Break';")
since=$(mark)
press "category-row-$BREAK"
sleep 1.5
# **"started", not "running".** Picking a category is a fresh start and says so, naming the category id
# and the face it went to; the play/pause control below says "running" when it resumes one. Two actions,
# two words, and a script that expected one wording for both would wait for a row nobody writes.
expect_log "picking a category starts timing it" "$since" "Timing: started \"Break\"%"

# Clicking the one already running asks for nothing, and says so rather than rotating the face and closing a
# segment for a gesture that wanted no change. Worth a check of its own now that a create leaves a category
# running, which is the state this guard is reached from.
since=$(mark)
press "category-row-$BREAK"
sleep 1
expect_log "clicking the one already running changes nothing" "$since" "%already timing \"Break\"%"

# Back to this run's own category for everything below.
since=$(mark)
press "category-row-$ID"
sleep 1.5
expect_log "and picking another moves the clock to it" "$since" "Timing: started \"$NAME\"%"

# A row in `device_event`, open, on one of the app's own faces. This is the fact behind the clock: the
# readout is drawn from it every time rather than from anything the click remembered.
open_row=$(sql "SELECT device_event_id FROM device_event WHERE finalised != 1 ORDER BY device_event_id DESC LIMIT 1;")
if [ -n "$open_row" ]; then
    pass "a segment is open in device_event (id $open_row)"
else
    fail "nothing is open in device_event, so nothing is really being timed"
fi

face=$(sql "SELECT device_face FROM device_event WHERE device_event_id = $open_row;")
if [ "${face:-0}" -ge 13 ]; then
    pass "it is on one of the app's own faces ($face)"
else
    fail "the segment is on face $face, which is a cube's face and not the app's"
fi

# The face has to hold the category, since that is what says whose time this is when the segment closes.
# `face` keys on `face_id`; `device_face` is the column over on `device_event`. Two names for the same
# number, in the two tables that each mean something different by it.
check "the face holds the category" "$ID" "$(sql "SELECT category_id FROM face WHERE face_id = $face;")"

# The clock on screen names it too, read from the table rather than pushed at the label.
check_contains "the Timing column names it" "$(tree)" "id=timing-category-name  value=$NAME"

# ---------------------------------------------------------------------------- it actually runs
#
# Two readings a second apart. The duration is grown by the history timer re-reporting the open segment,
# so this is also the one check that the timer is doing its job end to end.
first=$(sql "SELECT duration_seconds FROM device_event WHERE device_event_id = $open_row;")
sleep 12
second=$(sql "SELECT duration_seconds FROM device_event WHERE device_event_id = $open_row;")
if awk "BEGIN{exit !($second > $first)}"; then
    pass "the open segment's duration grows while it runs ($first -> $second)"
else
    fail "the duration did not move in 12s ($first -> $second), so nothing is being measured"
fi

# ---------------------------------------------------------------------------- pausing

since=$(mark)
press timing-play-pause
sleep 1.5
expect_log "the play/pause control stops it" "$since" "Timing: stopped \"$NAME\"%"

# **Pausing closes the segment rather than flagging it.** There is no "paused" state held anywhere: an
# open row is what running means, so stopping means there is no open row.
check "nothing is left open" "0" "$(sql "SELECT COUNT(*) FROM device_event WHERE finalised != 1;")"
check "the segment that was running is finalised" "1" "$(sql "SELECT finalised FROM device_event WHERE device_event_id = $open_row;")"

# ---------------------------------------------------------------------------- resuming

since=$(mark)
press timing-play-pause
sleep 1.5
expect_log "it starts again on the same category" "$since" "Timing: running \"$NAME\"%"

resumed=$(sql "SELECT device_event_id FROM device_event WHERE finalised != 1 ORDER BY device_event_id DESC LIMIT 1;")
if [ -n "$resumed" ] && [ "$resumed" != "$open_row" ]; then
    pass "resuming opens a new segment rather than reopening the closed one"
else
    fail "resuming did not open a fresh segment (got '$resumed', was '$open_row')"
fi

# **The same face, deliberately.** Rotating faces exists so a face's category cannot change under a
# finished segment; resuming is the same category continuing, so it reuses the face rather than cycling
# the pool for no reason.
check "on the same face it was using" "$face" "$(sql "SELECT device_face FROM device_event WHERE device_event_id = $resumed;")"

# Left paused, so the next script starts from a known state and the status item is not counting.
press timing-play-pause
sleep 1

finish
