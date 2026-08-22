#!/bin/bash
# The face the cube is resting on: asked for when the link comes up, followed on every turn after it, and drawn the
# same way in both of the places that draw it.
#
# **What needs a real cube here is the turn.** Which category a face holds is `DeviceFaceRules`, what a reading says
# is `TimingReadout`, and what the menu bar spells out of it is `StatusItemTitle` -- all three pinned in `swift test`
# with no radio anywhere near them. What cannot be tested there is that a cube reports a turn at all, and that both
# surfaces then say the same thing about it.
#
# **That second half is why this script exists.** With a cube connected the Faces tab drew the face's category while
# the menu bar went on drawing the app's name, because each asked its own question -- the tab asked the radio, the
# item asked `TimingReadout` -- and every hermetic test passed throughout. One reading now decides, and the check that
# would have caught it is the one below that reads both surfaces and compares them against each other.
#
# **Meeting (face 2) and Break (face 8), which is the archive's pair**: `Archive/Tests/Interactive/01i-history-refresh-checklist.md`
# says "faces used throughout this checklist's run: face 2 ('Meeting') and face 8 ('Break') only". Kept, and for a
# reason that is this database's rather than inherited: they are the only two faces `008_face.sql` seeds with a real
# category, so on a database built from the DDL every other face reads *Unassigned* -- which draws an unlit cube with
# no name on it, and would prove nothing about a name following anything.
#
# **The turn is detected, not confirmed.** Nobody is asked "did you do that?": the app writes a row when the cube
# reports the face, and that row is the evidence. `ask_and_detect` says more about why, and about why it never gives up.
#
# **The cube is unlocked first, and that is the archive's finding rather than tidiness.** A locked cube silently
# refuses to change face, so asking for a turn while it is locked would wait for ever with nothing to detect (`01i`
# Scenario A, Step 3, which found exactly that and had to unlock before it could carry on). It is a live possibility
# here rather than a precaution: `16-device-reconnect` quits the app, and quitting pauses and locks the cube whenever
# `pause_on_lock` is on, which is what the DDL seeds.
#
# **Runs after `17`, and before the wipe in `99`.** It needs a live link and it needs a person, so it sits with the
# other device scripts rather than out on its own.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
start "the face the cube is on, and both places drawing the same one"

if ! device_required; then
    skip "no TimeFlip was made available, so there is no face to read"
    finish
    exit 0
fi

open_settings
select_tab Device

# ---------------------------------------------------------------------------- a cube to turn
#
# Paired from scratch, for the reason `15`, `16` and `17` all give: a script that inherited an earlier one's pairing
# would silently test nothing whenever that one skipped. `17` ends by forgetting the device anyway, so there is
# nothing here to inherit.

link=$(mark)
if ! pair_a_cube; then
    skip "no cube could be paired, so there is no face to read ($PAIR_REASON)"
    close_settings
    finish
    exit 0
fi
pass "paired a cube to turn"

# The high-water mark for `device_event`, taken before anything is turned. What it is for is further down: reading a
# face is all this feature does, and the check that nothing was *recorded* needs a line to measure from.
events_before=$(sql "SELECT IFNULL(MAX(device_event_id), 0) FROM device_event;")

# ---------------------------------------------------------------------------- asked for, not waited for
#
# **A connection that only subscribed would show nothing until somebody touched the cube.** The face characteristic
# notifies on change, so a cube sitting still says nothing at all, and a link that came up to a blank column would be
# the ordinary case rather than the exception. The read is what puts a face on screen at the moment the cube is
# reached, and it is the first thing waited for here because everything below is about what happens after it.

expect_log "the app asks which face is up as soon as the link is open" "$link" "Asking the cube which face is up" 30
expect_log "and the cube answers, so there is a face before anybody touches it" "$link" "Face % is up" 30
expect_log "it asks what state the cube is in as well" "$link" "Asking the cube what state it is in" 30
# **And the answer is waited for separately, which is the whole point of this line.** The row above says the question
# went out, not that it came back, and everything below reads the answer: `status_row` decides which way the Lock item
# is currently pointing. On 2026-08-22 those two were one check, and the 118ms between the `0x10` write and the
# `commandResult` read was enough to lose -- the script read an empty status, took a locked cube for an unlocked one,
# pressed an item that said *Unlock*, and then waited twenty seconds for a pause that nothing was ever going to send.
#
# It is the last thing the connection does, so there is no later row to hide behind: `0x10` now goes out after the
# clock, the history, the face and the double-tap registers, which is what turned a latent race into a failing run.
expect_log "and the cube answers, so the app knows which way the lock is" "$link" "The cube is %ocked and %" 30

