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
# What this script checks when everything passes. See `finish` in lib.sh for what a mismatch means.
EXPECTED_CHECKS=44
start "every row on the App tab, written and read back"

open_settings
select_tab App


# ---------------------------------------------------------------------------- the switch
#
# Pressed twice, so whichever way it started it ends where it began.
#
# **One switch, where there were two.** Pause the device when locking it moved to the Device tab, above
# Auto-pause, and is checked there in `13-device-tab`. The loop is kept for the one that is left, since a
# second switch on this tab is a row away rather than a rewrite.

for pair in "app-show-seconds display_seconds enabled"; do
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

# **And the two rows that left are gone rather than drawn on both tabs.** A row still on the App tab as well as on
# the Device tab would be two controls answering one question, which is exactly the fault the first rule in
# `CLAUDE.md` is about -- and the two would be found disagreeing at the next lock, or at the next reading, rather
# than on screen. Checked as absences because that is what changed; `13-device-tab` checks where they went.
check "the lock switch is not on this tab any more" "0" "$(on_tab app-pause-on-lock)"
check "nor the battery warning, which went with it" "0" "$(on_tab app-battery-warning)"

# ---------------------------------------------------------------------------- the numbers
#
# The stepper's arrows rather than the field, since the arrows are what a person uses and the field is
# checked by reading the row back afterwards anyway. Each goes up once and down once.

for quad in \
    "app-daily-reset daily_reset_time hour" \
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
# settings drawn above it. Nothing looks wrong on screen, which is why it survived until a script
# dumped the tree.
#
# **Five settings now, not six**, the lock row having moved to the Device tab. What is being read is the
# order of the two section headings, which that did not touch.
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

# ---------------------------------------------------------------------------- the Debug section
#
# **The one section on this tab that is built folded.** The two above it are what somebody opens the tab
# to change; this one carries the trace, which is of no interest until something needs looking into.
#
# **Its rows are the `debug` row's two fields**: the switch, and the folder `debug.sqlite` is kept in --
# which is the folder a user is pointed at when they are asked to send the trace in.

check_contains "the Debug section is on the tab" "$(tree)" "id=app-debug-section"
# Read off the contents, as the two above are: a section with its rows showing is what open means.
check "it starts folded, where the other two start open" "0" "$(on_tab app-debug-enabled)"

since=$(mark)
press app-debug-section-heading-button
sleep 1
expect_log "pressing the Debug heading opens it" "$since" "App section app-debug-section opened"
check "and its rows come with it" "1" "$(on_tab app-debug-enabled)"

# **This is the one check in the suite that can blind the suite**, so it is trapped before it is made.
# Every check in every script after this one polls `debug_log`, and pressing this switch stops the app
# writing rows at that moment -- so a failure between the press that turns it off and the press that puts
# it back would leave the rest of the run reading a trace nothing is adding to, and reporting it as the
# app being broken.
#
# **The way back is the control, not the table.** A row written by sqlite under a running app tells the
# app nothing (`DebugLog.isRecording` is told by the Settings window, and otherwise read at launch), so
# the trap presses the switch, and only falls back to writing the row and quitting the app -- which makes
# the next launch read it -- when the press did not take.
restore_debug_logging() {
    [ "$(setting debug enabled)" = "1" ] && return 0
    press app-debug-enabled
    sleep 1
    [ "$(setting debug enabled)" = "1" ] && { step "debug logging has been switched back on"; return 0; }
    sql "UPDATE setting SET setting_value = json_set(setting_value, '\$.enabled', json('true')) \
        WHERE setting_name = 'debug';"
    quit_app
    if [ "$(setting debug enabled)" = "1" ]; then
        step "debug logging was written back on; the app was quit so the next launch reads it"
        return 0
    fi
    yellow "##############################################################################"
    yellow "##"
    yellow "##  DEBUG LOGGING IS STILL OFF"
    yellow "##"
    yellow "##  Every script after this one polls debug_log and will find nothing, which"
    yellow "##  reads as the app being broken. Turn it back on before running any more:"
    yellow "##    Settings > App > Debug > Debug logging"
    yellow "##"
    yellow "##############################################################################"
    echo ""
}
trap restore_debug_logging EXIT INT TERM

