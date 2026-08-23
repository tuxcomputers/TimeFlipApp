#!/bin/bash
# Disconnecting a Google account and connecting it again, with the calendar surviving in between.
#
# **The one check in this suite that needs your hands.** Everything else runs untouched. Signing in goes
# through a browser and a Google consent screen, which a script must not do on somebody's behalf, so the
# run stops and asks before it gets there.
#
# What it is really testing is a deliberate asymmetry in what a disconnect throws away:
#
#   - **The identity goes.** Name and email are cleared, and the refresh token is removed from the
#     Keychain, because a Keychain still able to act on an account the app says it is not connected to is
#     the thing a disconnect is for.
#   - **The calendar stays.** `calendar_id` and `calendar_name` are kept on purpose. Signing out and back
#     in on the same account is the ordinary case, and forgetting the id would make a second calendar
#     beside the first with the recorded history split across the two. The id is *checked* on the way back
#     in rather than trusted, so somebody else signing in finds it does not resolve and gets asked.
#
# The proof that access came back is not a row: it is `Google calendar confirmed`, which the app writes
# only after really fetching the calendar from Google (`settleGoogleCalendar` -> `GoogleCalendarClient.get`).
#
# **If you decline the prompt the app is left signed out**, and every later run's Google checks skip until
# you sign in by hand. The script says so rather than leaving you to find out.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
# What this script checks when everything passes. See `finish` in lib.sh for what a mismatch means.
EXPECTED_CHECKS=17
start "disconnecting Google and connecting again, with the calendar surviving"

open_settings
select_tab App

email=$(sql "SELECT json_extract(setting_value, '\$.email') FROM setting WHERE setting_name = 'google_account';")
before_id=$(sql "SELECT json_extract(setting_value, '\$.calendar_id') FROM setting WHERE setting_name = 'google_account';")
before_name=$(sql "SELECT json_extract(setting_value, '\$.calendar_name') FROM setting WHERE setting_name = 'google_account';")

if [ -z "$email" ]; then
    fail "no Google account is connected, so there is nothing to disconnect"
    finish
    exit $?
fi
if [ -z "$before_id" ]; then
    fail "connected, but no calendar was made, so nothing can survive the disconnect"
    finish
    exit $?
fi

pass "connected as $email, with a calendar to keep ($before_name)"

# ---------------------------------------------------------------------------- disconnecting

# One button for both, titled from the state: "Disconnect" while connected, "Sign in with Google" while
# not. It is one question, so there is one control -- two would be asking it twice.
check_contains "the button offers to disconnect" "$(element app-google-button)" "Disconnect"

since=$(mark)
press app-google-button
sleep 1.5
expect_log "disconnecting is recorded" "$since" "Google account disconnected"

# **REFUSED is in the same log line**, so a disconnect the table would not accept is not read as success.
refused=$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND message LIKE '%disconnected REFUSED%';")
check "and the table accepted it" "0" "$refused"

check "the email is cleared" "" "$(sql "SELECT json_extract(setting_value, '\$.email') FROM setting WHERE setting_name = 'google_account';")"
check_contains "the Status row says so" "$(element app-google-status)" "Not connected"
check_contains "and the button offers to sign in again" "$(element app-google-button)" "Sign in with Google"

# ---- the point of the whole script

check "the calendar id is NOT wiped out" "$before_id" \
    "$(sql "SELECT json_extract(setting_value, '\$.calendar_id') FROM setting WHERE setting_name = 'google_account';")"
check "and neither is its name" "$before_name" \
    "$(sql "SELECT json_extract(setting_value, '\$.calendar_name') FROM setting WHERE setting_name = 'google_account';")"

# ---------------------------------------------------------------------------- connecting again

if ! action_required \
    "Sign in to Google, so the run can check the calendar survived." \
    "1. Press y. Facet opens your browser at Google's sign-in page." \
    "2. Sign in as $email -- the same account, or the calendar will not resolve." \
    "3. Approve the access it asks for, then come back here." \
    "" \
    "The run waits for you and carries on by itself once you are done." \
    "Answering anything else leaves Facet SIGNED OUT, and every later run's" \
    "Google checks will skip until you sign in on the App tab by hand."; then
    fail "the sign-in was declined, so reconnecting is untested"
    echo ""
    red   "  #########################################################################"
    red   "  ##  Facet is left signed out of Google."
    red   "  ##  The calendar id is still stored, so signing in on Settings -> App"
    red   "  ##  will pick the same calendar back up. Until then, 10-google-calendar"
    red   "  ##  skips on every run."
    red   "  #########################################################################"
    echo ""
    finish
    exit 0
fi

since=$(mark)
press app-google-button

# Long, because this is a person in a browser rather than a request. Announced before the wait, so the
# terminal is not silent for two minutes with nothing saying what it is waiting for.
announce "waiting for the sign-in to come back (up to 3 minutes)"
if wait_for_value "SELECT json_extract(setting_value, '\$.email') != '' FROM setting WHERE setting_name = 'google_account';" "1" 180; then
    verdict_pass
else
    verdict_fail "no account was recorded within 3 minutes"
    finish
    exit 1
fi

# **Detected, and then it stops rather than racing on.** Signing in takes the browser to the front and the
# app somewhere behind it, and what happens next is worth watching: the app checks the stored calendar id
# against Google and either confirms it or forgets it. Carrying straight on would have that settled before
# anybody had found the window again.
#
# Nothing is being decided here, so any answer continues. The checks below only read what already
# happened -- the confirmation is looked for from the mark taken before the sign-in, so waiting cannot
# lose it.
wait_for_dev "the sign-in came back" \
    "Facet is connected again as $email." \
    "" \
    "Bring Facet's Settings window to the front if you want to watch what follows:" \
    "it re-checks the stored calendar against Google, and the next checks read" \
    "whether it confirmed the same one or gave up and made another."

check "it is the same account" "$email" \
    "$(sql "SELECT json_extract(setting_value, '\$.email') FROM setting WHERE setting_name = 'google_account';")"
check_contains "and the Status row agrees" "$(element app-google-status)" "Connected"

# ---- still has access to the calendar
#
# **This is a real request to Google, not a row being read.** The app fetches the calendar by its stored id
# on the way back in, which is what proves both that the id still addresses something and that the new
# token can reach it. A stored id that had stopped resolving would take the other branch and be forgotten.

expect_log "the calendar is confirmed against Google" "$since" "Google calendar confirmed,%" 60

check "it is the same calendar, not a new one" "$before_id" \
    "$(sql "SELECT json_extract(setting_value, '\$.calendar_id') FROM setting WHERE setting_name = 'google_account';")"
check "under the name it had before" "$before_name" \
    "$(sql "SELECT json_extract(setting_value, '\$.calendar_name') FROM setting WHERE setting_name = 'google_account';")"
check_contains "and the Calendar row shows it" "$(element app-google-calendar)" "$before_name"

# Nothing was made. A sign-in that could not resolve the stored id makes a fresh calendar instead, which is
# correct behaviour and the wrong outcome here -- and it is the failure this whole script exists to catch.
made=$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND message LIKE 'Google calendar created%';")
check "no second calendar was made" "0" "$made"

finish
