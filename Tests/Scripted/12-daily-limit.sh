#!/bin/bash
# The hard daily limit: reaching it stops the clock, and the app then refuses to start it again.
#
# **The archive staged this with a cube on the desk and this stages it without one**, which is the whole reason it
# can run at all today. `Archive/Tests/Bench/15b-hard-daily-limit-checklist.md` needed a paired TimeFlip, seeded a
# total 20 seconds short of the limit, resumed the cube and watched the pause go out over BLE. In manual mode the app
# *is* the clock, so the same crossing is reached by seeding the same 20 seconds and pressing the category on the
# Faces tab -- and the pause the archive watched on the wire is the app closing its own segment.
#
# The three things the archive said made its bench half assertable are kept, because each is still load-bearing:
#
# - **A category made for this run**, so the limit under test is spent by time this script inserted and nothing else.
#   Reusing Break or Meeting would fold in whatever the earlier scripts recorded against them today, and the figure
#   the crossing depends on would differ on every run.
# - **The seeded total sits seconds short**, so the crossing happens while the run is watching rather than at some
#   point in the next hour. Five minutes of limit against roughly 4:40 of recorded time is the whole trick.
#   This script does it three times, from 19, 20 and 21 seconds out: the watch ticks once a second, so 20 is the
#   crossing that lands *on* a tick and the other two fall either side of it. The archive only ever ran the one.
# - **The refusal is exercised through the status item's right half**, not the dropdown item. The item is disabled, so
#   clicking it proves nothing; the right half goes through the same `togglePause` a live one would.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
# What this script checks when everything passes. See `finish` in lib.sh for what a mismatch means.
EXPECTED_CHECKS=34
start "a category spending its daily limit, and the refusal that follows"

LIMIT_MINUTES=5
LIMIT_SECONDS=$(( LIMIT_MINUTES * 60 ))

# **Three categories, crossing from 19, 20 and 21 seconds out**, because the watch ticks once a second and 20 is the
# one that lands *on* a tick. Twenty is therefore the case a fencepost error hides in: at 19 and 21 the crossing falls
# between ticks and is caught by the tick after it whichever way the comparison leans, while at 20 the limit is reached
# at the exact instant the watch looks, and `>=` against `>` is the difference between stopping there and running a
# whole second over. One run at 20 alone could pass on a machine where the tick drifts a few milliseconds late; the
# three together say the boundary is handled rather than missed narrowly.
REMAINING_CASES=(19 20 21)

open_settings

