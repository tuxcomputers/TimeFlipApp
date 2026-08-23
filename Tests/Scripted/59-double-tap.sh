#!/bin/bash
# The four double-tap registers: stepped on the Device tab, sent to the cube, read back off it, and only then
# written down.
#
# **What needs a real cube is the order of the three.** Which bytes `0x16` carries and what a `0x17` answer has to
# look like are `DoubleTapRules`, pinned in `swift test` with no radio in sight; that the four fields land in one
# update is `SettingStore`, pinned the same way. What cannot be tested there is the sequence the first rule in
# `CLAUDE.md` is about: the cube is asked, the cube answers with the registers it is actually on, and the table is
# written only after that. An app that wrote the row beside the send would pass every unit test in the repo and
# would be recording its own wish as the cube's state.
#
# **Turning the gesture off is faked and that is the other half.** No BLE command disables double tap (measured,
# `Archive/Tests/Methods.md` Method 22), so the Disable box sends `window` 0 while the table keeps the real number --
# that number being what turning it back on has to put back. The two therefore disagree on purpose, which is exactly
# the shape a bug would take, so both are read: what went on the wire, and what the row holds afterwards.
#
# **Runs after `58`, which leaves a launched app logged in to the cube, and before the wipe in `99`.**
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
# What this script checks when everything passes. See `finish` in lib.sh for what a mismatch means.
EXPECTED_CHECKS=19
start "the double-tap registers: sent, read back off the cube, then written down"

# **No cube check here.** `00-setup` asked once and `50-device-scan` stops the run if the answer was no, so
# anything reaching this line has a cube: every script between them needs one, and none of them runs after 50
# has failed. A second gate here would be a branch that can never be taken, and an untaken branch is checks
# that silently do not run.

# ---------------------------------------------------------------------------- arranging, not checking
#
# **The row is put to its seeded four before anything opens.** Every pattern below names the numbers it expects, and
# a run inheriting a `window` somebody left at 0 would turn the whole disable section into a check that cannot fail:
# sending 0 when the stored value is already 0 proves nothing about the faking. This is the same licence
# `08-app-settings` takes when it puts `fetch_history_interval_seconds` back by hand, and it is taken here for the
# same reason -- there is no control that can reach an arbitrary starting state in one press.
#
# **Written with the window shut**, which is what makes it safe. An open Settings window is the source of truth for
# what it shows (`CLAUDE.md`), so writing underneath one would be the two-answers problem this script exists to check
# for. Shut, there is nothing holding a copy, and the open below reads the table.

close_settings
sql "UPDATE setting
        SET setting_value = json_set(setting_value,
              '\$.enabled', json('true'),
              '\$.clickThreshold', 90,
              '\$.limit', 20,
              '\$.latency', 50,
              '\$.window', 50)
      WHERE setting_name = 'double_tap_settings';"
step "the double-tap row starts at enabled, 90 / 20 / 50 / 50"

open_settings
select_tab Device

# ---------------------------------------------------------------------------- a live cube to send to
#
# Paired from scratch, for the reason `52`, `53` and `54` give: a script that inherited an earlier one's pairing
# would silently test nothing whenever that one skipped.

if ! pair_a_cube; then
    pair_verdict "there is no cube to send registers to"
    close_settings
    finish
    exit $?
fi
pass "paired a cube to set the registers against"

# ---------------------------------------------------------------------------- reaching the four fields
#
# **`Double tap` is a `DisclosureRow` inside the Settings `PanelSection`**, and it is the one fold on this tab that
# starts shut. Opening Settings puts it back to shut however it was left, so this is unconditional rather than a
# state to be tolerated.

check "the Double tap group starts folded" "0" "$(on_tab device-double-tap-threshold-up)"

press device-double-tap-heading-button
sleep 1
opened=$(on_tab device-double-tap-threshold-up)
if [ "${opened:-0}" -gt 0 ]; then
    pass "and its registers come out when the heading is pressed"
else
    fail "the Double tap group opened but its Threshold stepper is not on the tab"
fi

# ---------------------------------------------------------------------------- one register moved
#
# **The arrow rather than the field**, as `08-app-settings` does: the arrows are what a person uses, and what the
# field ends up holding is read back out of the table anyway.
#
# **All four go every time.** `0x16` sets the lot in one command, so moving Threshold sends Limit, Latency and Window
# beside it -- which is why the row below names all four and why the table is then checked for the three that did
# not move.

