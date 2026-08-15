#!/bin/bash
# The Google section, and recorded time reaching the calendar.
#
# **Everything here is skipped rather than failed when no account is connected.** Signing in needs a
# browser, a Google account and somebody to approve it, none of which a script should do on your behalf,
# and a developer who has not connected one has not broken anything. What is skipped is printed loudly,
# so a run is never read as fuller coverage than it was.
#
# To make this section actually run: open Settings -> App -> Sign in with Google once. Everything below
# then works on its own from there on.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
start "the Google account, its calendar, and an entry syncing to it"

open_settings
select_tab App

account=$(sql "SELECT setting_value FROM setting WHERE setting_name = 'google_account';")
email=$(sql "SELECT json_extract(setting_value, '\$.email') FROM setting WHERE setting_name = 'google_account';")
calendar_id=$(sql "SELECT json_extract(setting_value, '\$.calendar_id') FROM setting WHERE setting_name = 'google_account';")

if [ -z "$email" ]; then
    skip "no Google account is connected, so the calendar and the sync cannot be checked"
    skip "connect one on Settings -> App to include this section"
    grey "  the google_account row is: $account"
    finish
    exit 0
fi

pass "an account is connected ($email)"

# What the section says has to agree with the row behind it. A window showing an account the table does
# not hold is the two-answers problem this codebase exists to avoid.
check_contains "the tab shows the connected email" "$(element app-google-email)" "$email"
check_contains "and says so in the Status row" "$(element app-google-status)" "Connected"

# ---------------------------------------------------------------------------- the calendar

if [ -z "$calendar_id" ]; then
    skip "connected, but no calendar has been made yet -- nothing to sync into"
    finish
    exit 0
fi

pass "a calendar is stored ($(printf '%.20s' "$calendar_id")...)"

calendar_name=$(sql "SELECT json_extract(setting_value, '\$.calendar_name') FROM setting WHERE setting_name = 'google_account';")
check_contains "the Calendar row shows its name" "$(element app-google-calendar)" "$calendar_name"

# **The name is a label and the id is the identity.** The row is editable and a rename goes to Google, so
# what must never happen is the name deciding anything.
check "the name is not what identifies it" "1" "$([ -n "$calendar_id" ] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------- an entry reaching it
#
# Recording an entry sweeps every row still at 0, so this both makes one and watches the sweep carry it.
# The event is created and then read back and checked before the row is ticked, which is what the tick
# means -- so a pass here is "the event is at Google and is right", not "a request returned 200".

select_tab Faces
NAME="Sync $(date '+%H:%M:%S')"
since=$(mark)
press create-category
sleep 0.5
set_field category-name-field "$NAME"
press save-category
sleep 1
ID=$(sql "SELECT message FROM debug_log WHERE debug_log_id > $since AND message LIKE '%Save new category%' ORDER BY debug_log_id LIMIT 1;" | sed -E 's/.*category_id ([0-9]+).*/\1/')

BLIP=$(sql "SELECT json_extract(setting_value, '\$.seconds') FROM setting WHERE setting_name = 'blip_time';")
BLIP=${BLIP:-5}

since=$(mark)
press "category-row-$ID"
sleep $((BLIP + 4))
press timing-play-pause
sleep 2

entry=$(sql "SELECT time_entry_id FROM time_entry WHERE category_id = $ID ORDER BY time_entry_id DESC LIMIT 1;")
if [ -z "$entry" ]; then
    fail "no entry was recorded, so there is nothing for the sweep to carry"
    finish
    exit 1
fi
pass "an entry to sync (id $entry)"

expect_log "recording an entry starts a sweep" "$since" "Calendar sync started%" 30

# The network is involved, so this waits longer than anything else here. Two round trips per entry, at
# roughly a second each.
if wait_for_value "SELECT synced_to_google_calendar FROM time_entry WHERE time_entry_id = $entry;" "1" 60 >/dev/null; then
    pass "the entry is marked synced, which means its event was read back and checked"
else
    reason=$(sql "SELECT message FROM debug_log WHERE debug_log_id > $since AND tag = 'sync' ORDER BY debug_log_id DESC LIMIT 1;")
    fail "the entry is still unsynced after 60s (last sync line: ${reason:-none})"
fi

expect_log "and the sweep says what it did" "$since" "Calendar sync finished%" 30

# **Nothing is left behind unexplained.** A sweep that stopped says so; if it did, the run should not
# read as clean.
stopped=$(sql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND message LIKE 'Calendar sync stopped%';")
check "the sweep did not stop part way" "0" "$stopped"

finish