# ---------------------------------------------------------------------------- unlocked, or it will not turn
#
# **A precondition and a check at the same time.** The cube has to be unlocked before it will report a turn, and
# getting it there is the app's own Unlock item doing the thing it exists for -- so the badge is checked in both
# directions on the way past rather than in a script of its own.
#
# **Which of the two directions gets exercised depends on how the cube is found**, and that is worth saying plainly
# rather than claiming both. A cube found unlocked is locked here and then unlocked by the block below it, so a run
# that starts from one covers the pair. A cube found locked is only unlocked: locking it again would leave the cube
# locked for everything underneath, and a locked cube silently refuses to change face. `16`'s quit locks it whenever
# `pause_on_lock` is on, which the DDL seeds, so the second case is the ordinary one on a full run.

# What the cube last said about itself, from this connection onwards. Written by `BluetoothRadio` and only when the
# answer is news, which is enough: the ask made when a link comes up always writes one, since the held status is
# cleared with the connection.
status_row() {
    sql "SELECT message FROM debug_log WHERE debug_log_id > $link AND tag = 'command' AND message LIKE 'The cube is %ocked and %' ORDER BY debug_log_id DESC LIMIT 1;"
}

# The status item's own line, which is where the lock badge shows up. Matched through the spoken description rather
# than the drawn title: the badge is an image attachment and every attachment is the same character in text, so a
# title cannot tell a lock apart from a category icon. `setAccessibilityLabel(title.spoken)` spells it out, which is
# what makes it assertable at all.
status_item() {
    python3 scripts/ax-dump.py --menu-bar 2>/dev/null | grep -m1 "id=status-item" || true
}

# Opens the dropdown and presses the Lock/Unlock item, whichever one it is currently offering.
press_cube_lock() {
    python3 scripts/status-item-click.py >/dev/null 2>&1
    sleep 0.8
    press toggle-cube-lock
    sleep 1.5
}

grey "  the cube says: $(status_row)"

if [[ "$(status_row)" != *"is locked"* ]]; then
    # Locked deliberately, so the badge is checked even on a run where nothing else left it locked.
    #
    # **Gated on the same setting the app gates it on.** `pause_on_lock` decides whether locking from the app means
    # anything at all, and with it off `CubeLock.lock` sends nothing -- so this would sit waiting for a state the app
    # is deliberately refusing to reach.
    if [ "$(sql "SELECT json_extract(setting_value, '\$.enabled') FROM setting WHERE setting_name = 'pause_on_lock';")" = "1" ]; then
        locking=$(mark)
        press_cube_lock
        # **The pause goes first and is confirmed first, and that order is load-bearing**: a locked cube reports
        # itself paused whatever its pause byte says, so a pause confirmed after the lock would be confirming nothing.
        expect_log "the dropdown's Lock item pauses the cube first" "$locking" "The cube is paused" 20
        expect_log "and then locks it" "$locking" "The cube is locked" 20
    else
        skip "pause_on_lock is off, so the app will not lock from here and the badge cannot be raised"
    fi
fi

if [[ "$(status_row)" == *"is locked"* ]]; then
    # **Repainted the moment the answer moved, not on the item's next tick.** The tick only runs while the app itself
    # is timing, and locking pauses the cube -- so the state the badge exists for is exactly the state nothing else
    # would redraw. This passing is what says `radio.onCubeStatus` is wired to the menu bar.
    check_contains "the menu bar says the cube is locked" "$(status_item)" "device locked"

    unlocking=$(mark)
    python3 scripts/status-item-click.py >/dev/null 2>&1
    sleep 0.8
    # One item saying two things rather than two items, so what it currently offers is worth reading before pressing it.
    check_contains "and the dropdown offers to unlock it" "$(python3 scripts/ax-dump.py --menu-bar 2>/dev/null)" "Unlock"
    press toggle-cube-lock
    sleep 1.5

    expect_log "pressing it unlocks the cube" "$unlocking" "The cube is unlocked" 20
    # **Unlocking lifts the pause the lock applied, which the archive's Unlock deliberately did not.** There, the Pause
    # item commanded the device and could resume it separately; here the Pause item is the app's own clock and sends
    # the cube nothing, so an unlock that left it paused would leave it paused for good -- and a paused cube reports no
    # turns either, which would strand everything below.
    expect_log "and lifts the pause with it, so the cube is running again" "$unlocking" "The cube is running" 20

    case "$(status_item)" in
        *"device locked"*) fail "the menu bar still says the cube is locked" ;;
        *) pass "and the badge goes with it" ;;
    esac
