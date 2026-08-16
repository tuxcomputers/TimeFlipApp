#!/bin/bash
# The Settings window: its five tabs, moving between them, closing it -- and then making the calendar this
# run will fill.
#
# **The calendar is set up here because of when this script runs, not because it belongs to this window.**
# Recording an entry sweeps every unsynced row into whatever calendar the app holds, so a calendar
# replaced later would be replaced after several scripts had already filled the old one -- and deleting it
# would throw away the events somebody would want to look at afterwards. This is the first script with the
# window open and the last before anything is recorded, which makes it the only place that works.
#
# **The tabs carry no `AXIdentifier`.** A Settings tab button has to be matched on its description
# instead, which is Archive/Tests/Methods.md Method 10's finding from the previous app and is still true
# of this one. `select_tab` is that, in one place, so no script rediscovers it as a regression.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
start "the Settings window, its tabs, and the calendar this run will fill"

open_settings
check "the window is open" "yes" "$(settings_is_open && echo yes || echo no)"

# **Off Faces first.** The tab view's delegate does not fire for a tab that is already selected, and the
# window always opens on Faces, so a loop starting there would wait for a row that is never written --
# which is not the app failing but the script asking for the wrong evidence. `SettingsWindowController`
# says as much where it logs the open.
select_tab Device

# Every tab, in the order they sit in the window. Each one is selected and then checked twice: the app
# said it selected it, and the pane it names is actually in the tree. The first alone would pass on a
# tab that logged the change and drew nothing.
for tab in Faces Categories Report App Device; do
    since=$(mark)
    select_tab "$tab"
    expect_log "the $tab tab can be selected" "$since" "Settings tab selected: $tab"

    pane=$(python3 scripts/ax-dump.py 2>/dev/null | grep -c "id=settings-pane-$(echo "$tab" | tr '[:upper:]' '[:lower:]')" || true)
    if [ "${pane:-0}" -gt 0 ]; then
        pass "the $tab pane is on screen"
    else
        fail "the $tab tab was selected but its pane is not in the tree"
    fi
done

# ---------------------------------------------------------------------------- coming back

# Closing and reopening re-reads everything rather than showing what the last open loaded, which is the
# first rule in CLAUDE.md applied to this window. What is checked here is the cheaper half of it: that
# the window goes away and comes back at all.
since=$(mark)
close_settings
expect_log "the Close button is recorded" "$since" "Button clicked: Close (Settings window)"
check "the window is gone" "no" "$(settings_is_open && echo yes || echo no)"

open_settings
check "it opens again" "yes" "$(settings_is_open && echo yes || echo no)"

# **It always opens on Faces**, whatever was showing when it was closed, which is deliberate: what is
# being timed is what somebody opening this window most often wants, and a window that reopened on the
# Device tab because that is where they last were would bury it. The row is written by the open itself
# rather than by the tab view, precisely because selecting an already-selected tab fires nothing.
opened=$(sql "SELECT message FROM debug_log WHERE message LIKE 'Settings opened on %' ORDER BY debug_log_id DESC LIMIT 1;")
check_contains "it opens on Faces however it was left" "$opened" "Faces"

# ============================================================================ the run's calendar
#
# **Here, before anything records a single entry, and that is the whole reason it is in this script.**
# Recording an entry sweeps every unsynced row into whatever calendar the app currently holds. So a
# calendar replaced later in the run is replaced *after* several scripts have already filled the old one,
# and deleting it throws away the very events somebody would want to look at afterwards. Doing it first
# means every event the run produces lands in the calendar the run made, and it is all still there at the
# end.
#
# It has nothing to do with the Settings window as such. It is here because this is the first script with
# the window open and the last one before anything is recorded, and that ordering is the requirement.
#
# **A fresh calendar every run.** Google keeps a deleted *event* for ever as `cancelled` and will not
# reissue its id, while Facet derives event ids from `time_entry_id`, which a rebuilt database restarts at
# 1. Reusing a calendar means every run after the first colliding with its predecessor's ids and syncing
# nothing. A calendar made a moment ago has none of them.
#
# **The app does the deleting.** This was a Python script that read the refresh token out of the login
# Keychain with the `security` tool -- a different program from the one that owns the item, so macOS asked
# permission, and every run that signed in again created a fresh item and asked once more.

select_tab App

email=$(sql "SELECT json_extract(setting_value, '\$.email') FROM setting WHERE setting_name = 'google_account';")
if [ -z "$email" ]; then
    skip "no Google account is connected, so there is no calendar to set up"
    skip "connect one on Settings -> App; 10 explains what that turns on"
    finish
    exit 0
fi

stored_name() { sql "SELECT json_extract(setting_value, '\$.calendar_name') FROM setting WHERE setting_name = 'google_account';"; }
stored_id() { sql "SELECT json_extract(setting_value, '\$.calendar_id') FROM setting WHERE setting_name = 'google_account';"; }

# ---- last run's, deleted

if [ -n "$(stored_id)" ]; then
    doomed=$(stored_name)
    since=$(mark)
    press app-google-calendar-delete
    sleep 1

    # **The order is what is on screen, left to right, not the order the buttons were added.** AppKit puts
    # a button titled "Cancel" on the left whichever way round it went in, so the destructive one reads
    # first. That is also why the app sets the alert's key equivalents explicitly instead of trusting
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

# ---- this run's, made and named

since=$(mark)
press app-google-calendar-create
expect_log "Create makes one" "$since" "Google calendar created,%" 45
if [ -z "$(stored_id)" ]; then
    fail "no calendar id was recorded, so nothing recorded today has anywhere to go"
    finish
    exit 1
fi
check "and it is called Facet, the name the app makes them under" "Facet" "$(stored_name)"

# Renamed here too, so everything the run writes lands in a calendar already carrying the test name.
# **A real rename, at Google**: the row is written from what Google answers rather than from what was
# typed, so a name that only changed inside Facet fails here rather than looking like a pass.
WANTED="Facet-test"
made=$(stored_id)
since=$(mark)
press app-google-calendar
wait_for_element app-google-calendar-field 5
set_field_focused app-google-calendar-field "$WANTED"
press_return
expect_log "renaming it goes to Google" "$since" "Google calendar renamed to $WANTED" 45
check "the row records the new name" "$WANTED" "$(stored_name)"
check_contains "and the Calendar row shows it" "$(element app-google-calendar)" "$WANTED"

# **The name is a label and the id is the identity.** A rename that moved to a different calendar would
# leave every event already written behind, under a calendar nothing points at any more.
check "the rename did not change which calendar it is" "$made" "$(stored_id)"

finish
