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
# **The off half is sent twice, from a timing cube and from a stopped one**, because the command the first of the two
# clicks defers depends on which: `togglePause` sends the opposite of what the cube reports, so it is a pause on a
# timing cube and a resume on a stopped one, and both have to be cancelled. The on half is `57-cube-pause`, which
# reads the same two commands off the wire and checks the pause went out before the lock.
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
EXPECTED_CHECKS=25
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
# `13-device-tab` presses the same one.
#
# **On the Device tab, above Auto-pause.** It was on the App tab until 2026-09-03, which is the only thing that
# changed here: the same box, in the section holding the rest of what the cube is set to.

PAUSE_ON_LOCK_IS_OFF=0

# **The box is dead while no cube is connected**, which the App tab's copy of it never was, so the trap can no longer
# assume its press landed. An exit path that gets here having lost the cube -- a failure part way down, a Ctrl-C
# during the drop -- would press a greyed control, do nothing, and leave `pause_on_lock` off for `55`, `57` and the
# next run of this script. So the restore is read back, and says plainly what to do by hand when it could not.
put_pause_on_lock_back() {
    [ "$PAUSE_ON_LOCK_IS_OFF" = "1" ] || return 0
    yellow "  putting pause_on_lock back on"
    open_settings
    select_tab Device
    press device-pause-on-lock
    sleep 1
    if [ "$(setting pause_on_lock enabled)" = "1" ]; then
        PAUSE_ON_LOCK_IS_OFF=0
    else
        red "  pause_on_lock is still off and the box would not take a press -- the cube is probably gone."
        red "  Turn Pause the device when locking it back on, on the Device tab, before the next run."
    fi
    close_settings
}
trap put_pause_on_lock_back EXIT INT TERM

open_settings
select_tab Device

check "pause_on_lock starts on, which is what 00-setup pins it to" "1" "$(setting pause_on_lock enabled)"

since=$(mark)
press device-pause-on-lock
PAUSE_ON_LOCK_IS_OFF=1
check "and the checkbox turns it off" "0" "$(wait_sql "0" \
    "SELECT json_extract(setting_value, '\$.enabled') FROM setting WHERE setting_name = 'pause_on_lock';" 5)"
# **The row the box writes, said out loud.** Nothing else in the suite polls it: `13-device-tab` can only see this
# box dead, so without this the one message `applyPauseOnLock` writes would be unread by any script -- and a
# message no check reads is a message the next rename breaks silently.
expect_log "and says what the table now holds" "$since" "Pause on lock: the table now holds off"

close_settings

# ---------------------------------------------------------------------------- one pass, run from both states
#
# **The lock is sent from a timing cube and from a stopped one, and the answer has to be the same both times.** With
# the setting off the rule is "lock, and send no pause", and what the cube was doing beforehand is not part of it --
# but the *deferred* command the first of the two clicks schedules is: `togglePause` sends the opposite of what the
# cube reports, so on a timing cube that pending command is a pause and on a stopped one it is a resume. One pass
# would leave whichever of those two the run happened not to start in untested, and the resume is the worse of the
# two to get wrong: it would start a cube somebody had deliberately stopped, on their way to locking it.
#
# So the pass below is a function called twice rather than an `if`. `CLAUDE.md` is explicit that a branch in a test
# script is a path a run does not take, and that is the whole reason this file exists at all.

# The cube's own record of whether it is stopped: 1 paused, 0 timing. The open `device_event` row, which is where
# `57-cube-pause` reads it from too.
cube_is_paused() {
    sql "SELECT paused FROM device_event WHERE finalised = 0 ORDER BY start_epoch DESC, device_event_id DESC LIMIT 1;"
}

# **Arranging, not checking.** A single right click toggles the cube's pause, so getting to a named state is a click
# only if it is not already there. What it arranged is checked by the caller, from the table, rather than trusted
# here -- a setup step that answered for itself would be a check nobody counted.
put_the_cube() {
    [ "$(cube_is_paused)" = "$1" ] && return 0
    click_right
    wait_for_value \
        "SELECT paused FROM device_event WHERE finalised = 0 ORDER BY start_epoch DESC, device_event_id DESC LIMIT 1;" \
        "$1" 25 >/dev/null
}

