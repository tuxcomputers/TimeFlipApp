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
# (`Archive/Tests/CLAUDE.md`: a cross-step wait needs its own named baseline).
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
