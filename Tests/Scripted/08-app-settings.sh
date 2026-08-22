#!/bin/bash
# The App tab: every row written to the table, and put back again.
#
# **Each setting is changed and then changed back**, and both directions are checked. That is not tidying
# up: a one-way change would leave the next script running against a different `blip_time` or a different
# fetch interval, and the second half proves the control works in both directions rather than only
# happening to move the way the first press pushed it.
#
# What is being checked is the write reaching the table. The window writes straight through and reads
# back before it believes anything (`SettingStore.write`), so a row that did not change means the control
# is lying about what it did.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
start "every row on the App tab, written and read back"

open_settings
select_tab App

setting() { sql "SELECT json_extract(setting_value, '\$.$2') FROM setting WHERE setting_name = '$1';"; }

# ---------------------------------------------------------------------------- the two switches
#
# Each is pressed twice, so whichever way it started it ends where it began.

for pair in "app-show-seconds display_seconds enabled" "app-pause-on-lock pause_on_lock enabled"; do
    set -- $pair
    control="$1" row="$2" field="$3"

    was=$(setting "$row" "$field")
    since=$(mark)
    press "$control"
    sleep 1
    now=$(setting "$row" "$field")
    if [ "$now" != "$was" ]; then
        pass "$control changes $row ($was -> $now)"
    else
        fail "$control left $row at '$was'"
    fi

    press "$control"
    sleep 1
    check "$control puts $row back" "$was" "$(setting "$row" "$field")"
done

# ---------------------------------------------------------------------------- the four numbers
#
# The stepper's arrows rather than the field, since the arrows are what a person uses and the field is
# checked by reading the row back afterwards anyway. Each goes up once and down once.

for quad in \
    "app-daily-reset daily_reset_time hour" \
    "app-battery-warning low_battery_level percent" \
    "app-blip-time blip_time seconds"
do
    set -- $quad
    control="$1" row="$2" field="$3"

    was=$(setting "$row" "$field")
    press "$control-up"
    sleep 1
    up=$(setting "$row" "$field")
    if [ "$up" != "$was" ]; then
        pass "$control steps $row up ($was -> $up)"
    else
        fail "$control-up left $row at '$was'"
    fi

    press "$control-down"
    sleep 1
    check "$control steps $row back down" "$was" "$(setting "$row" "$field")"
done

# ---------------------------------------------------------------------------- the odd one out
#
# **The interval is stored in seconds and stepped in whole minutes**, so it does not simply go back. The
# seeded value is 10 seconds, deliberately below the one-minute floor the control offers: a developer's
# value for making history arrive quickly, which `AppSettingsRules.fetchIntervalMinutes` floors to 1 for
# display. One press up is therefore 2 minutes, and one press down is 1 minute, not the 10 seconds it
# started at -- the control cannot express the value it was showing.
#
# So this checks what actually happens rather than what would be tidy, and puts the row back afterwards.

was=$(setting fetch_history_interval_seconds seconds)
press app-fetch-interval-up
sleep 1
up=$(setting fetch_history_interval_seconds seconds)
press app-fetch-interval-down
sleep 1
down=$(setting fetch_history_interval_seconds seconds)

if [ "$up" != "$down" ] && [ "$((up - down))" = "60" ]; then
    pass "app-fetch-interval steps whole minutes (${was}s -> ${up}s -> ${down}s)"
else
    fail "app-fetch-interval did not step a minute (${was}s -> ${up}s -> ${down}s)"
fi

# Put back by hand, since the control cannot reach a sub-minute value. Written straight to the table,
# which is the one thing in this folder that goes behind the app's back -- and it is safe here precisely
# because the app re-reads this setting on every tick rather than holding it.
if [ "$was" != "$down" ]; then
    sql "UPDATE setting SET setting_value = json_set(setting_value, '\$.seconds', $was) WHERE setting_name = 'fetch_history_interval_seconds';"
    check "the developer's ${was}s interval is restored" "$was" "$(setting fetch_history_interval_seconds seconds)"
fi

