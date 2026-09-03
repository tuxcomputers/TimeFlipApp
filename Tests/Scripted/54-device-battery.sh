#!/bin/bash
# The cube's charge: read once on connecting, then pushed, and drawn as one steady figure.
#
# **What needs a real cube here is the traffic, not the arithmetic.** Which figure a run of readings should show is
# `BatteryRules`, and it is pinned in `Tests/FacetAppTests/BatteryRulesTests.swift` with no radio in sight. What cannot
# be tested there is that the cube is asked at all, that it answers, and that it then goes on volunteering values
# nobody asked for -- which is the whole reason this feature is a read *and* a subscription rather than either one.
#
# **The warning itself is deliberately not here, and that is the archive's finding rather than a gap.** Its
# `07b-battery-low-indicator-checklist` says why: arming the warning needs the charge at or below `low_battery_level`,
# the field will not take a level above 20%, and a healthy cube sits near 100 -- so on real hardware there is no way
# to reach the state without draining the batteries. The archive moved that whole claim into a mock sequence for
# exactly this reason; here it is `LowBatteryWatchTests`, which drives the latch, the recovery margin, the flash and a
# threshold changed underneath it.
#
# **Runs late, and after `53`.** It needs a live link, and it reads what the connection has logged since it came up.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
# What this script checks when everything passes. See `finish` in lib.sh for what a mismatch means.
EXPECTED_CHECKS=12
start "the charge: pulled on connecting, pushed after that, and shown without flapping"

# **No cube check here.** `00-setup` asked once and `50-device-scan` stops the run if the answer was no, so
# anything reaching this line has a cube: every script between them needs one, and none of them runs after 50
# has failed. A second gate here would be a branch that can never be taken, and an untaken branch is checks
# that silently do not run.

open_settings
select_tab Device

# ---------------------------------------------------------------------------- a live link to ask
#
# **The link is taken down and let back up, and the pairing is left alone.** The first section below is about what the
# app does *on connecting*, which a connection that is already up cannot answer: its rows are older than any mark this
# script can take. So `relink_a_cube` quits and relaunches, and the app reconnects to the cube it inherited -- the
# reconnect `53-device-reconnect` proves, running the same login a fresh pairing would. See lib.sh for why this is not
# a `pair_a_cube`: nothing here is about pairing, and forgetting a cube to get a link would cost a scan for nothing.
#
# It is also what this script times from: every row it looks at is one this connection wrote, baselined here.

require_a_paired_cube "there is nothing to ask"

since=$(mark)
if ! relink_a_cube; then
    fail "the app did not reach the cube again within 90s, so there is no connecting to watch"
    finish
    exit 1
fi
# The relaunch took the window with it, and everything below reads the Device tab.
open_settings
select_tab Device

# ---------------------------------------------------------------------------- the pull
#
# **A connection that only subscribed would have nothing to show right now.** The cube notifies on change and only on
# change (`docs/timeflip2-firmware-observations.md`), so a charge that is not moving is a cube that says nothing --
# measured gaps of over an hour. The read is what puts a figure on screen at the moment a cube is reached.

expect_log "the app asks the cube for its charge on connecting" "$since" "Asking the cube for its charge" 30
expect_log "and the cube answers, so there is a figure without waiting for it to move" "$since" "Charge %" 30

# ---------------------------------------------------------------------------- the push
#
# The subscription is logged separately because a refused one and a steady charge are both silence: without this row
# there is no way to tell a cube that stopped reporting from a cube with nothing to report.

expect_log "and subscribes, so the cube reports every change by itself" "$since" "batteryLevel: notifying" 30

# ---------------------------------------------------------------------------- and everything else it can push
#
# **The app reads the charge and nothing else, and it listens to all of it.** A notification is only delivered on a
# characteristic that has been subscribed to, so anything not subscribed to is not ignored -- it is never sent, and
# leaves no evidence it could have been. `DeviceLogin.listenToTheCube` therefore subscribes to every characteristic
# whose properties say it can notify, which is what puts the cube's faces, its double taps and its system state in the
# trace years before a feature reads them.
#
# Counted rather than named, since what there is to subscribe to is the cube's answer and not this script's list.

# **Waited on rather than counted once**, which is `wait_sql`'s own lesson in `lib.sh` applied to a total this script
# cannot know in advance. Each subscription is a round trip: the battery one is confirmed first, the sweep's six go out
# behind it, and their confirmations trickle in about 120ms apart. Counting at the moment the battery row appears
# caught 7 asked and 1 confirmed and failed a working app -- measured in run 44, where the last confirmation landed
# 790ms after the row this script had waited for.
asked=0 took=0
for _ in $(seq 1 50); do
    asked=$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND tag = 'ble-tx' AND message LIKE '%notify on requested';")
    took=$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND tag = 'ble-rx' AND message LIKE '%: notifying';")
    [ "${asked:-0}" -ge 2 ] && [ "$asked" = "$took" ] && break
    sleep 0.2
