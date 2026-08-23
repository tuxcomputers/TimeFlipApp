#!/bin/bash
# A finished segment becoming tracked time, and a flick past a face not becoming anything.
#
# `device_event` is what a source says happened; `time_entry` is what the app counts. They are
# deliberately not the same question, and this is where the second one gets answered.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
# What this script checks when everything passes. See `finish` in lib.sh for what a mismatch means.
EXPECTED_CHECKS=12
start "a segment becoming a time entry, and a blip not"

open_settings
select_tab Faces

# The threshold this whole script is measured against, read from the table rather than assumed: it is a
# setting somebody can change, and a script carrying its own copy of it would be testing a number nobody
# is using.
BLIP=$(sql "SELECT json_extract(setting_value, '\$.seconds') FROM setting WHERE setting_name = 'blip_time';")
BLIP=${BLIP:-5}
grey "  blip_time is ${BLIP}s"

NAME=$(next_name Entry)
since=$(mark)
press create-category
sleep 0.5
set_field category-name-field "$NAME"
press save-category
sleep 1
ID=$(dsql "SELECT message FROM debug_log WHERE debug_log_id > $since AND message LIKE '%Save new category%' ORDER BY debug_log_id LIMIT 1;" | sed -E 's/.*category_id ([0-9]+).*/\1/')
if [ -z "$ID" ]; then
    fail "could not create a category to record against"
    finish
    exit 1
fi

# ---------------------------------------------------------------------------- time that counts

since=$(mark)
# **Nothing is clicked to start it.** Creating a category on the Faces tab assigns it to a face and starts timing
# it, so the clock has been running since the save above; clicking the row now would be the no-op `05` checks.
sleep $((BLIP + 4))
press timing-play-pause
sleep 2

expect_log "closing a segment over blip_time writes an entry" "$since" "time_entry created id=%category=$ID%"

entry=$(sql "SELECT time_entry_id FROM time_entry WHERE category_id = $ID ORDER BY time_entry_id DESC LIMIT 1;")
if [ -n "$entry" ]; then
    pass "the entry is in the table (id $entry)"
else
    fail "no time_entry row for category $ID"
    finish
    exit 1
fi

# Every column is worked out when the entry is made, never backfilled, so they can all be checked now.
check "it is filed under the category that was timed" "$ID" "$(sql "SELECT category_id FROM time_entry WHERE time_entry_id = $entry;")"

seconds=$(sql "SELECT duration_seconds FROM time_entry WHERE time_entry_id = $entry;")
if awk "BEGIN{exit !($seconds >= $BLIP)}"; then
    pass "its duration is over blip_time (${seconds}s)"
else
    fail "the entry lasted ${seconds}s, which is under the ${BLIP}s threshold it was supposed to clear"
fi

# The end is the start plus the length, both through the segment's own zone. Nothing here could know a
# zone changed part way through, so both ends carry the one the segment was recorded in.
check "both ends carry a zone" "0" "$(sql "SELECT COUNT(*) FROM time_entry WHERE time_entry_id = $entry AND (start_timezone_id IS NULL OR end_timezone_id IS NULL);")"

# **Whether it is still unsynced depends on whether anything is connected**, and that is the point of the
# column rather than a wrinkle in this check. The recorder writes 0; recording an entry then starts a
# sweep, so with a Google account connected the row can be ticked within a second -- faster than this
# script can look at it. Asserting 0 unconditionally passed until an account existed and then failed on
# the app working, which is the wrong way round.
synced=$(sql "SELECT synced_to_google_calendar FROM time_entry WHERE time_entry_id = $entry;")
if [ -z "$(sql "SELECT json_extract(setting_value, '\$.email') FROM setting WHERE setting_name = 'google_account';")" ]; then
    check "it stays unsynced, there being nowhere to sync it" "0" "$synced"
else
    if [ "$synced" = "0" ] || [ "$synced" = "1" ]; then
        pass "the sync flag holds a real value ($synced, with an account connected)"
    else
        fail "synced_to_google_calendar holds '$synced', which is neither 0 nor 1"
    fi
    grey "          10-google-calendar is what checks the sweep itself"
fi

# **One entry per segment, as a constraint rather than a convention** (`UN1_time_entry`). The same
# segment offered twice cannot be counted twice.
segment=$(sql "SELECT device_event_id FROM time_entry WHERE time_entry_id = $entry;")
check "exactly one entry for that segment" "1" "$(sql "SELECT COUNT(*) FROM time_entry WHERE device_event_id = $segment;")"
check "and the segment is marked processed" "1" "$(sql "SELECT processed FROM device_event WHERE device_event_id = $segment;")"

# ---------------------------------------------------------------------------- a blip
#
# The cube being turned past a face rather than time spent on it. No entry, ever -- and the segment is
# still marked processed, because the question has been answered and leaving it unprocessed would grow a
# tail of rows every later pass re-examines.

before=$(sql "SELECT COUNT(*) FROM time_entry WHERE category_id = $ID;")
since=$(mark)
press "category-row-$ID"
sleep 1
press timing-play-pause
sleep 2

expect_log "a segment under blip_time is ignored" "$since" "%ignored, under blip_time=${BLIP}s"
check "it wrote no entry" "$before" "$(sql "SELECT COUNT(*) FROM time_entry WHERE category_id = $ID;")"

blip_row=$(sql "SELECT device_event_id FROM device_event WHERE device_face >= 13 ORDER BY device_event_id DESC LIMIT 1;")
check "the blipped segment is still marked processed" "1" "$(sql "SELECT processed FROM device_event WHERE device_event_id = $blip_row;")"

# **Not lost, just not counted.** The segment is on record; what it did not earn is an entry.
check "the segment itself is still on record" "1" "$(sql "SELECT COUNT(*) FROM device_event WHERE device_event_id = $blip_row;")"

finish