# Creates a category of this run's own, gives it the limit through the Categories tab, and seeds it to within
# `$1` seconds of spending it. Sets STAGED_ID, STAGED_NAME and STAGED_SEEDED; returns 1 if the create failed.
#
# **Three different categories, one per case**, which `next_name` gives for nothing: it reads the highest number
# already in the table and goes one past, so the calls answer Limit 1, Limit 2, Limit 3. Sharing one category would
# fold each crossing's overshoot into the next case's starting total, and the third would start over its limit.
#
# **Answers through globals rather than by printing**, deliberately. `ID=$(stage_category ...)` would run all of this
# in a subshell: the assignments would be lost, and every line `press` and `set_field` write would be captured into
# the id. That is not hypothetical -- it is what a stray `echo` did to `testlog_run_start`, where the run id became
# two lines of text and a whole run recorded nothing.
stage_category() {
    local remaining="$1" name seeded created id zone started ended event

    # **Cleared first, so an early return cannot hand the caller the last staging's category.** These are globals and
    # the returns below leave them alone, so without this a failed staging looks exactly like a successful one that
    # produced the previous id.
    STAGED_ID=""
    STAGED_NAME=""
    STAGED_SEEDED=""

    name=$(next_name Limit)
    # **Created on the Categories tab, not the Faces tab**, which is the one place in this suite that distinction
    # matters. The Faces tab's create starts the clock on what it makes, and this script has to choose the moment
    # timing begins: the budget is seeded to within seconds of the limit, so a clock running from the create would
    # spend that budget during the staging and cross the limit before the wait below had started.
    select_tab Categories
    created=$(mark)
    press create-category
    sleep 0.5
    set_field category-name-field "$name"
    press save-category
    sleep 1
    id=$(dsql "SELECT message FROM debug_log WHERE debug_log_id > $created AND message LIKE '%Save new category%' ORDER BY debug_log_id LIMIT 1;" | sed -E 's/.*category_id ([0-9]+).*/\1/')
    if [ -z "$id" ]; then
        return 1
    fi

    # The limit goes in through the Categories tab, so the value under test is one the app wrote rather than one this
    # script reached around it to insert.
    select_tab Categories
    set_field_focused "category-limit-$id" "$LIMIT_MINUTES"
    press_return
    sleep 1

    # **Seeded straight into the tables, which every other script here is forbidden from doing.** It is right here for
    # the reason `00-setup` gives for its own seeds: recording nearly five minutes by driving the app would mean
    # sitting there for nearly five minutes. What is inserted is an ordinary finished segment and the entry it
    # produced, on one of the app's own faces, so the total the app reads is reached the same way any other total is.
    #
    # **Marked synced**, so the Google sweep has nothing to do with it: a fixture rather than recorded time somebody
    # wants in their calendar.
    seeded=$(( LIMIT_SECONDS - remaining ))
    zone=$(sql "SELECT timezone_id FROM timezone ORDER BY timezone_id LIMIT 1;")
    zone=${zone:-0}
    started=$(( $(date +%s) - seeded - 60 ))
    # **Shifted back until the identity is free.** `(event_number, start_epoch)` is unique and here both are this one
    # number, so two stagings collide whenever the seconds between them happen to equal the difference in their
    # seeded totals -- a collision the wall clock decides rather than the script. It duly happened on run 88
    # (2026-08-23), after a change elsewhere in the suite moved every script about a minute later.
    while [ -n "$(sql "SELECT 1 FROM device_event WHERE event_number = $started AND start_epoch = $started;")" ]; do
        started=$(( started - 1 ))
    done
    ended=$(( started + seeded ))

    sql "INSERT INTO device_event (
             event_number, event_type_id, device_face, start_time, timezone_id,
             start_epoch, duration_seconds, paused, finalised, processed
         ) VALUES (
             $started, 1, 13, strftime('%Y-%m-%dT%H:%M:%S', $started, 'unixepoch', 'localtime'), $zone,
             $started, $seeded, 0, 1, 1
         );"
    event=$(sql "SELECT device_event_id FROM device_event WHERE start_epoch = $started AND event_number = $started;")
    # **The insert is read back before anything is built on it**, because `sql` reports a refused write on stderr and
    # answers nothing on stdout -- so the failure reaches the screen and the script carries on regardless. Run 88
    # spent twelve more lines before reporting the consequence (a category zero seconds into its limit) rather than
    # the cause, which is the shape `CLAUDE.md`'s rule about silent failure exists to stop.
    if [ -z "$event" ]; then
        return 1
    fi

    sql "INSERT INTO time_entry (
             category_id, device_event_id, started_at, start_timezone_id,
             ended_at, end_timezone_id, duration_seconds, synced_to_google_calendar
         ) VALUES (
             $id, $event,
             strftime('%Y-%m-%dT%H:%M:%S', $started, 'unixepoch', 'localtime'), $zone,
             strftime('%Y-%m-%dT%H:%M:%S', $ended, 'unixepoch', 'localtime'), $zone,
             $seeded, 1
         );"

    STAGED_ID="$id"
    STAGED_NAME="$name"
    STAGED_SEEDED="$seeded"
}

# ---------------------------------------------------------------------------- the crossing, from either side of a tick

