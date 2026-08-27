#!/bin/bash
# Locking the cube with `pause_on_lock` off: the lock still goes, and only the pause is skipped.
#
# **The bug this exists for, fixed 2026-08-27.** The setting used to gate the whole sequence rather than the pause, so
# with it off `CubeLock.lock` sent nothing at all: a double click on the right half of the status item, and a quit,
# both answered by leaving the cube running and unlocked. The only sign anything had been asked was one row,
# `pause_on_lock is off, so the cube is left as it is`. The setting is named for what it does -- whether locking
# **also** pauses -- and never decided whether locking happens.
#
# So the rule, in full:
#
#   on   double click or quit -> pause the cube, then lock it
#   off  double click or quit -> lock it
#
# **And the dropdown's Pause item, which the lock decides too.** A locked cube is frozen on the face it is on and
# ignores everything but an unlock, so Pause is greyed while it is locked and live while it is not. That is checked
# here rather than in its own script because this is the one place a cube is deliberately locked with the pause
# setting off, and the item has to be right in that combination as much as any other.
#
# **Why it is its own script rather than a branch in `57-cube-pause`.** Every other script here runs with the setting
# on, because `00-setup` pins it there and the scripts after it are written for one starting state. `CLAUDE.md` is
# explicit that a branch in a test script is a path a run does not take and so never checks -- and that is exactly
# what happened: `55` and `57` each carry an `if` on this setting whose `else` is a `fail`, so the off case has never
# once been exercised on hardware. One script that deliberately turns it off, checks the single thing that changes,
# and puts it back is the version of that which actually runs.
#
# **Last of the device scripts, deliberately.** It is the only one that moves a setting the others depend on, so it
# sits where the fewest scripts follow it. Only `99-quit` does, and that wipes the cube anyway.
#
# **The setting is restored from a trap as well as at the end.** A check failing, or somebody pressing Ctrl-C, would
# otherwise leave it off -- and the next run's `00-setup` would put it back, so the damage would land on whatever ran
# in between rather than being visible here. The end-of-script restore is the one that is *checked*; the trap is for
# the exits nobody thought of.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
# What this script checks when everything passes. See `finish` in lib.sh for what a mismatch means.
EXPECTED_CHECKS=13
start "locking the cube with pause_on_lock off"

# **No cube check here**, for the reason `57-cube-pause` gives: `00-setup` asked once and `50-device-scan` stops the
# run if the answer was no, so anything reaching this line has a cube.
#
# **The cube `60-device-backlog` left connected**, inherited like every device script from `52` on -- see
# `require_a_paired_cube` in lib.sh. A precondition and not a check: the lock below is a command that has to arrive
# somewhere.
require_a_paired_cube "there is no cube to lock"

# ---------------------------------------------------------------------------- turning the pause off
#
# **Through the checkbox, not the table.** Every script in this folder except `00-setup` is forbidden from writing to
# the tables, and here the rule earns it twice over: the app reads this setting at the moment it locks, so the value
# that matters is the one the app's own write left behind, and pressing the control is the only way to get that.
# `08-app-settings` presses the same one.

PAUSE_ON_LOCK_IS_OFF=0

put_pause_on_lock_back() {
    [ "$PAUSE_ON_LOCK_IS_OFF" = "1" ] || return 0
    yellow "  putting pause_on_lock back on"
    open_settings
    select_tab App
    press app-pause-on-lock
    sleep 1
    close_settings
    PAUSE_ON_LOCK_IS_OFF=0
}
trap put_pause_on_lock_back EXIT INT TERM

open_settings
select_tab App

check "pause_on_lock starts on, which is what 00-setup pins it to" "1" "$(setting pause_on_lock enabled)"

press app-pause-on-lock
PAUSE_ON_LOCK_IS_OFF=1
check "and the checkbox turns it off" "0" "$(wait_sql "0" \
    "SELECT json_extract(setting_value, '\$.enabled') FROM setting WHERE setting_name = 'pause_on_lock';" 5)"

close_settings

# ---------------------------------------------------------------------------- two clicks still lock it

since=$(mark)
double_click_right

# Routed the same way whatever the setting says: the router knows nothing about `pause_on_lock`, and this is what
# says so. A failure here is a routing problem rather than a locking one, which is worth telling apart.
expect_log "a double click is still routed as a lock" "$since" \
    "Status item clicked: side=right clicks=2%toggleCubeLock" 10

expect_log "and the cube locks, with the setting off" "$since" "The cube is locked" 20

