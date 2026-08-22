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

# **Checked against the table rather than assumed**, because both answers are now legitimate: a rebuilt database has
# nothing paired and manual mode is the expected answer, while a `--keep` run after `51-device-connect` starts with a
# real pairing in it and manual mode off. What is worth saying out loud either way is that the launch agrees with the
# row it read -- a paired cube changes what every later script means, since segments would come from the device
# instead of from the app.
mode=$(dsql "SELECT message FROM debug_log WHERE debug_log_id > $since AND message LIKE 'Manual mode:%' ORDER BY debug_log_id LIMIT 1;")
paired=$(sql "SELECT json_extract(setting_value, '\$.paired') FROM setting WHERE setting_name = 'paired';")
if [ "$paired" = "1" ]; then
    check_contains "manual mode is off, a device being paired" "$mode" "off, a device is paired"
else
    check_contains "manual mode, since no device is paired" "$mode" "on, no device is paired"
fi

# The debug log is how every other script in this folder checks anything, so its own writing is worth
# one check of its own: a silent log would make every later script pass by finding nothing to object to.
rows=$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since;")
if [ "${rows:-0}" -gt 0 ]; then
    pass "the debug log is being written ($rows rows so far)"
else
    fail "the debug log has no rows from this launch, so nothing below could be checked"
fi

# The zone is a foreign key rather than text on the row, so a launch that could not resolve one leaves
# every timestamp pointing at the seeded Unknown. Worth knowing before a script reads a time.
unknown=$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND timezone_id = 0;")
check "every logged row resolved a real time zone" "0" "$unknown"

# ---------------------------------------------------------------------------- one instance only
#
# **The binary is run directly, not through `open`.** `open -n` hands the launch to macOS, which may
# decline to start a duplicate for reasons of its own, and it discards the launched process's stderr --
# so a check built on it can pass without the lock ever being asked anything, and can never see the
# refusal. Running the executable is the only way to get both the exit status and the message.
#
# Accessibility ignores a bare executable (Method 1), which does not matter here: nothing presses
# anything, the process is expected to die in milliseconds.

since=$(mark)
refusal="$(mktemp)"
"$BINARY" >"$refusal" 2>&1 &
second=$!

# Waited for rather than slept on, and killed if it outlives the wait -- if the lock ever stopped
# working this would otherwise be a second app running for the rest of the suite, which is a far more
# confusing failure than the one being tested for.
waited=0
while kill -0 "$second" 2>/dev/null && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
done

if kill -0 "$second" 2>/dev/null; then
    kill "$second" 2>/dev/null
    fail "the second instance was still running after 5s, so the lock did not hold"
else
    wait "$second"
    status=$?
    # **Zero, deliberately.** Standing down is this code working, and a non-zero status would tell
    # whatever launched it that the launch was broken.
    check "a second instance exits, and exits 0" "0" "$status"
    check_contains "saying why on stderr" "$(cat "$refusal")" "already running"
fi
rm -f "$refusal"

# The point of the lock: a duplicate must not open the database. `Manual mode` is logged after the lock
# is claimed and the database is open, so a second one of those is the failure this exists to prevent --
# and it is a sharper test than counting processes, which cannot tell "refused" from "never started".
check "and it never opened the database" "0" \
    "$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND message LIKE 'Manual mode%';")"

check "the original is still the only one running" "1" "$(pgrep -x Facet | wc -l | tr -d ' ')"

finish