# Pressed twice, as every other row on this tab is, so it ends where it began. What is being checked is
# the write reaching the table and coming back, and then the thing that write is for: the logging itself
# stopping and starting as the switch moves.
was=$(setting debug enabled)
since=$(mark)
press app-debug-enabled
sleep 1
now=$(setting debug enabled)
if [ "$now" != "$was" ] && [ -n "$now" ]; then
    pass "the switch writes debug.enabled ($was -> $now)"
else
    fail "debug.enabled still reads '$now' after the switch was pressed"
fi
# **Written while it was still recording**, which is the order `SettingsWindowController.store` takes: the
# row goes down, and only then is the logger told to stop. A trace that stopped before saying why would be
# missing the one line explaining its own end.
# **The trailing `%` is the whole of it, and it is not decoration.** `wait_for` matches with
# `message LIKE '$pattern'` and adds no wildcards of its own, so a pattern that stops where the message
# carries on cannot match: the row reads `App setting debug.enabled -> flag(false)`. Run 156 failed here
# with that row sitting in the table 170ms after the mark, exactly the shape `wait_for`'s own comment
# describes for an unescaped apostrophe -- a confident verdict pointing at the app for a fault in the
# check. Every other pattern in this suite carries its own `%`; this one did not.
expect_log "and the write is recorded" "$since" "App setting debug.enabled ->%"
expect_log "and the trace says it is stopping" "$since" "Logging turned off"

# **The switch is live, and this is what says so.** With logging off, a gesture that always writes a row
# writes none: the folds above proved `App section % folded` arrives within a second, so a second of
# silence here is the logger being off rather than the press being missed.
silent=$(mark)
press app-debug-section-heading-button
sleep 2
press app-debug-section-heading-button
sleep 2
check "with logging off, nothing is recorded at all" "0" \
    "$(dsql "SELECT count(*) FROM debug_log WHERE debug_log_id > $silent;")"

since=$(mark)
press app-debug-enabled
sleep 1
check "and pressing it again puts it back" "$was" "$(setting debug enabled)"
# **The first row of the resumed trace.** The write that turned it back on was itself not recorded -- the
# logger was still off when `store` wrote the row -- so this line is what says the trace resumes here.
expect_log "and the trace starts again at that moment" "$since" "Logging turned on"

# **Present, and deliberately not pressed.** Reveal in Finder brings the Finder to the front and Save a
# copy puts a save panel up, and both take the keyboard away from the app every remaining step of this run
# is addressing. What they do is covered hermetically instead (`DebugLogTests`, `AppSettingsPaneTests`);
# what only a running app can say is that the row is there and its buttons are alive.
check "the Trace file row offers Reveal in Finder" "1" "$(on_tab app-debug-reveal)"
check "and a copy of the trace to send in" "1" "$(on_tab app-debug-copy)"
# **Clear least of all.** It empties the very trace every check after this one polls, so pressing it here would end
# the run rather than test anything. What it does is covered in `DebugLogTests`.
check "and a way to empty it" "1" "$(on_tab app-debug-clear)"

# **The folder is read off the row and compared with the table**, rather than against a path written here.
# A check naming the folder itself would fail on any machine that had chosen a different one, which is
# exactly the thing the row exists to let somebody do.
folder=$(element app-debug-directory | sed -n 's/.*value=\(.*\)$/\1/p')
check "the Directory row names the folder the table holds" "$(setting debug directory)" "$folder"

# **Left folded, as it was found**, which is what the window would put it back to on the next open anyway.
press app-debug-section-heading-button
sleep 1
check "the Debug section is folded again" "0" "$(on_tab app-debug-enabled)"

# **Left as they were found.** Both sections open, which is what the next script expects and what the
# window would put them back to anyway on the next open.
check "the App settings section is open again" "1" "$(on_tab app-show-seconds)"
check "and the Google section is too" "1" "$(on_tab app-google-status)"

finish