# One pass: send the lock, and read what did and did not go out.
#
# **The negatives are read after the positive landed, which is what makes an absence provable.** The pause, when it
# goes, goes *before* the lock and is confirmed before it -- so by the time `The cube is locked` is in the table, a
# pause would already be there if one were coming. Nothing is being waited out and there is no race to lose: the
# positive is the clock the negatives are read against.
lock_without_pausing() {
    local state="$1" since
    since=$(mark)
    double_click_right

    # Routed the same way whatever the setting says: the router knows nothing about `pause_on_lock`. A failure here is
    # a routing problem rather than a locking one, which is worth telling apart.
    expect_log "with the cube $state, a double click is still routed as a lock" "$since" \
        "Status item clicked: side=right clicks=2%toggleCubeLock" 10
    expect_log "and the lock goes out" "$since" "The cube is locked" 20
    # The app saying which branch it took, which is the row the 2026-08-27 bug left as the *only* sign of anything.
    expect_log "and it says the pause was skipped, not that nothing was asked" "$since" \
        "pause_on_lock is off, so the cube is locked without pausing it" 10

    check "so nothing claims to have paused it" "0" \
        "$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND tag = 'command' AND message = 'The cube is paused';")"

    # **The wire as well as the app's own account of it**, which are different claims: the line above is what
    # `CubeLock` believed, and this is what actually went out. `06 %` is either direction of the pause command
    # (`DeviceCommandRules.pause`), so zero across the whole double click is the deferred first-click command never
    # having been sent by anybody -- a pause on a timing cube, a resume on a stopped one.
    check "and no pause command reached the wire in either direction" "0" \
        "$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND tag = 'command' AND message LIKE 'Sending 06 %';")"

    check_contains "and the menu bar shows the lock" "$(status_item)" "device locked"
}

# ---------------------------------------------------------------------------- from a cube that is timing

put_the_cube 0
check "the cube is timing, which is this pass's starting state" "0" "$(cube_is_paused)"
lock_without_pausing "timing"

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

# ---------------------------------------------------------------------------- and again, from a cube that is stopped
#
# **The pass the run would otherwise never take.** Everything above happened on a timing cube, where the command the
# first click defers is a pause; here it is a resume, and a cancellation that only worked in one direction would
# start a cube somebody had deliberately stopped on their way to locking it.
#
# **Stopped with a real click rather than by writing the row**, because the row is the cube's answer and not the
# app's: `device_event.paused` is written from what the cube reported, so setting it by hand would arrange a state
# the hardware is not in and this whole script would then be reading the app against a fiction.

put_the_cube 1
check "the cube is stopped, which is the other starting state" "1" "$(cube_is_paused)"
lock_without_pausing "already paused"

# ---------------------------------------------------------------------------- and the unlock still starts it again
#
# **From a cube that was stopped before the lock, which is the case `resume` is least obviously right about.** It
# sends the resume unconditionally, so this unlock starts a cube that was stopped on purpose -- and that is
# deliberate rather than an oversight: a cube left paused and unlocked records nothing while somebody flips it, and
# the app has no way to tell "stopped on purpose" from "stopped because a lock stopped it". `CubeLock.resume` carries
# the reasoning. Checked here so the behaviour is on record rather than a surprise.

since=$(mark)
double_click_right
expect_log "the unlock goes out for a cube that was stopped first" "$since" "The cube is unlocked" 20
expect_log "and it is started again, stopped or not" "$since" "The cube is running" 20

# ---------------------------------------------------------------------------- putting the setting back
#
# Checked rather than left to the trap, so that a run which quietly failed to restore it is a red line here instead of
# a puzzle in whatever runs next.
#
# **Settings is opened from the menu still standing open above**, which is what dismisses it: choosing an item is the
# only way to close a dropdown here, and this is the one choice that leads where the script was going anyway.

press open-settings
sleep 1
select_tab Device
press device-pause-on-lock
PAUSE_ON_LOCK_IS_OFF=0
check "pause_on_lock is back on for whatever runs next" "1" "$(wait_sql "1" \
    "SELECT json_extract(setting_value, '\$.enabled') FROM setting WHERE setting_name = 'pause_on_lock';" 5)"
close_settings

finish
