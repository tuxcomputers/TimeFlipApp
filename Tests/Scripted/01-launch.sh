#!/bin/bash
# The app starts, opens the database it was told to, records what it is doing, and refuses to run twice.
#
# First because everything else depends on it. A failure here means every later script would be testing
# against an app that is not really up, or writing to a database nobody meant to touch.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
start "the app launches, opens the test database and records what it does"

# **A cold start, always.** This script is about launching, so an app left running by an earlier run has
# to go first -- otherwise `ensure_app_running` finds it up, launches nothing, and every check below waits
# for rows a launch that never happened would have written.
if is_running; then
    grey "  quitting the app left running, so this starts cold"
    quit_app
    sleep 1
fi

# From before the launch, so what is found afterwards was written by this run.
since=$(mark)
ensure_app_running

check "the app is running" "yes" "$(is_running && echo yes || echo no)"

# The launch writes its mode as it decides it, which is the first thing this app does that leaves a
# trace. Waiting for the row rather than sleeping means this is as fast as the app is.
expect_log "the launch records which mode it is in" "$since" "Manual mode:%" 20

# Nothing is paired in a test run, so manual mode is the expected answer -- and it is worth saying out
# loud rather than accepting whatever comes, because a paired cube changes what every later script
# means. Segments would come from the device instead of from the app.
mode=$(sql "SELECT message FROM debug_log WHERE debug_log_id > $since AND message LIKE 'Manual mode:%' ORDER BY debug_log_id LIMIT 1;")
check_contains "manual mode, since no device is paired" "$mode" "on, no device is paired"

# The debug log is how every other script in this folder checks anything, so its own writing is worth
# one check of its own: a silent log would make every later script pass by finding nothing to object to.
rows=$(sql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since;")
if [ "${rows:-0}" -gt 0 ]; then
    pass "the debug log is being written ($rows rows so far)"
else
    fail "the debug log has no rows from this launch, so nothing below could be checked"
fi

# The zone is a foreign key rather than text on the row, so a launch that could not resolve one leaves
# every timestamp pointing at the seeded Unknown. Worth knowing before a script reads a time.
unknown=$(sql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND timezone_id = 0;")
check "every logged row resolved a real time zone" "0" "$unknown"

# ---------------------------------------------------------------------------- one instance only
#
# A second copy must stand down rather than open the database a second time. It exits 0 doing so,
# because standing down is this code working, and it says so on stderr.
second=$(open -n "$APP" 2>&1; sleep 2; echo done)
count=$(pgrep -x Facet | wc -l | tr -d ' ')
check "a second launch does not leave a second instance running" "1" "$count"

finish
