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

# ---------------------------------------------------------------------------- deleting last run's calendar
#
# **A fresh calendar every run, and the app is what makes it fresh.** Google keeps a deleted *event* for
# ever as `cancelled` and will not reissue its id, while Facet derives event ids from `time_entry_id`,
# which a rebuilt database restarts at 1. Reusing a calendar therefore means every run after the first
# colliding with its predecessor's ids and syncing nothing. A calendar made a moment ago has none of them.
#
# **Done here rather than in 00, and by the app rather than by a script.** This used to be a Python script
# that read the refresh token out of the login Keychain with the `security` tool -- a different program
# from the one that owns the item, so macOS asked permission, and every run that signed in again created a
# fresh item and asked once more. The app already holds that token and never has to ask. So the whole
# lifecycle is one script driving one window: delete the old, make a new one, name it.
#
# The seed put last run's calendar id back, so there is one to delete unless this is the first run ever.

stored_name() { sql "SELECT json_extract(setting_value, '\$.calendar_name') FROM setting WHERE setting_name = 'google_account';"; }
stored_id() { sql "SELECT json_extract(setting_value, '\$.calendar_id') FROM setting WHERE setting_name = 'google_account';"; }

if [ -n "$calendar_id" ]; then
    doomed=$(stored_name)
    since=$(mark)
    press app-google-calendar-delete
    sleep 1

    # It asks before destroying anything, and names what goes.
    #
    # **The order is what is on screen, left to right, not the order the buttons were added.** AppKit puts a
    # button titled "Cancel" on the left whichever way round it went in, so the destructive one reads first
    # here. That is also why the app sets the alert's key equivalents explicitly instead of trusting
    # position to keep Return harmless: the rightmost button is the one Return activates, and left to
    # itself that would have been Delete Calendar.
    check "deleting asks first, and offers a way out" "Delete Calendar|Cancel" "$(alert_buttons)"
    check_contains "and the question names the calendar" \
        "$(python3 scripts/ax-alert.py --message 2>/dev/null)" "$doomed"

    press_title "Delete Calendar"
    expect_log "confirming deletes it at Google" "$since" "Google calendar deleted,%" 45

    # **Forgotten only once Google has taken it.** A row cleared before the request would leave the app
    # unable to name what it failed to delete.
    check "and the app no longer holds a calendar" "|" "$(stored_id)|$(stored_name)"
    check_contains "the Calendar row offers to make another" "$(tree)" "id=app-google-calendar-create"
else
    skip "no calendar is stored, so there is none to delete (the first run on this machine)"
fi

# ---------------------------------------------------------------------------- making a new one

since=$(mark)
press app-google-calendar-create
expect_log "Create makes one" "$since" "Google calendar created,%" 45
calendar_id=$(stored_id)
if [ -z "$calendar_id" ]; then
    fail "no calendar id was recorded, so there is nothing to sync into"
    finish
    exit 1
fi

# Made under the app's own default. The rename below is what turns it into the test one, and it can only
# be asserted because this is known.
check "and it is called Facet, the name the app makes them under" "Facet" "$(stored_name)"
check_contains "the Calendar row shows its name" "$(element app-google-calendar)" "$(stored_name)"

# ---------------------------------------------------------------------------- renaming it
#
# **The rename is a real one, at Google.** The row is written from what Google answers rather than from
# what was typed, so a name that only changed inside Facet would fail here rather than look like a pass.
#
# The same cell a category name uses: click the name, it becomes a field, Return commits.

WANTED="Facet-test"

since=$(mark)
press app-google-calendar
wait_for_element app-google-calendar-field 5
set_field_focused app-google-calendar-field "$WANTED"
press_return
expect_log "renaming the calendar goes to Google" "$since" "Google calendar renamed to $WANTED" 45
check "the row records the new name" "$WANTED" "$(stored_name)"
check_contains "and the Calendar row shows it" "$(element app-google-calendar)" "$WANTED"

# **The name is a label and the id is the identity.** A rename that moved to a different calendar would
# leave every event already written behind, under a calendar nothing points at any more.
check "the rename did not change which calendar it is" "$calendar_id" "$(stored_id)"

# ---------------------------------------------------------------------------- an entry reaching it
#
# Recording an entry sweeps every row still at 0, so this both makes one and watches the sweep carry it.
# The event is created and then read back and checked before the row is ticked, which is what the tick
# means -- so a pass here is "the event is at Google and is right", not "a request returned 200".

select_tab Faces
NAME=$(next_name Sync)
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
