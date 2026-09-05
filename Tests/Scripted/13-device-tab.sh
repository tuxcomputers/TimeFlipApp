#!/bin/bash
# The Device tab's two sections, and the folds that need no cube.
#
# **Under 50 deliberately, because none of this touches a radio.** Whether a section folds is a question about the
# window, not about the hardware: both sections are built whether or not anything is paired, and the rows inside
# them are drawn from the tables. The checks that do need a cube -- what the readings say once one has answered,
# what the scan finds -- stay in `51-device-connect.sh` where a cube is confirmed first.
#
# **The nesting is the thing this tab has and the others do not.** *More* sits inside TimeFlip, and *LED* and
# *Double tap* inside Settings, so a `DisclosureRow` can be folded inside a folded `PanelSection`. Both levels are
# checked here, and so is the part that is easy to get wrong: opening Settings puts every one of them back to what
# it was built as, at both levels, however they were left.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
# What this script checks when everything passes. See `finish` in lib.sh for what a mismatch means.
EXPECTED_CHECKS=45
start "the Device tab's two sections, and the folds that need no cube"

open_settings
select_tab Device

# ---------------------------------------------------------------------------- the two sections
#
# **Both open**, which is the App tab's answer rather than the Categories tab's: these are the whole of the tab, so
# opening it folded would show two headings and nothing to read. TimeFlip in particular stays open because the scan
# results appear inside it, and a folded section would hide the answer to the thing somebody just pressed.
#
# **Two, not the archive's three.** Info and TimeFlip were merged on 2026-08-22: what a cube is and how to get one
# were a panel apart, so the name of the paired device sat in one section and the button that pairs it in another.
# The absence of a third is checked rather than left implied, since a stale section would still draw correctly.

for pair in "device-timeflip-section TimeFlip" "device-settings-section Settings"; do
    set -- $pair
    check_contains "the $2 section is on the tab" "$(tree)" "id=$1"
done
check "and there is no third section left over" "0" "$(on_tab device-info-section)"
check "nor the old pairing one" "0" "$(on_tab device-pairing-section)"

# Read off the contents rather than off the heading: a section with its rows showing is what open means.
check "the TimeFlip section starts open" "1" "$(on_tab device-connection)"
check "the Settings section starts open" "1" "$(on_tab device-auto-pause)"

# **The readings and the button are one section now.** Both of these are in TimeFlip, which is the whole point of
# the merge: what the app knows about the cube, and what to press to get one.
check "the Name row and the scan button are in one section" "1" "$(on_tab device-name)"
check "and the scan button is there with it" "1" "$(on_tab device-scan)"

# ---------------------------------------------------------------------------- what a tab with no cube offers
#
# **The Settings section is dead before anything has been paired**, which is the state every launch starts in and
# the one no device script can reach: from `51` onwards there is a cube. The gate is `isCubeConnected`, and here the
# two facts give the same answer -- nothing is paired, so nothing is connected -- which is why both are read rather
# than only the one being asserted about. `56-manual-mode` reads the discriminating case, where the pairing survives
# a drop, and `DevicePaneTests.testEverySettingsControlIsDeadWhileAPairedCubeIsOutOfReach` reads it hermetically.
#
# **This script already depends on there being no cube**: the scan button checked directly above is only on the tab
# while nothing is paired (`DevicePairingRules.showsScanControls`), so an unconditional check adds no new assumption.

check "nothing is paired, which is what this tab is drawn from" "0" "$(setting paired paired)"
check "so nothing is connected either" "0" "$(setting connection connected)"

# **Every control in the Settings section is dead, not just Auto-pause.** Each of them changes something about the
# cube, so with nothing on the other end a press could only ever end in the refusal sheet -- and one row left live
# in a dead section reads as the section having an exception rather than a rule.
#
# **Read off the tree in one loop**, because the fault this guards against is a row added to that section and not
# to this list: naming them here is what makes the next one visible.
#
# Pause the device when locking it and Battery warning at are in the list with the rest, and they are the two worth
# saying why about: no command carries either, so both could have been left live, and neither is. A section about a
# cube answers the question about a cube the same way in every row of it. See `DevicePane.drawSettingsGate`.

# **Both inner folds are opened first.** LED and Double tap are built folded, so their rows are not in the tree at
# all until the heading is pressed, and a control that is absent is not a control that is dead. Opened once around
# the whole loop rather than per row, and put back below, so the section is left as the fold checks further down
# expect to find it.
press device-led-heading-button
sleep 0.5
press device-double-tap-heading-button
sleep 0.5

for control in \
    device-pause-on-lock \
    device-battery-warning \
    device-auto-pause \
    device-led-brightness \
    device-led-blink \
    device-double-tap-disable \
    device-double-tap-threshold \
    device-double-tap-limit \
    device-double-tap-latency \
    device-double-tap-window
do
    check "$control is dead with no cube connected" "1" \
        "$(tree | grep -cE "id=$control[[:space:]].*disabled" || true)"
done

press device-led-heading-button
sleep 0.5
press device-double-tap-heading-button
sleep 0.5
check "and both inner folds are back as they were built" "0" "$(on_tab device-led-brightness)"

# The arrows go with the field they belong to: a dead box above two live arrows is a control that is half off.
check "and the Auto-pause arrows are dead with it" "2" \
    "$(tree | grep -cE "id=device-auto-pause-(up|down)[[:space:]].*disabled" || true)"