else
    skip "the cube could not be got into a locked state, so the badge was not checked"
fi

# Whatever the two blocks above did, the cube has to be turnable from here or nothing below can happen at all.
if [[ "$(status_row)" == *"is locked"* ]]; then
    fail "the cube is still locked, and a locked cube silently refuses to change face"
    close_settings
    finish
    exit 1
fi

# ---------------------------------------------------------------------------- the two faces, and which to ask for
#
# **Read from the table, not written down here.** Which category a face holds is `face`'s answer, and a check that
# compared the screen against a name spelled out in this script would be agreeing with itself rather than with the app.

MEETING_FACE=2
BREAK_FACE=8
name_on_face() {
    sql "SELECT category_name FROM category WHERE category_id = (SELECT category_id FROM face WHERE face_id = $1);"
}
meeting=$(name_on_face $MEETING_FACE)
break_name=$(name_on_face $BREAK_FACE)
grey "  face $MEETING_FACE holds '$meeting', face $BREAK_FACE holds '$break_name'"

if [ -z "$meeting" ] || [ -z "$break_name" ]; then
    fail "one of the two seeded faces holds no category, so there would be no name to follow"
    close_settings
    finish
    exit 1
fi

# **Asked for the face it is not already on**, which is the archive's own correction to itself: asking for the one it
# is resting on would leave the poll with nothing to detect, and the run would sit there indefinitely while somebody
# stared at a cube that was already right.
resting=$(sql "SELECT message FROM debug_log WHERE debug_log_id > $link AND tag = 'face' AND message LIKE 'Face % is up' ORDER BY debug_log_id DESC LIMIT 1;" | sed -n 's/^Face \([0-9]*\) is up$/\1/p')
grey "  the cube is resting on face ${resting:-unknown}"
if [ "${resting:-0}" = "$BREAK_FACE" ]; then
    first_face=$MEETING_FACE; first_name="$meeting"
    second_face=$BREAK_FACE;  second_name="$break_name"
else
    first_face=$BREAK_FACE;   first_name="$break_name"
    second_face=$MEETING_FACE; second_name="$meeting"
fi

# The Faces tab draws the cube, and it has to be the tab on show *before* the turn rather than after it: the window
# redraws the pane it is looking at, so switching to it afterwards would prove only that opening a tab reads the
# database, which `03` already covers. Left here for both turns.
select_tab Faces

# ---------------------------------------------------------------------------- what a turn has to produce
#
# Both turns are checked the same way, and the second is not a repeat: the first could pass on the read taken when the
# link came up, and only a second turn says the app is following the cube rather than having asked it once.