for remaining in "${REMAINING_CASES[@]}"; do
    STAGED_ID=""
    stage_category "$remaining"
    if [ -z "$STAGED_ID" ]; then
        fail "could not stage a category $remaining seconds short of its limit"
        finish
        exit 1
    fi
    ID="$STAGED_ID"
    NAME="$STAGED_NAME"
    on_tick=""
    [ "$remaining" -eq 20 ] && on_tick=", landing on a tick"
    pass "a category $remaining seconds short of its limit ($NAME, id $ID)$on_tick"

    check "its limit is stored, and it is $STAGED_SEEDED seconds into it" "$LIMIT_MINUTES|$STAGED_SEEDED" \
        "$(sql "SELECT daily_limit FROM category WHERE category_id = $ID;")|$(sql "SELECT CAST(IFNULL(SUM(duration_seconds), 0) AS INTEGER) FROM time_entry WHERE category_id = $ID;")"

    select_tab Faces
    since=$(mark)
    press "category-row-$ID"
    sleep 1.5
    expect_log "picking it starts the clock" "$since" "%$NAME%"

    # Waited on rather than read once: the log row above and the segment behind it are two statements, and the
    # row is written first. See `wait_sql`.
    check "it is running, with $remaining seconds of budget left" "1" \
        "$(wait_sql "1" "SELECT COUNT(*) FROM device_event WHERE finalised = 0;")"

    # **The wait is the test.** Nothing here presses anything: what is being checked is that the app stops itself.
    step "waiting out the last $remaining seconds of the budget..."
    if wait_for "$since" "%Daily limit reached%" $(( remaining + 25 )) >/dev/null; then
        pass "reaching the limit from $remaining seconds out stops the clock, and says so"
    else
        fail "the limit came and went with the clock still running ($remaining seconds out)"
        finish
        exit 1
    fi

    # **The row says the limit was reached; the table says the clock stopped, and they do not land together.**
    # `DailyLimitWatch` records "Daily limit reached" and *then* calls `stopTiming()`, so reading once here is
    # racing that gap -- and on run 29 it lost, on the third of three identical iterations.
    check "the open segment was closed" "0" \
        "$(wait_sql "0" "SELECT COUNT(*) FROM device_event WHERE finalised = 0;")"

    # **How far past the limit it stopped, which is the point of running three.** The tick is once a second and the
    # segment closes on the tick that noticed, so a second of overshoot is expected and more than that is the watch
    # having missed a tick. The 20-second case should be the tightest of the three, the crossing falling where the
    # watch is already looking.
    total=$(sql "SELECT CAST(IFNULL(SUM(duration_seconds), 0) AS INTEGER) FROM time_entry WHERE category_id = $ID;")
    over=$(( ${total:-0} - LIMIT_SECONDS ))
    if [ "${total:-0}" -lt "$LIMIT_SECONDS" ]; then
        fail "it stopped ${total}s in, short of the ${LIMIT_SECONDS}s limit ($remaining seconds out)"
    elif [ "$over" -le 2 ]; then
        pass "and it stopped ${over}s past the limit (${total}s of ${LIMIT_SECONDS}s)"
    else
        fail "it overshot the limit by ${over}s (${total}s of ${LIMIT_SECONDS}s), which is more than a tick"
    fi
done

# Everything below is about the refusal rather than the crossing, and runs against the last of the three, which is
# sitting spent and stopped exactly as the other two were left.

# ---------------------------------------------------------------------------- the menu bar says so
#
# **Red, which is the archive's colour for this** (`MenuBarStatusStyle` drew `overLimit ? .systemRed : .systemGreen`).
# Both halves of it are checked. The spoken label names the limit, which is worth having on its own terms rather than
# as a proxy -- a colour is the whole of the signal on screen, so the one state the item exists to warn about would
# otherwise be the one state it never mentions to somebody who cannot see it -- and the colour itself comes out of
# `debug_log`, the accessibility tree carrying none (see `expect_colours` in lib.sh).

item=$(python3 scripts/ax-dump.py --menu-bar 2>/dev/null | grep -m1 "id=status-item" || true)
check_contains "the status item says the limit is reached" "$item" "daily limit reached"
check_contains "and it still names the category" "$item" "$NAME"
# **The red lands on the figure and the name stays cyan**, which is where this parts from the archive's whole-line
# red: the figure is what reached the number, and the name is only which category it belongs to. Checked as one
# string so a red that spread to the name fails here rather than passing a check that only looked at the figure.
expect_colours "the figure is drawn red, and only the figure" "name cyan, glyph label, figure red"

# ---------------------------------------------------------------------------- the refusal
#
# Three ways to start a clock, and all three have to refuse. The dropdown greys its item, the status item's right half
# routes to nothing, and the Faces tab's glyph greys too -- those are the courtesies. `togglePause` refusing is the
# enforcement behind all of them.