check "as are the Battery warning arrows" "2" \
    "$(tree | grep -cE "id=device-battery-warning-(up|down)[[:space:]].*disabled" || true)"

# **None of them is pressed here, deliberately.** `AXPress` on a disabled control is refused by the accessibility
# API itself, so the press would print a red failure line for behaving correctly -- and `00-setup` pins
# `pause_on_lock` on, with `55`, `57` and `61` all requiring it on, so a press that somehow got through would fail a
# script two hundred lines away with nothing to point at. That a dead control starts no write is checked hermetically
# instead (`DevicePaneTests.testADeadLockBoxReportsNothingWhenItIsClicked` and the Auto-pause one beside it).
#
# **What it is like to change one is checked where there is a cube**: `61-lock-without-pause` presses this same box
# and reads the table both ways, `54-device-battery` steps the warning level, `65-auto-pause` the delay,
# `63-led-settings` the LED pair and `59-double-tap` the registers.

# **The Name row will not open either, and for the same reason: renaming is a command (`0x15`) that has to reach the
# cube.** What it does instead of going dead is say why -- the button stays pressable so that the tooltip and the
# spoken label survive, which is what `EditableNameCell.isEnabled` is careful about, so the check that it will not
# open is that pressing it produces no field.
#
# **The live case cannot be checked here**, nothing being paired below `50`. It is in `66-device-rename`.


check_contains "the Name row says there is no device" "$(element device-name)" "Not paired"
check_contains "and says why it will not open" "$(element device-name)" "no name to change"
press device-name
sleep 1
check "so pressing the name opens no field" "0" "$(on_tab device-name-field)"

# ---------------------------------------------------------------------------- folding each one
#
# **Pressed on the heading button, not the section.** The section is a group and pressing a group does nothing at
# all, which reads as a tab that failed to draw its rows (measured on a device run, 2026-08-17, and written up in
# `51-device-connect.sh`). The whole line is the target, and that is the half `swift test` cannot check.

for pair in "device-timeflip-section device-connection" "device-settings-section device-auto-pause"; do
    set -- $pair
    section="$1" inside="$2"

    since=$(mark)
    press "$section-heading-button"
    sleep 1
    expect_log "pressing the $section heading folds it" "$since" "Device section $section folded"
    check "and its rows go with it" "0" "$(on_tab "$inside")"

    since=$(mark)
    press "$section-heading-button"
    sleep 1
    expect_log "pressing it again opens it" "$since" "Device section $section opened"
    check "and its rows come back" "1" "$(on_tab "$inside")"
done

# ---------------------------------------------------------------------------- a fold inside a fold
#
# **More is built folded and TimeFlip is built open**, so this is the case where the two levels disagree. What is
# being checked is that folding the outer one does not quietly open or close the inner one: a section that
# rebuilt its contents on every fold would lose whatever the inner row was left as.

check "More starts folded, so its rows are not in the tree" "0" "$(on_tab device-manufacturer)"

press device-more-heading-button
sleep 0.7
check "opening More brings its rows out" "1" "$(on_tab device-manufacturer)"

press device-timeflip-section-heading-button
sleep 0.7
check "folding TimeFlip takes the open More with it" "0" "$(on_tab device-manufacturer)"

press device-timeflip-section-heading-button
sleep 0.7
check "and opening TimeFlip finds More still open, not reset" "1" "$(on_tab device-manufacturer)"

# The scan button folds with the readings above it, being rows of the same section now rather than of its own.
press device-timeflip-section-heading-button
sleep 0.7
check "folding TimeFlip takes the scan button with the readings" "0" "$(on_tab device-scan)"
press device-timeflip-section-heading-button
sleep 0.7
check "and both come back together" "1" "$(on_tab device-scan)"

# ---------------------------------------------------------------------------- a fold does not outlive its window
#
# **Nothing stores a fold, at either level.** The panes are made once and reused for the life of the launch, so
# without the reset a section folded in one window is still folded in the next -- and the second open would show a
# tab arranged by a gesture made minutes ago and no reason to remember. Left here in the state that proves it:
# an outer section folded, an inner row opened away from its default.

press device-settings-section-heading-button
sleep 0.7
check "precondition: Settings is folded" "0" "$(on_tab device-auto-pause)"

# **Its own baseline, taken here.** The `since` left over from the fold loop above would sweep in every row those
# presses wrote, so the silence check below would be reading its own doing rather than the reset's
# (the previous suite's rule: a cross-step wait needs its own named baseline).
before_reset=$(mark)

close_settings
open_settings
select_tab Device

check "the next open finds Settings back open" "1" "$(on_tab device-auto-pause)"
check "and TimeFlip back open too" "1" "$(on_tab device-connection)"
# The inner row goes back to *its* own default, which is the opposite of the outer ones. A reset that put
# everything to one state would be just as wrong as one that put nothing back.
check "and More back to folded, which is its own default" "0" \
    "$(on_tab device-manufacturer)"

# **Silent, and that is the point.** A reset is not a fold anybody made, so it must not write a row. A log full
# of folds nobody made is worse than no record at all, and it would make every check above unassertable.
resets=$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $before_reset AND message LIKE 'Device section %';")
check "and it said nothing while putting them back" "0" "${resets:-0}"

finish