# ---------------------------------------------------------------------------- what the row means
#
# The App tab shows a 12-hour face; the table stores 24-hour. A stepper that wrote what the field showed
# would put a 3 in the row for 3 PM as well as for 3 AM, which is the kind of fault nothing notices until
# a day rolls over at the wrong time.
hour=$(setting daily_reset_time hour)
if [ "${hour:-99}" -ge 0 ] && [ "${hour:-99}" -le 23 ]; then
    pass "the stored reset hour is on a 24-hour clock ($hour)"
else
    fail "daily_reset_time holds '$hour', which is not an hour of the day"
fi

# The minute is not on this tab at all, and a write of the hour must not drop it: one row holds the whole
# object, so a write that only knew about the hour would take the minute with it.
minute=$(setting daily_reset_time minute)
if [ -n "$minute" ]; then
    pass "and the minute beside it survived the writes ($minute)"
else
    fail "daily_reset_time has lost its minute, so a write replaced the object instead of one field"
fi

# ---------------------------------------------------------------------------- the order it reads in
#
# **Subview order is what accessibility reads, and it is not the constraints.** The Google section sits at
# the bottom of the tab, and it was being added to the view first, so VoiceOver announced it before the
# six settings drawn above it. Nothing looks wrong on screen, which is why it survived until a script
# dumped the tree.
order=$(tree | grep -n "section-heading" | head -2)
first=$(printf '%s' "$order" | head -1)
check_contains "the tab reads in the order it is drawn: App settings first" "$first" "app-settings-section-heading"

# ---------------------------------------------------------------------------- the sections fold
#
# **Both start open**, which is not the Categories tab's answer and is the right one here: these two
# sections are the whole of the tab, so opening it folded would show two headings and nothing to change.
#
# **Pressed on the heading button rather than the triangle**, because the whole line is the target and
# that is the half `swift test` cannot check: `performClick` presses a button directly, so a hermetic
# test passes on a control no mouse can reach. This has already shipped broken once, on the Categories
# headings (`Tests/Methods.md`).

check_contains "the App settings section is on the tab" "$(tree)" "id=app-settings-section"
check_contains "and the Google section is too" "$(tree)" "id=app-google-section"

# Read off the contents rather than off the heading: a section with its rows showing is what open means.
check "the App settings section starts open" "1" "$(on_tab app-show-seconds)"
check "the Google section starts open" "1" "$(on_tab app-google-status)"

for pair in "app-settings-section app-show-seconds" "app-google-section app-google-status"; do
    set -- $pair
    section="$1" inside="$2"

    since=$(mark)
    press "$section-heading-button"
    sleep 1
    expect_log "pressing the $section heading folds it" "$since" "App section $section folded"
    check "and its contents go with it" "0" "$(on_tab "$inside")"

    since=$(mark)
    press "$section-heading-button"
    sleep 1
    expect_log "pressing it again opens it" "$since" "App section $section opened"
    check "and its contents come back" "1" "$(on_tab "$inside")"
done

# **The footnote goes with the section it explains.** It says why the Google button cannot be pressed, so
# leaving it under a folded section would be an explanation of something no longer on screen. It sits
# outside the panel and so cannot fold with it, which is why it hangs off the fold's state rather than
# off the press (`PanelSection.onExpandedChanged`).
#
# **What the note says is read off the tab rather than assumed, because whether there is one at all
# depends on the account.** `GoogleAccountRules.note` answers nothing for a connected account, and this
# suite connects one in `10-google-calendar` -- so a check hard-coding "there is a note" passes or fails
# on which scripts have run before it rather than on anything about folding. Captured here, the check is
# the same either way: whatever the account state puts there, folding takes away and opening puts back.
note_before=$(on_tab app-google-note)

press app-google-section-heading-button
sleep 1
check "folding Google takes its note with it, whether or not there is one" "0" \
    "$(on_tab app-google-note)"

press app-google-section-heading-button
sleep 1
check "and opening it puts back exactly what the account state says" "$note_before" \
    "$(on_tab app-google-note)"

# **Left as they were found.** Both sections open, which is what the next script expects and what the
# window would put them back to anyway on the next open.
check "the App settings section is open again" "1" "$(on_tab app-show-seconds)"
check "and the Google section is too" "1" "$(on_tab app-google-status)"

finish
