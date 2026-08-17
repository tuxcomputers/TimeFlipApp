#!/bin/bash
# Quitting: the way out closes what was left open.
#
# **Numbered 99 so it stays last whatever is added before it.** This is the script that ends the app, so anything
# after it would run against nothing at all -- and numbering it out at the end rather than one past the last leaves
# every number in between free, so a new script takes the next one and nothing is renumbered to make room. That is
# not hypothetical: `12-daily-limit` was written as `13` because quit held `12`, and it would have run after the app
# had already gone.
#
# Last, because it ends with no app running. **This is the one thing that cannot be checked by looking at
# the app afterwards**, so everything it proves is read out of the database once the process is gone.
#
# Why it matters: a segment left open is measured from its start to *now* by whatever reads it next, so a
# launch inheriting one from a quit that skipped this would show a session lasting however long the app
# was shut. Startup recovery exists as the second line of defence, and this is the first.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
start "quitting closes the open segment"

open_settings
select_tab Faces

# Something to leave running, so the quit has work to do.
NAME=$(next_name Quit)
since=$(mark)
press create-category
sleep 0.5
set_field category-name-field "$NAME"
press save-category
sleep 1
ID=$(sql "SELECT message FROM debug_log WHERE debug_log_id > $since AND message LIKE '%Save new category%' ORDER BY debug_log_id LIMIT 1;" | sed -E 's/.*category_id ([0-9]+).*/\1/')

BLIP=$(sql "SELECT json_extract(setting_value, '\$.seconds') FROM setting WHERE setting_name = 'blip_time';")
BLIP=${BLIP:-5}

# Creating it on the Faces tab started it, so there is nothing to click: the segment this quit has to close is
# already open.
sleep $((BLIP + 3))

open_row=$(sql "SELECT device_event_id FROM device_event WHERE finalised != 1 ORDER BY device_event_id DESC LIMIT 1;")
if [ -n "$open_row" ]; then
    pass "a segment is open going into the quit (id $open_row)"
else
    fail "nothing is open, so this script would prove nothing"
    finish
    exit 1
fi

# ---------------------------------------------------------------------------- out through the menu
#
# The app's own way out, which is the only one that runs the quit sequence. Killing the process would
# skip exactly the thing being checked.

since=$(mark)
close_settings
python3 scripts/status-item-click.py >/dev/null 2>&1
sleep 0.5
press quit-app

# Waits for the process rather than sleeping a fixed time.
waited=0
while [ "$waited" -lt 150 ]; do
    is_running || break
    sleep 0.1
    waited=$((waited + 1))
done

if is_running; then
    fail "the app is still running 15s after Quit"
    pkill -x Facet
    finish
    exit 1
fi
pass "the app quit"

# ---------------------------------------------------------------------------- what it left behind

expect_log "the quit sequence closed the open segment" "$since" "Quit: closed the open segment, device_event $open_row"

check "and the row is finalised" "1" "$(sql "SELECT finalised FROM device_event WHERE device_event_id = $open_row;")"
check "nothing at all is left open" "0" "$(sql "SELECT COUNT(*) FROM device_event WHERE finalised != 1;")"

# **Closed keeping the duration it already had**, not extended to the moment of the quit. The two are the
# same here to within a second, so what is checked is the weaker, honest thing: it is a real length rather
# than zero, and not wildly beyond what was actually timed.
seconds=$(sql "SELECT duration_seconds FROM device_event WHERE device_event_id = $open_row;")
if awk "BEGIN{exit !($seconds >= $BLIP && $seconds < $BLIP + 60)}"; then
    pass "with the length it had been running (${seconds}s)"
else
    fail "the closed segment says ${seconds}s, which is not the few seconds it ran for"
fi

# And it became tracked time on the way out, since closing a segment is what raises that question.
expect_log "the closed segment became an entry" "$since" "time_entry created id=%category=$ID%"

# ---------------------------------------------------------------------------- and the device
#
# **The quit is where a connection ends now**, the link having stopped belonging to the Settings window when pairing
# arrived. Nothing else could end it: the process simply stops, so without this step the last thing written says the
# cube is connected and the next launch reads a link nothing is holding.
#
# Recorded whether or not a cube was connected, and the three fields are three different endings: `connected` says
# reachable now, `connection_lost` says the cube went away, `quit_request` says the app was asked to stop. A quit
# clears the second so it cannot later be read as the first kind of ending.

expect_log "the quit sequence let go of the device" "$since" "Quit: %device%"

check "the connection is recorded as down" "0" "$(sql "SELECT json_extract(setting_value, '\$.connected') FROM setting WHERE setting_name = 'connection';")"
check "the quit is stamped with today" "$(date +%Y-%m-%d)" "$(sql "SELECT substr(json_extract(setting_value, '\$.quit_request'), 1, 10) FROM setting WHERE setting_name = 'connection';")"
check "and no drop is left recorded against a deliberate quit" "" "$(sql "SELECT json_extract(setting_value, '\$.connection_lost') FROM setting WHERE setting_name = 'connection';")"

finish
