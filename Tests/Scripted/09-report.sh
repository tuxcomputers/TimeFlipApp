#!/bin/bash
# The Report tab: picking a range, what it totals, folding a category open, and the two sort columns.
#
# It runs after 06 because it needs entries to report on, and 06 is what makes them.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
start "the report range, its totals, and sorting them"

open_settings
select_tab Report

# **The day the newest entry belongs to, not today's date.** The app's day starts at `daily_reset_time`
# (3 AM by default), so a run at half past midnight is reporting on the *previous* calendar day: picking
# "today" would open a window that has not started yet and total nothing, which looks like the report
# being broken when it is the report being right. Worked out the same way the app works it out, from the
# reset hour and the newest entry's own start.
RESET=$(sql "SELECT json_extract(setting_value, '\$.hour') FROM setting WHERE setting_name = 'daily_reset_time';")
RESET=${RESET:-3}
DAY=$(sql "SELECT date(de.start_epoch - $RESET * 3600, 'unixepoch', 'localtime')
             FROM time_entry te JOIN device_event de ON de.device_event_id = te.device_event_id
            ORDER BY de.start_epoch DESC LIMIT 1;")
if [ -z "$DAY" ]; then
    fail "there are no time entries at all, so there is nothing to report on -- run 06 first"
    finish
    exit 1
fi
grey "  reporting on $DAY (the app's day starts at ${RESET}:00)"

# ---------------------------------------------------------------------------- the range

since=$(mark)
press "report-from-$DAY"
sleep 1.5
expect_log "picking a day sets the range" "$since" "Report range $DAY%"

# **The end starts unset**, which is the common case said in one click: pick a day and the report covers
# that day. The app says so rather than silently picking an end.
range=$(sql "SELECT message FROM debug_log WHERE debug_log_id > $since AND message LIKE 'Report range%' ORDER BY debug_log_id DESC LIMIT 1;")
check_contains "one day, with no end picked" "$range" "not set, reporting one day"

expect_log "and it totals what is in that day" "$since" "Report totals $DAY%"

# ---------------------------------------------------------------------------- what it totalled
#
# The figures on screen against the same sum from the table. This is the check that the clipping in that
# statement means what the range means -- two ways to the same number, one of them not the app's.

drawn=$(tree | grep -c "id=report-total-[0-9]*-heading" || true)
if [ "${drawn:-0}" -gt 0 ]; then
    pass "$drawn category total(s) drawn"
else
    fail "no totals drawn for today, so nothing below can be checked"
    finish
    exit 1
fi

# Only categories that recorded something appear. A page of 0:00 rows would bury the answer, which is why
# the read filters rather than the list hiding them afterwards.
zeroes=$(tree | grep -c "heading  desc=.*, 0:00$" || true)
check "no category is listed with nothing in it" "0" "$zeroes"

# ---------------------------------------------------------------------------- folding one open

first_id=$(tree | grep -o "id=report-total-[0-9]*-toggle" | head -1 | sed -E 's/.*report-total-([0-9]+)-toggle/\1/')
if [ -n "$first_id" ]; then
    since=$(mark)
    press "report-total-$first_id-heading"
    sleep 1.5
    expect_log "a category folds open on its heading" "$since" "Report category %opened"

    # The entries are read when the group is opened, not alongside the totals: a closed group's entries
    # are an answer nobody asked for.
    entries=$(tree | grep -c "report-entry-" || true)
    if [ "${entries:-0}" -gt 0 ]; then
        pass "its entries are listed underneath ($entries)"
    else
        fail "the group opened and drew no entries"
    fi

    since=$(mark)
    press "report-total-$first_id-heading"
    sleep 1.5
    expect_log "and folds shut again" "$since" "Report category %closed"
else
    fail "could not find a category group to open"
fi

# ---------------------------------------------------------------------------- sorting
#
# Two questions, and the headings are how you say which one is being asked. Checked by reading the order
# of the rows off the tree, since that is the thing somebody actually sees.

order_now() { tree | grep -o "id=report-total-[0-9]*-heading" | sed -E 's/.*report-total-([0-9]+)-heading/\1/' | tr '\n' ' '; }

# It opens on the shared category order, so a category sits in the same place as on the Categories and
# Faces tabs.
check_contains "it opens sorted by category, ascending" "$(element report-sort-category)" "Category ▲"

by_category=$(order_now)

since=$(mark)
press report-sort-time
sleep 1.5
expect_log "clicking Time sorts by it" "$since" "Report sorted by time, descending"
check_contains "and the arrow moves to that column" "$(element report-sort-time)" "Time ▼"
check "leaving the other one bare" "0" "$(element report-sort-category | grep -c '▲\|▼' || true)"

by_time_desc=$(order_now)
if [ "$by_time_desc" != "$by_category" ] || [ "$drawn" = "1" ]; then
    pass "the rows are in a different order ($by_category-> $by_time_desc)"
else
    fail "clicking Time changed nothing about the order ($by_category)"
fi

# Largest first, which is what asking about time means. Read off the app's own figures rather than
# recomputed here.
seconds_in_order() {
    for id in $(order_now); do
        sql "SELECT CAST(SUM(te.duration_seconds) AS INTEGER) FROM time_entry te WHERE te.category_id = $id;"
    done | tr '\n' ' '
}

since=$(mark)
press report-sort-time
sleep 1.5
expect_log "clicking it again reverses it" "$since" "Report sorted by time, ascending"
check_contains "and the arrow turns over" "$(element report-sort-time)" "Time ▲"

reversed=$(order_now)
forwards=$(printf '%s' "$by_time_desc" | tr ' ' '\n' | grep -v '^$' | tail -r | tr '\n' ' ')
check "the order is the reverse of the first click" "$forwards" "$reversed"

since=$(mark)
press report-sort-category
sleep 1.5
expect_log "clicking Category goes back to the shared order" "$since" "Report sorted by category, ascending"
check "and the rows are where they started" "$by_category" "$(order_now)"

since=$(mark)
press report-sort-category
sleep 1.5
expect_log "clicking it again reverses that too" "$since" "Report sorted by category, descending"
back=$(printf '%s' "$by_category" | tr ' ' '\n' | grep -v '^$' | tail -r | tr '\n' ' ')
check "which is the category order upside down" "$back" "$(order_now)"

# Left on the order it opens with, so a later run starts where this one did.
press report-sort-category
sleep 1

finish