# **The item is greyed, and it still reads Resume.** It says what clicking would do, and it will not do it: a dead
# item claiming something else is on offer would be worse than a dead one telling the truth. The status item is not
# in `AXMenuBar` until its menu is open, so this opens it first (`02` for why).
click_left
sleep 1
menu=$(python3 scripts/ax-dump.py --menu-bar 2>/dev/null)
check_contains "the dropdown's pause control is still there" "$menu" "id=toggle-pause"
resume=$(printf '%s' "$menu" | grep -m1 "id=toggle-pause" || true)
check_contains "it reads Resume" "$resume" "Resume"
check_contains "and it is greyed" "$resume" "disabled"

# Dismissed by choosing Settings, which is what `02` does: a menu left open is modal and every press below it would
# land on nothing.
press open-settings
sleep 1.5

# **The right half, not the menu item.** The item is disabled, so a click on it proves nothing; this is a real click
# on a live target, routed and then refused.
#
# **It is refused at the router, which is why this waits for `ignore` rather than for `Resume refused`.**
# `StatusItemClickRouter` asks the same `ManualTimerRules.isClickable` the other two do and answers `.ignore`, so
# `togglePause` is never reached from this path and never logs. Measured on 2026-08-16: the first run of this script
# asserted the `togglePause` row and failed with the click plainly recorded as ignored. The guard inside
# `togglePause` is still real and still reachable -- the Faces tab's glyph goes through it -- but it is not what a
# click here produces.
#
# The row says `state=paused` because the limit already stopped the clock, so what is being refused is precisely a
# resume, which is the whole claim.
since=$(mark)
click_right
sleep 1.5
expect_log "the status item's right half is a no-op" "$since" "%side=right%state=paused -> ignore%"
check "and nothing started" "0" "$(sql "SELECT COUNT(*) FROM device_event WHERE finalised = 0;")"

# ---------------------------------------------------------------------------- raising the limit lifts it
#
# A deliberate edit is answered immediately, which is what `DailyLimitEnforcement` stores the limit for rather than
# just the fact of it. What comes back is the *ability* to start the clock, not the clock itself: nothing starts
# timing on somebody's behalf while they are elsewhere.
#
# **The raise goes in through the Categories tab, because that is the only place anybody raises one.** Measured
# 2026-08-16, run 15: this is where the feature was actually broken. The refusal was answered from a flag that
# `DailyLimitWatch` only updated on its tick, and the tick stands down the moment a limit stops the clock -- so the
# edit below was written to the table, logged, and then noticed by nothing. The right half went on refusing for the
# rest of the launch. Two things had to change and both are checked here: the refusal is worked out when it is asked,
# and `setDailyLimit` calls `onTimingChanged` so the edit itself redraws the item.

select_tab Categories
set_field_focused "category-limit-$ID" "$((LIMIT_MINUTES * 2))"
press_return
sleep 2

check "the raised limit is stored" "$((LIMIT_MINUTES * 2))" \
    "$(sql "SELECT daily_limit FROM category WHERE category_id = $ID;")"
check "and raising it did not start the clock by itself" "0" \
    "$(sql "SELECT COUNT(*) FROM device_event WHERE finalised = 0;")"

# The menu bar stops saying it, which is the half a user actually sees. Nothing was clicked between the edit and this,
# so what redrew the item is the edit -- there is no tick running to have done it.
item=$(python3 scripts/ax-dump.py --menu-bar 2>/dev/null | grep -m1 "id=status-item" || true)
# Matched with `case` rather than piped into `grep -q`: a status test through a pipe is not reliable under the
# `pipefail` this suite sets, and the shape is kept out of the suite entirely rather than allowed where the
# left-hand side happens to be short enough to get away with it. See `tree_has` in lib.sh.
case "$item" in
    *"daily limit reached"*) fail "the status item still says the limit is reached after it was raised" ;;
    *) pass "the status item stops saying the limit is reached" ;;
esac
# **And the red goes with it.** The colour is worked out per draw from the same answer the refusal is, so a red that
# stayed would mean the item had latched a colour rather than following the state -- which is the fault the whole
# section above is about, seen from the other side.
expect_colours "and the figure goes back to cyan" "name cyan, glyph label, figure cyan"

since=$(mark)
click_right
sleep 1.5
check "the clock can be started again" "1" \
    "$(wait_sql "1" "SELECT COUNT(*) FROM device_event WHERE finalised = 0;")"

# Left as it was found: stopped, so nothing after this is timing against a category this script made.
click_right
sleep 1

finish