# ---------------------------------------------------------------------------- and the pause is the only thing missing
#
# **Checked after the lock landed, which is what makes an absence provable.** The pause, when it goes, goes *before*
# the lock and is confirmed before it -- so by the time `The cube is locked` is in the table, a pause would already be
# there if one were coming. Nothing is being waited out here and there is no race to lose: the positive above is the
# clock this negative is read against.

check "and nothing said it paused the cube" "0" \
    "$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND tag = 'command' AND message = 'The cube is paused';")"

# **The wire as well as the app's own account of it**, which are different claims: the line above is what `CubeLock`
# believed, and this is what actually went out. `06 01` is pause-on (`DeviceCommandRules.pause(true)`), and a count of
# zero across the whole double click is the pause never having been sent by anybody -- the deferred one the first
# click schedules included.
check "and no pause went out on the wire either" "0" \
    "$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND tag = 'command' AND message LIKE 'Sending 06 01%';")"

check_contains "the menu bar shows the lock" "$(status_item)" "device locked"

# ---------------------------------------------------------------------------- and the menu says so too
#
# **The dropdown is read while the cube is actually locked**, which is the only way to check this: the item's state is
# decided at the moment the menu opens, from `PauseMenuRules`, so nothing short of a real locked cube behind a real
# open menu exercises it. `ax-dump.py` prints `disabled` on an item's line only when it is off, so the word being
# present is the whole assertion.

click_left
sleep 0.8
pause_item() { python3 scripts/ax-dump.py --menu-bar 2>/dev/null | grep -m1 "id=toggle-pause" || true; }

case "$(pause_item)" in
    *disabled*) pass "the dropdown greys out Pause while the cube is locked" ;;
    "") fail "the dropdown had no Pause item to read at all" ;;
    *) fail "the dropdown still offers Pause on a locked cube, which the cube will refuse" ;;
esac

# ---------------------------------------------------------------------------- and two more unlock it
#
# **Unlocking is not gated on the setting and must not become gated on it.** `CubeLock.resume` says why in its own
# comment: refusing to undo a lock because the setting that made it has since been turned off would strand a cube in
# the one state this app can otherwise not get it out of. With the setting off that is the *only* way out, since
# nothing else here would have locked it.
#
# **Pressing Lock is also what dismisses the menu opened above.** There is no helper that closes a dropdown without
# choosing something, so the check above is placed where the choice it needs to make anyway is the right one.

since=$(mark)
press toggle-cube-lock

expect_log "the dropdown Lock item unlocks it" "$since" "The cube is unlocked" 20

# **And the resume comes with it, even though nothing here paused.** `resume` sends both unconditionally, which is
# deliberate: a cube left paused and unlocked records nothing while somebody flips it, and that is worse than a lock
# they can see. So this row appears on a cube that was never paused, and its absence would mean `resume` had grown a
# gate to match the lock's old one.
expect_log "and the resume goes with it, on a cube nothing had paused" "$since" "The cube is running" 20

case "$(status_item)" in
    *"device locked"*) fail "the menu bar still says the cube is locked" ;;
    *) pass "and the badge goes with it" ;;
esac

# ---------------------------------------------------------------------------- and Pause comes back with the unlock
#
# The other half of the rule, and the half that was broken in the opposite direction: with a cube connected and no
# manual session, the item used to be greyed because it only ever asked about the app's own clock.

click_left
sleep 0.8

case "$(pause_item)" in
    *disabled*) fail "the dropdown still greys out Pause on an unlocked cube it could pause perfectly well" ;;
    "") fail "the dropdown had no Pause item to read at all" ;;
    *) pass "and offers it again once the cube is unlocked" ;;
esac

# ---------------------------------------------------------------------------- putting the setting back
#
# Checked rather than left to the trap, so that a run which quietly failed to restore it is a red line here instead of
# a puzzle in whatever runs next.
#
# **Settings is opened from the menu still standing open above**, which is what dismisses it: choosing an item is the
# only way to close a dropdown here, and this is the one choice that leads where the script was going anyway.

press open-settings
sleep 1
select_tab App
press app-pause-on-lock
PAUSE_ON_LOCK_IS_OFF=0
check "pause_on_lock is back on for whatever runs next" "1" "$(wait_sql "1" \
    "SELECT json_extract(setting_value, '\$.enabled') FROM setting WHERE setting_name = 'pause_on_lock';" 5)"
close_settings

finish