check_turn() {
    local face="$1" name="$2" base="$3" tab_name item

    expect_log "the app is told the cube is on face $face" "$base" "Face $face is up" 5

    # The tab, read from the element rather than from anything this script remembers.
    tab_name=$(element timing-category-name | sed -n 's/.*value=\(.*\)$/\1/p')
    check "the Faces tab names the category on that face" "$name" "$tab_name"

    # **The cube is actually drawn**, rather than a name changing over an empty column. This is the only place the
    # suite addresses an image view by name; both are `NSImageView`s carrying an AXIdentifier, so both should be in
    # the tree whenever there is a face to draw.
    check_contains "and draws the cube for it" "$(tree)" "timing-device-face"
    check_contains "with the category's icon on its centre face" "$(tree)" "timing-centre-icon"

    # **The lock, and it is on**: faces 2 and 8 are the two `008_face.sql` seeds locked, which is why they are also the
    # two this script uses. So the lock is drawn here, and the category rows beside it are dead -- one fact drawn
    # twice, which is what `FacesTabRules` exists to guarantee.
    check_contains "the face's lock is drawn on the cube" "$(tree)" "timing-face-lock"
    check_contains "and it says what pressing it would do" "$(element timing-face-lock)" "Unlock face"
    local row
    row=$(sql "SELECT category_id FROM face WHERE face_id = $face;")
    case "$(element "category-row-$row")" in
        *disabled*) pass "so the category rows are dead, which is what says the click would be refused" ;;
        *) fail "the face is locked but the category rows are still live" ;;
    esac

    # The menu bar, which is the half that was wrong. Read as the whole line: the name is in the drawn title and again
    # in the spoken description, and either one carrying it is the item saying it.
    item=$(status_item)
    grey "  $item"
    check_contains "the menu bar names the same category" "$item" "$name"

    # **The two compared against each other, not each against a literal.** Both being wrong in the same way is the only
    # failure this cannot see, and both being wrong in *different* ways is exactly the fault that shipped.
    check_contains "so both surfaces agree about what the cube is on" "$item" "$tab_name"

    # **The figure, on both, and it is the same one.** It is the category's total for the day out of `time_entry`,
    # which is the archive's own menu-bar figure. What it reads depends on what the cube has done today and on how
    # much of its history has been ingested and closed out into entries, so what is checked is that the two surfaces
    # carry the *same* string, not any particular value.
    #
    # The glyph beside it is checked on the tab rather than in the menu bar line, where every image is the same
    # character in text and one cannot be told from another. It says what the *cube* is doing, which is a fact the app
    # has only because it asked -- so a cube that has not answered draws none, and that is a pass too.
    local figure
    figure=$(element timing-face-elapsed | sed -n 's/.*value=\(.*\)$/\1/p')
    if [ -n "$figure" ]; then
        pass "the Faces tab shows the category's total under its name ($figure)"
    else
        fail "no figure under the name on the Faces tab"
    fi
    check_contains "and the menu bar shows the same one" "$item" "$figure"

    # **The history is fetched on every flip**, which is how the app finds out what the cube has been doing -- and it
    # replaces the `0x10` this script used to expect here. A flip is a moment the cube may have been handled, and the
    # history answers both questions at once: which segments have finished, and whether the open one is paused. A
    # double tap arrives as an interval filed for `Side + 128`, so nothing has to ask about pause separately.
    expect_log "the app fetches the cube's history after the turn" "$base" "Fetching history (the cube was turned)%" 20
    if [ -n "$(element timing-face-glyph)" ]; then
        pass "and the tab draws whether the cube is running or paused"
    else
        grey "  no glyph: the cube's history has not said whether it is paused"
    fi

    # **The turn is filed**, which is the half that changed when ingestion landed: this used to check that *nothing*
    # was recorded against a cube's face, because filing what the cube had been doing was a feature the app did not
    # have. It has it now, so the same line asserts the opposite.
    #
    # Waited on rather than read once. The rows arrive from a stream of notifications a few frames long, and the log
    # row above says the fetch began rather than that it landed. `MIN(1, COUNT(*))` because what is being waited for
    # is "any row at all", and how many the stream brings depends on what the cube was doing before anybody asked.
    if wait_for_value \
        "SELECT MIN(1, COUNT(*)) FROM device_event WHERE device_event_id > $events_before AND device_face = $face;" \
        "1" 20
    then
        pass "and the turn is filed in device_event against face $face"
    else
        fail "the cube's own record of the turn never reached device_event"
    fi
}

# ---------------------------------------------------------------------------- the first turn

base=$(mark)
if ask_and_detect \
    "SELECT message FROM debug_log WHERE debug_log_id > $base AND tag = 'face' AND message = 'Face $first_face is up';" \
    "Turn the cube so the $first_name face is up" \
    "That is face $first_face. Take as long as you like: this waits, it does not time out." \
    "Nothing else needs touching -- leave the Settings window where it is."
then
    check_turn "$first_face" "$first_name" "$base"
else
    skip "nobody was there to turn the cube, so the first turn was not checked"
fi

# ---------------------------------------------------------------------------- and back again
#
# The one that matters. A single turn could be the app having read the face once when the link came up; this is what
# says both surfaces are following the cube.

base=$(mark)
if ask_and_detect \
    "SELECT message FROM debug_log WHERE debug_log_id > $base AND tag = 'face' AND message = 'Face $second_face is up';" \
    "Now turn it back, so the $second_name face is up" \
    "That is face $second_face -- the other of the two." \
    "This is the turn that says the app is following the cube rather than having asked it once."
then
    check_turn "$second_face" "$second_name" "$base"
else
    skip "nobody was there to turn the cube back, so the second turn was not checked"
fi

# ---------------------------------------------------------------------------- and it goes with the link
#
# The face is not stored anywhere and must not outlive the connection it describes: a remembered face is a claim about
# where a cube is resting that nobody is in a position to check. Forgetting the device is the shortest way to drop the
# link.

select_tab Device
since=$(mark)
press device-forget
sleep 1.5

expect_log "letting the cube go takes the face with it" "$since" "The face goes with the link"

# Read back on the Faces tab, which reads the database as it opens: with no cube there is no face, so there is no cube
# to draw. A tab still holding artwork here would be the held-copy fault the whole design is arranged against.
select_tab Faces
case "$(tree)" in
    *timing-device-face*) fail "the Faces tab is still drawing a cube nothing is connected to" ;;
    *) pass "and the Faces tab stops drawing one" ;;
esac

close_settings
finish
