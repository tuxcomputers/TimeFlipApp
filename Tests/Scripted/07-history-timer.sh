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
start "the history timer running, stopping and coming back"

open_settings
select_tab Faces

INTERVAL=$(sql "SELECT json_extract(setting_value, '\$.seconds') FROM setting WHERE setting_name = 'fetch_history_interval_seconds';")
INTERVAL=${INTERVAL:-10}
grey "  the interval is ${INTERVAL}s"

# Whatever the last script left, start from stopped so what follows is this script's doing.
if [ "$(sql "SELECT COUNT(*) FROM device_event WHERE finalised != 1;")" != "0" ]; then
    press timing-play-pause
    sleep 2
fi

# ---------------------------------------------------------------------------- while nothing is timed

# It should not be running at all. That was the point of the change: a paused app woke every interval to
# discover there was nothing to do.
since=$(mark)
sleep $((INTERVAL + 3))
ticks=$(sql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND message LIKE 'History timer fired%';")
check "it does not fire while nothing is being timed" "0" "$ticks"

# ---------------------------------------------------------------------------- while something is

NAME="Timer $(date '+%H:%M:%S')"
since=$(mark)
press create-category
sleep 0.5
set_field category-name-field "$NAME"
press save-category
sleep 1
ID=$(sql "SELECT message FROM debug_log WHERE debug_log_id > $since AND message LIKE '%Save new category%' ORDER BY debug_log_id LIMIT 1;" | sed -E 's/.*category_id ([0-9]+).*/\1/')

since=$(mark)
press "category-row-$ID"
sleep 2
expect_log "starting to time starts the timer" "$since" "History timer started%"

# It says the interval it is on, so two consecutive lines are what show a change taking effect.
started=$(sql "SELECT message FROM debug_log WHERE debug_log_id > $since AND message LIKE 'History timer started%' ORDER BY debug_log_id LIMIT 1;")
check_contains "and names the interval it is asking on" "$started" "every ${INTERVAL}s"

since=$(mark)
expect_log "it fires" "$since" "History timer fired%" $((INTERVAL + 8))

# Twice, so this is a repeating timer rather than one that fired once and stopped. Each fire re-arms the
# next from a fresh read of the setting.
since=$(mark)
expect_log "and goes on firing" "$since" "History timer fired%" $((INTERVAL + 8))

# ---------------------------------------------------------------------------- and stops again

since=$(mark)
press timing-play-pause
sleep 2
expect_log "pausing stops it" "$since" "History timer stopped, nothing is being timed" $((INTERVAL + 8))

# The real check: no more fires after it said it stopped.
since=$(mark)
sleep $((INTERVAL + 3))
after=$(sql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND message LIKE 'History timer fired%';")
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
