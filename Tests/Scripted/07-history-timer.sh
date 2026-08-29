#!/bin/bash
# The history timer: it runs while something is being timed, and stops when nothing is.
#
# **A working timer used to be completely silent.** Every tick goes through `refreshOpenSegment`, which
# logs nothing, so the only sign of life was `device_event.duration_seconds` moving -- a 79-second gap in
# the log turned out to be eight healthy ticks. It now says when it fires, which is what makes this
# script possible at all.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
# What this script checks when everything passes. See `finish` in lib.sh for what a mismatch means.
EXPECTED_CHECKS=8
start "the history timer running, stopping and coming back"

open_settings
select_tab Faces

INTERVAL=$(sql "SELECT json_extract(setting_value, '\$.seconds') FROM setting WHERE setting_name = 'fetch_history_interval_seconds';")
INTERVAL=${INTERVAL:-10}
step "the interval is ${INTERVAL}s"

# Whatever the last script left, start from stopped so what follows is this script's doing.
if [ "$(sql "SELECT COUNT(*) FROM device_event WHERE finalised != 1;")" != "0" ]; then
    press timing-play-pause
    sleep 2
fi

# ---------------------------------------------------------------------------- while nothing is timed

# It should not be running at all. That was the point of the change: a paused app woke every interval to
# discover there was nothing to do.
#
# The interval plus four, for the reason set out at the matching check further down: waiting exactly the period
# lets a tick arrive just after the count is read, which passes the check by luck rather than by the timer being
# stopped.
since=$(mark)
step "watching for $((INTERVAL + 4))s with nothing being timed, which is long enough for a tick to show up..."
sleep $((INTERVAL + 4))
ticks=$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND message LIKE 'History timer fired%';")
check "it does not fire while nothing is being timed" "0" "$ticks"

# ---------------------------------------------------------------------------- while something is

NAME=$(next_name Timer)
since=$(mark)
press create-category
sleep 0.5
set_field category-name-field "$NAME"
press save-category
sleep 1
ID=$(dsql "SELECT message FROM debug_log WHERE debug_log_id > $since AND message LIKE '%Save new category%' ORDER BY debug_log_id LIMIT 1;" | sed -E 's/.*category_id ([0-9]+).*/\1/')
sleep 2

# **When the clock started**, which is the create rather than anything below it: making a category on the Faces tab
# assigns it to a face and starts timing straight away. Read from the wall clock rather than from
# `duration_seconds`, because that column only moves when the history timer ticks -- it reads 0, then 10, then 20 on
# a ten-second interval, so asking it to reach 22 would really be waiting for 30.
TIMING_FROM=$(date +%s)

# **Measured from before the create, because the create is what starts the clock now.** Making a category on the
# Faces tab assigns it to a face and starts timing it, so the history timer is already running by the time the row
# could be clicked -- and a mark taken after the create would be looking for a row written before it.
expect_log "starting to time starts the timer" "$since" "History timer started%"

# It says the interval it is on, so two consecutive lines are what show a change taking effect.
started=$(dsql "SELECT message FROM debug_log WHERE debug_log_id > $since AND message LIKE 'History timer started%' ORDER BY debug_log_id LIMIT 1;")
check_contains "and names the interval it is asking on" "$started" "every ${INTERVAL}s"

since=$(mark)
expect_log "it fires" "$since" "History timer fired%" $((INTERVAL + 8))

# Twice, so this is a repeating timer rather than one that fired once and stopped. Each fire re-arms the
# next from a fresh read of the setting.
since=$(mark)
expect_log "and goes on firing" "$since" "History timer fired%" $((INTERVAL + 8))

# ---------------------------------------------------------------------------- and stops again

# **Twenty-two seconds on the clock before the pause.** Two full intervals and a margin, so the segment being paused
# is one the timer has demonstrably ticked over more than once rather than one that was created and stopped inside a
# single period. The two fires above normally take it most of the way there; this is what makes it certain rather
# than a consequence of how long they happened to take.
elapsed=$(( $(date +%s) - TIMING_FROM ))
if [ "$elapsed" -lt 22 ]; then
    step "letting the clock climb to 22s before pausing (${elapsed}s so far)"
    sleep $(( 22 - elapsed ))
fi
step "paused after $(( $(date +%s) - TIMING_FROM ))s of timing"

since=$(mark)
press timing-play-pause
sleep 2
expect_log "pausing stops it" "$since" "History timer stopped, nothing is being timed" $((INTERVAL + 8))

# The real check: no more fires after it said it stopped.
# **The interval plus four, and the four is the whole point.** Waiting exactly the period is a race: the tick is due
# at the moment the count is taken, so a timer that is still running can land just after the check has read zero and
# passed. The check would then be recording that the app happened to be a few milliseconds late rather than that it
# had stopped. Outlasting the period by four seconds means a timer still running has certainly fired inside the
# window, so a zero is a zero.
since=$(mark)
step "watching for $((INTERVAL + 4))s, long enough that a timer still running would have fired in it..."
sleep $((INTERVAL + 4))
after=$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND message LIKE 'History timer fired%';")
check "and it stays stopped" "0" "$after"

# ---------------------------------------------------------------------------- coming back
#
# Through `onTimingChanged`, the funnel every path that starts timing already goes through, rather than a
# second notification each new path would have to remember.

since=$(mark)
press "category-row-$ID"
sleep 2
expect_log "timing again brings it back" "$since" "History timer started%"

# Left paused, for the next script.
press timing-play-pause
sleep 1

finish
