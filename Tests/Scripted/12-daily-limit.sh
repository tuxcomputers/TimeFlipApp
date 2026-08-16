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
# - **The seeded total sits 20 seconds short**, so the crossing happens while the run is watching rather than at some
#   point in the next hour. Five minutes of limit against 4:40 of recorded time is the whole trick.
# - **The refusal is exercised through the status item's right half**, not the dropdown item. The item is disabled, so
#   clicking it proves nothing; the right half goes through the same `togglePause` a live one would.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
start "a category spending its daily limit, and the refusal that follows"

LIMIT_MINUTES=5
# Twenty seconds short of the limit, in seconds.
SEEDED=$(( LIMIT_MINUTES * 60 - 20 ))

open_settings
select_tab Faces

# ---------------------------------------------------------------------------- a category of this run's own

NAME=$(next_name Limit)
since=$(mark)
press create-category
sleep 0.5
set_field category-name-field "$NAME"
press save-category
sleep 1
ID=$(sql "SELECT message FROM debug_log WHERE debug_log_id > $since AND message LIKE '%Save new category%' ORDER BY debug_log_id LIMIT 1;" | sed -E 's/.*category_id ([0-9]+).*/\1/')
if [ -z "$ID" ]; then
    fail "could not create a category to spend a limit against"
    finish
    exit 1
fi
pass "a category of this run's own ($NAME, id $ID)"

# The limit goes in through the Categories tab, so the value under test is one the app wrote rather than one this
# script reached around it to insert.
select_tab Categories
set_field_focused "category-limit-$ID" "$LIMIT_MINUTES"
press_return
sleep 1
check "the daily limit is stored" "$LIMIT_MINUTES" \
    "$(sql "SELECT daily_limit FROM category WHERE category_id = $ID;")"

# ---------------------------------------------------------------------------- 20 seconds short of it
#
# **Seeded straight into the tables, which every other script here is forbidden from doing.** It is right here for
# the reason `00-setup` gives for its own seeds: recording 4 minutes 40 by driving the app would mean sitting there
# for 4 minutes 40. What is inserted is an ordinary finished segment and the entry it produced, on one of the app's
# own faces, so the total the app reads is reached the same way any other total is.

zone=$(sql "SELECT timezone_id FROM timezone ORDER BY timezone_id LIMIT 1;")
zone=${zone:-0}
started=$(( $(date +%s) - SEEDED - 60 ))
ended=$(( started + SEEDED ))

sql "INSERT INTO device_event (
         event_number, event_type_id, device_face, start_time, timezone_id,
         start_epoch, duration_seconds, paused, finalised, processed
     ) VALUES (
         $started, 1, 13, strftime('%Y-%m-%dT%H:%M:%S', $started, 'unixepoch', 'localtime'), $zone,
         $started, $SEEDED, 0, 1, 1
     );"
event=$(sql "SELECT device_event_id FROM device_event WHERE start_epoch = $started AND event_number = $started;")

sql "INSERT INTO time_entry (
         category_id, device_event_id, started_at, start_timezone_id,
         ended_at, end_timezone_id, duration_seconds, synced_to_google_calendar
     ) VALUES (
         $ID, $event,
         strftime('%Y-%m-%dT%H:%M:%S', $started, 'unixepoch', 'localtime'), $zone,
         strftime('%Y-%m-%dT%H:%M:%S', $ended, 'unixepoch', 'localtime'), $zone,
         $SEEDED, 1
     );"

check "the category is $SEEDED seconds into a $((LIMIT_MINUTES * 60)) second budget" "$SEEDED" \
    "$(sql "SELECT CAST(IFNULL(SUM(duration_seconds), 0) AS INTEGER) FROM time_entry WHERE category_id = $ID;")"

# **Marked synced**, so the Google sweep has nothing to do with it. A seeded entry is a fixture rather than recorded
# time somebody wants in their calendar.

# ---------------------------------------------------------------------------- the crossing

select_tab Faces
since=$(mark)
press "category-row-$ID"
sleep 1.5
expect_log "picking it starts the clock" "$since" "%\"$NAME\"%"

check "it is running, with 20 seconds of budget left" "1" \
    "$(sql "SELECT COUNT(*) FROM device_event WHERE finalised = 0;")"

# **The wait is the test.** Twenty seconds of budget, plus a few for the watch's own tick and the write behind it.
# Nothing here presses anything: what is being checked is that the app stops itself.
grey "  waiting out the last 20 seconds of the budget..."
if wait_for "$since" "%Daily limit reached%" 45 >/dev/null; then
    pass "reaching the limit stops the clock, and says so"
else
    fail "the limit came and went with the clock still running"
    finish
    exit 1
fi

check "the open segment was closed" "0" "$(sql "SELECT COUNT(*) FROM device_event WHERE finalised = 0;")"

# The figure it stopped on. Not asserted to the second: the tick is once a second and the segment closes on the
# tick that noticed, so the total lands at or just past the limit rather than exactly on it.
total=$(sql "SELECT CAST(IFNULL(SUM(duration_seconds), 0) AS INTEGER) FROM time_entry WHERE category_id = $ID;")
if [ "${total:-0}" -ge "$((LIMIT_MINUTES * 60))" ]; then
    pass "and it stopped at or just past the limit (${total}s of $((LIMIT_MINUTES * 60))s)"
else
    fail "it stopped ${total}s in, short of the $((LIMIT_MINUTES * 60))s limit"
fi

# ---------------------------------------------------------------------------- the menu bar says so
#
# **Red, which is the archive's colour for this** (`MenuBarStatusStyle` drew `overLimit ? .systemRed : .systemGreen`).
# The accessibility tree carries no colour, so what is checked is the other half of the same change: the item's spoken
# label names the limit. That is worth having on its own terms rather than as a proxy -- a colour is the whole of the
# signal on screen, so the one state the item exists to warn about would otherwise be the one state it never mentions
# to somebody who cannot see it.

item=$(python3 scripts/ax-dump.py --menu-bar 2>/dev/null | grep -m1 "id=status-item" || true)
check_contains "the status item says the limit is reached" "$item" "daily limit reached"
check_contains "and it still names the category" "$item" "$NAME"

# ---------------------------------------------------------------------------- the refusal
#
# Three ways to start a clock, and all three have to refuse. The dropdown greys its item, the status item's right half
# routes to nothing, and the Faces tab's glyph greys too -- those are the courtesies. `togglePause` refusing is the
# enforcement behind all of them.

# **The item is greyed, and it still reads Resume.** It says what clicking would do, and it will not do it: a dead
# item claiming something else is on offer would be worse than a dead one telling the truth. The status item is not
# in `AXMenuBar` until its menu is open, so this opens it first (`02` for why).
python3 scripts/status-item-click.py >/dev/null 2>&1
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
python3 scripts/status-item-click.py --right >/dev/null 2>&1
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
if printf '%s' "$item" | grep -q "daily limit reached"; then
    fail "the status item still says the limit is reached after it was raised"
else
    pass "the status item stops saying the limit is reached"
fi

since=$(mark)
python3 scripts/status-item-click.py --right >/dev/null 2>&1
sleep 1.5
check "the clock can be started again" "1" "$(sql "SELECT COUNT(*) FROM device_event WHERE finalised = 0;")"

# Left as it was found: stopped, so nothing after this is timing against a category this script made.
python3 scripts/status-item-click.py --right >/dev/null 2>&1
sleep 1

finish