done
step "asked for $asked subscription(s), the cube took $took"

if [ "${asked:-0}" -ge 2 ] && [ "$asked" = "$took" ]; then
    pass "every characteristic the cube can push on is subscribed to, not only the one a feature reads"
else
    fail "asked for $asked subscription(s) and $took were confirmed"
fi

check_contains "and the trace names what the service actually has" \
    "$(dsql "SELECT message FROM debug_log WHERE debug_log_id > $since AND message LIKE 'timeFlipService: characteristics%' ORDER BY debug_log_id DESC LIMIT 1;")" \
    "characteristics"

# ---------------------------------------------------------------------------- what the tab says
#
# The Battery row is read from the radio at the moment the tab is drawn, so it must agree with the last figure the log
# recorded. A row that disagreed would be the two-answers problem in its plainest form.

shown=$(dsql "SELECT message FROM debug_log WHERE debug_log_id > $since AND tag = 'battery' AND message LIKE 'Charge %' ORDER BY debug_log_id DESC LIMIT 1;")
percent=$(printf '%s' "$shown" | sed -n 's/^Charge \([0-9]*\)%.*/\1/p')
step "the log's latest figure is ${percent:-unknown}%"

if [ -n "$percent" ]; then
    check_contains "the Battery row shows what was last read" "$(element device-battery)" "${percent}%"
else
    fail "no charge was recorded at all, so there is nothing for the tab to agree with"
fi

# ---------------------------------------------------------------------------- the flap, absorbed
#
# **Every raw reading is in the trace and only the answers are in `battery`**, which is what makes this measurable at
# all: on the archive's traffic the cube reported 2,168 times in one day for a charge that was only ever 98 or 99.
#
# The assertion is the rule itself rather than the counts, since a cube that happens to sit still during this run
# produces one of each and proves nothing by volume: **the figure on show never climbs by one.** A rise of a single
# percent is what the flap is made of, so any increase here has to be two or more.

raw=$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND tag = 'ble-rx' AND message GLOB 'batteryLevel: [0-9A-F][0-9A-F]*';")
answers=$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND tag = 'battery' AND message LIKE 'Charge %';")
step "the cube reported $raw time(s); the figure on show moved $answers time(s)"

climbs=$(dsql "
    WITH shown AS (
        SELECT debug_log_id,
               CAST(substr(message, 8, instr(message, '%') - 8) AS INTEGER) AS percent
        FROM debug_log
        WHERE debug_log_id > $since AND tag = 'battery' AND message LIKE 'Charge %'
    )
    SELECT COUNT(*) FROM (
        SELECT percent - LAG(percent) OVER (ORDER BY debug_log_id) AS step FROM shown
    ) WHERE step = 1;
")
check "the figure never climbs by a single percent, which is what the flap is made of" "${climbs:-0}" "0"

# ---------------------------------------------------------------------------- setting what counts as flat
#
# **The row that says when to warn, changed here because here is where there is a cube.** Battery warning at moved
# from the App tab to the Device tab on 2026-09-03, and it goes dead with the rest of that section while nothing is
# connected -- so `13-device-tab` can only check that it is dead, and the write has to be driven from a script that
# has a link. This one already has one and is already on the tab.
#
# **No command goes out.** The level is what the app treats as flat, not something the cube is told, so the whole of
# the write is the table taking it. What is checked is the row moving and moving back.
#
# **Stepped and then waited on**, because the write is debounced by half a second now that the field sits among the
# steppers on this tab. It was written per tick while it was on the App tab, which debounces nothing.

warning_was=$(setting low_battery_level percent)
since=$(mark)
press device-battery-warning-up
sleep 1
warning_now=$(setting low_battery_level percent)
if [ "$warning_now" != "$warning_was" ]; then
    pass "the Battery warning arrow writes low_battery_level ($warning_was -> $warning_now)"
else
    fail "device-battery-warning-up left low_battery_level at $warning_was"
fi
expect_log "and says what the table now holds" "$since" "Battery warning: the table now holds % percent"

press device-battery-warning-down
sleep 1
check "and steps it back down" "$warning_was" "$(setting low_battery_level percent)"

# ---------------------------------------------------------------------------- and it goes with the link
#
# The charge is not stored anywhere and must not outlive the connection it describes: a remembered percentage is a
# number that was true at a moment nobody can name. Forgetting the device is the shortest way to drop the link.

since=$(mark)
press device-forget
sleep 1

expect_log "letting the cube go takes the charge with it" "$since" "The charge goes with the link"
check_contains "and the Battery row stops claiming one" "$(element device-battery)" "Not paired"

# ---------------------------------------------------------------------------- putting the cube back
#
# The forget above is how this script drops the link, so it ends with nothing paired and `55-device-face` starts from
# a cube. See `restore_the_pairing` in lib.sh.

restore_the_pairing

close_settings
finish