since=$(mark)
press device-double-tap-threshold-up
expect_log "stepping Threshold sends all four registers" "$since" \
    "Double tap: sending Threshold: 91, Limit: 20, Latency: 50, Window: 50"
expect_log "and the cube answers with the registers it is now on" "$since" \
    "The cube confirms it took: Threshold: 91, Limit: 20, Latency: 50, Window: 50" 30
expect_log "and only then is the row written" "$since" \
    "Double tap: the table now holds Threshold: 91, Limit: 20, Latency: 50, Window: 50" 30

wait_for_value "SELECT json_extract(setting_value, '\$.clickThreshold') FROM setting WHERE setting_name = 'double_tap_settings';" "91" 10
check "the table holds the stepped Threshold" "91" "$(setting double_tap_settings clickThreshold)"
check "and the three that did not move are still what they were" "20/50/50" \
    "$(setting double_tap_settings limit)/$(setting double_tap_settings latency)/$(setting double_tap_settings window)"

press device-double-tap-threshold-down
wait_for_value "SELECT json_extract(setting_value, '\$.clickThreshold') FROM setting WHERE setting_name = 'double_tap_settings';" "90" 30
check "stepping it back down puts the table back" "90" "$(setting double_tap_settings clickThreshold)"

# ---------------------------------------------------------------------------- turning the gesture off
#
# **Window 0 on the wire, the real Window in the table.** That disagreement is deliberate and is the whole of how the
# app turns a gesture off that the hardware has no switch for, so both sides are read rather than one.

since=$(mark)
press device-double-tap-disable
expect_log "ticking Disable sends Window as 0" "$since" \
    "Double tap: turning it off, sending Threshold: 90, Limit: 20, Latency: 50, Window: 0"
wait_for_value "SELECT json_extract(setting_value, '\$.enabled') FROM setting WHERE setting_name = 'double_tap_settings';" "0" 30
check "the table says the gesture is off" "0" "$(setting double_tap_settings enabled)"
check "and it keeps the real Window, which is what turning it back on sends" "50" \
    "$(setting double_tap_settings window)"

# ---------------------------------------------------------------------------- a register moved while it is off
#
# The trap this covers: a value changed while the gesture is off must not turn it back on behind the box. Everything
# still goes as Window 0, and the stored 50 is untouched.

since=$(mark)
press device-double-tap-threshold-up
expect_log "a register moved while the gesture is off still goes with Window 0" "$since" \
    "Double tap: sending Threshold: 91, Limit: 20, Latency: 50, Window: 0"
expect_log "and the log says which Window is being kept" "$since" \
    "Double tap: the gesture is off, so Window goes as 0 and 50 is what gets stored"
wait_for_value "SELECT json_extract(setting_value, '\$.clickThreshold') FROM setting WHERE setting_name = 'double_tap_settings';" "91" 30
check "the table took the moved register and kept the real Window" "91/50" \
    "$(setting double_tap_settings clickThreshold)/$(setting double_tap_settings window)"

press device-double-tap-threshold-down
wait_for_value "SELECT json_extract(setting_value, '\$.clickThreshold') FROM setting WHERE setting_name = 'double_tap_settings';" "90" 30
check "and it goes back down again" "90" "$(setting double_tap_settings clickThreshold)"

# ---------------------------------------------------------------------------- turning it back on
#
# **The stored Window is what goes**, which is the reason the table kept it. A cube left on 0 after the box is
# unticked is a gesture the app believes is on and the hardware cannot recognise.

since=$(mark)
press device-double-tap-disable
expect_log "unticking Disable sends the stored Window back to the cube" "$since" \
    "Double tap: turning it on, sending Threshold: 90, Limit: 20, Latency: 50, Window: 50"
wait_for_value "SELECT json_extract(setting_value, '\$.enabled') FROM setting WHERE setting_name = 'double_tap_settings';" "1" 30
check "the table says the gesture is on again" "1" "$(setting double_tap_settings enabled)"
check "and the four registers are back where this script found them" "90/20/50/50" \
    "$(setting double_tap_settings clickThreshold)/$(setting double_tap_settings limit)/$(setting double_tap_settings latency)/$(setting double_tap_settings window)"

close_settings
finish
