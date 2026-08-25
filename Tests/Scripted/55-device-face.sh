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
# **The cube is put into a known state first -- unlocked and running -- and that is the archive's finding rather than
# tidiness.** A locked cube silently refuses to change face, so asking for a turn while it is locked would wait for
# ever with nothing to detect (`01i` Scenario A, Step 3, which found exactly that and had to unlock before it could
# carry on). A paused cube fails differently and later: it still reports the turn, so the prompt is satisfied, but it
# files no history for it. Neither is a precaution: `53-device-reconnect` quits the app, and quitting pauses and locks
# the cube whenever `pause_on_lock` is on, which is what the DDL seeds.
#
# **Runs after `54`, and before the wipe in `99`.** It needs a live link and it needs a person, so it sits with the
# other device scripts rather than out on its own.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
# What this script checks when everything passes. See `finish` in lib.sh for what a mismatch means.
EXPECTED_CHECKS=46
start "the face the cube is on, and both places drawing the same one"

# **No cube check here.** `00-setup` asked once and `50-device-scan` stops the run if the answer was no, so
# anything reaching this line has a cube: every script between them needs one, and none of them runs after 50
# has failed. A second gate here would be a branch that can never be taken, and an untaken branch is checks
# that silently do not run.

open_settings
select_tab Device

# ---------------------------------------------------------------------------- a cube to turn
#
# Paired from scratch, for the reason `52`, `53` and `54` all give: a script that inherited an earlier one's pairing
# would silently test nothing whenever that one skipped. `54` ends by forgetting the device anyway, so there is
# nothing here to inherit.

link=$(mark)
if ! pair_a_cube; then
    pair_verdict "there is no face to read"
    close_settings
    finish
    exit $?
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
# **Both directions, on every run, by normalising first rather than by branching.** Whichever state the cube is found
# in it is unlocked, and only then locked and unlocked again -- so the two presses below are the same two presses on
# every run, in the same order, whatever `53`'s quit happened to leave. Branching on the state found instead meant the
# lock direction went untested on exactly the runs where it mattered most: `53` quits the app, quitting locks the cube
# whenever `pause_on_lock` is on, and the DDL seeds it on, so the full-run case was the one that skipped the lock.

# What the cube last said about itself, from this connection onwards. Written by `BluetoothRadio` and only when the
# answer is news, which is enough: the ask made when a link comes up always writes one, since the held status is
# cleared with the connection.
status_row() {
    dsql "SELECT message FROM debug_log WHERE debug_log_id > $link AND tag = 'command' AND message LIKE 'The cube is %ocked and %' ORDER BY debug_log_id DESC LIMIT 1;"
}

# The status item's own line, which is where the lock badge shows up. Matched through the spoken description rather
# than the drawn title: the badge is an image attachment and every attachment is the same character in text, so a
# title cannot tell a lock apart from a category icon. `setAccessibilityLabel(title.spoken)` spells it out, which is
# what makes it assertable at all.
status_item() {
    python3 scripts/ax-dump.py --menu-bar 2>/dev/null | grep -m1 "id=status-item" || true
}

# Opens the dropdown and presses the Lock/Unlock item, whichever one it is currently offering.
#
# **Each step is checked, because both of them can do nothing and say nothing.** A status item exposes no
# accessibility action at all, so opening the menu takes a real posted mouse event -- and a mouse event can be
# swallowed by the window server with no error anywhere. `press` then finds no `toggle-cube-lock`, because the menu
# holding it is not open, and swallows that too. What reached the log on 2026-08-23 was a check waiting twenty
# seconds for the cube to unlock, reported as the app failing to unlock it, when the app was never asked: there was
# a twenty-seven second hole in `debug_log` where the menu should have opened.
#
# So: wait for the app's own row saying the menu opened, rather than sleeping and hoping, and say plainly which of
# the two steps failed. `02-menu-bar` asserts this same row, so it is the app's established way of saying so.
press_cube_lock() {
    local since; since=$(mark)
    if ! click_left; then
        fail "the status item could not be clicked at all, so the dropdown was never asked to open"
        return 1
    fi
    if ! wait_for "$since" "%side=left%showMenu%" 5 >/dev/null; then
        fail "the status item was clicked and the dropdown did not open, so there was no Lock item to press"
        return 1
    fi
    if ! python3 scripts/ax-press.py toggle-cube-lock >/dev/null 2>&1; then
        fail "the dropdown is open but has no toggle-cube-lock item to press"
        return 1
    fi
    sleep 1.5
}

# Whether the cube is stopped, as the app's own record has it -- which is the source `CubeLock.togglePause` decides
# its direction from, so it is the one to ask before sending a click meant to go a particular way.
open_paused() {
    sql "SELECT paused FROM device_event WHERE finalised = 0 ORDER BY start_epoch DESC, device_event_id DESC LIMIT 1;"
}

# The right half, single, which is the only control the app offers for a plain resume: the dropdown's Unlock resumes
# too, but only appears on a locked cube. Deferred by the double-click interval at the far end, hence the wait.
click_right() {
    click_right
    sleep 1.5
}

grey "  the cube says: $(status_row)"

# ---------------------------------------------------------------------------- 1. unlocked, whatever it was
#
# A cube found unlocked needs nothing here; one found locked is unlocked with the item that exists for it. Either way
# the block below starts from the same place. This is not the unlock *check* -- that is step 3, on a lock this script
# applied itself, so it is testing the pair rather than clearing up after another script.

if [[ "$(status_row)" == *"is locked"* ]]; then
    clearing=$(mark)
    press_cube_lock
    expect_log "a cube found locked is unlocked first, so both directions run from one place" \
        "$clearing" "The cube is unlocked" 20
fi

if [[ "$(status_row)" == *"is locked"* ]]; then
    fail "the cube would not come out of its lock, so neither direction can be checked"
    close_settings
    finish
    exit 1
fi

# ---------------------------------------------------------------------------- 2. locked, and the badge raised
#
# **Gated on the same setting the app gates it on.** `pause_on_lock` decides whether locking from the app means
# anything at all, and with it off `CubeLock.lock` sends nothing -- so this would sit waiting for a state the app is
# deliberately refusing to reach. With it off there is no lock to undo either, so step 3 is skipped with it.

if [ "$(sql "SELECT json_extract(setting_value, '\$.enabled') FROM setting WHERE setting_name = 'pause_on_lock';")" = "1" ]; then
    locking=$(mark)
    press_cube_lock
    # **The pause goes first and is confirmed first, and that order is load-bearing**: a locked cube reports itself
    # paused whatever its pause byte says, so a pause confirmed after the lock would be confirming nothing.
    expect_log "the dropdown's Lock item pauses the cube first" "$locking" "The cube is paused" 20
    expect_log "and then locks it" "$locking" "The cube is locked" 20

    # **Repainted the moment the answer moved, not on the item's next tick.** The tick only runs while the app itself
    # is timing, and locking pauses the cube -- so the state the badge exists for is exactly the state nothing else
    # would redraw. This passing is what says `radio.onCubeStatus` is wired to the menu bar.
    check_contains "the menu bar says the cube is locked" "$(status_item)" "device locked"

    # ------------------------------------------------------------------------ 3. and unlocked again
    unlocking=$(mark)
    click_left
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
    fail "pause_on_lock is off, so the app will not lock from here and neither direction can be checked"
fi

# ---------------------------------------------------------------------------- unlocked AND running, or stop here
#
# **Two device states can strand a flip, and they strand it in different places.** A locked cube silently refuses to
# change face, so `ask_and_detect` would sit for ever with nothing to detect (`01i` Scenario A, Step 3 found exactly
# that). A cube that is merely *paused* is worse to debug: it still reports the turn on the faces characteristic, so
# the prompt is satisfied and the face check passes, but it files no history for the interval -- and `check_turn` now
# waits for the turn to reach `device_event`, so the failure lands twenty seconds later on a line about ingestion.
#
# The lock is settled by the three steps above. The pause is not: steps 2 and 3 leave the cube running as a side
# effect of the lock cycle, but both are gated on `pause_on_lock`, so a cube found unlocked-and-paused on a run with
# that setting off reaches here still paused. So it is asked here, and cleared here, rather than assumed.

if [[ "$(status_row)" == *"is locked"* ]]; then
    fail "the cube is still locked, and a locked cube silently refuses to change face"
    close_settings
    finish
    exit 1
fi

# **Asked of the app's record rather than of `status_row`, and that is deliberate.** `CubeLock.togglePause` takes its
# direction from the open segment, so a click aimed at resuming only resumes if that is what the table says. Reading
# `0x10` here and clicking on the strength of it could send a pause into a cube the app believed was already running.
if [ "$(open_paused)" = "1" ]; then
    grey "  the cube is paused, so its turns would file no history; starting it again first"
    resuming=$(mark)
    click_right
    expect_log "a cube found paused is started again, so the turns below are recorded" \
        "$resuming" "The cube is running" 20
fi

if [ "$(open_paused)" = "1" ]; then
    fail "the cube is still paused, so a turn would be reported but never recorded ($(status_row))"
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
resting=$(dsql "SELECT message FROM debug_log WHERE debug_log_id > $link AND tag = 'face' AND message LIKE 'Face % is up' ORDER BY debug_log_id DESC LIMIT 1;" | sed -n 's/^Face \([0-9]*\) is up$/\1/p')
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

    # **The two surfaces read together, and tried again if they straddle a second.** The figure counts up while the
    # cube times, so the tab and the menu bar are dumped one after another and can legitimately land either side of a
    # tick -- an equality check that did not allow for that would fail on the app being right. They disagree only for
    # as long as one dump takes, so reading the pair again is enough; three tries and no agreement is the two of them
    # genuinely saying different things, which is the fault this whole script exists for.
    local figure attempt=0 agreed=""
    while [ "$attempt" -lt 3 ]; do
        figure=$(element timing-face-elapsed | sed -n 's/.*value=\(.*\)$/\1/p')
        item=$(status_item)
        # **The empty figure is excluded rather than matched.** `*""*` matches any line at all, so a tab drawing no
        # figure would agree with a menu bar drawing none either -- passing the second check on the strength of the
        # first one failing.
        if [ -n "$figure" ]; then
            case "$item" in
                *"$figure"*) agreed=1; break ;;
            esac
        fi
        attempt=$((attempt + 1))
    done
    grey "  $item"

    # The menu bar, which is the half that was wrong. Read as the whole line: the name is in the drawn title and again
    # in the spoken description, and either one carrying it is the item saying it.
    check_contains "the menu bar names the same category" "$item" "$name"

    # **The two compared against each other, not each against a literal.** Both being wrong in the same way is the only
    # failure this cannot see, and both being wrong in *different* ways is exactly the fault that shipped.
    check_contains "so both surfaces agree about what the cube is on" "$item" "$tab_name"

    # **The figure, on both, and it is the same one.** It is the category's total for the day out of `time_entry` plus
    # the stretch still running, which is the archive's own menu-bar figure. What it reads depends on what the cube has
    # done today, so what is checked is that the two surfaces carry the *same* string, not any particular value.
    #
    # The glyph beside it is checked on the tab rather than in the menu bar line, where every image is the same
    # character in text and one cannot be told from another. It says what the *cube* is doing, which is a fact the app
    # has only because it asked -- so a cube that has not answered draws none, and that is a pass too.
    if [ -n "$figure" ]; then
        pass "the Faces tab shows the category's total under its name ($figure)"
    else
        fail "no figure under the name on the Faces tab"
    fi
    if [ -n "$agreed" ]; then
        pass "and the menu bar shows the same one"
    else
        fail "the menu bar is not showing $figure: $item"
    fi

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
    fail "nobody was there to turn the cube, so the first turn was not checked"
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
    fail "nobody was there to turn the cube back, so the second turn was not checked"
fi

# ---------------------------------------------------------------------------- the figure keeps its own time
#
# **The cube measures, this machine counts, and the row holds only what the cube said.** Between one history fetch
# and the next nothing on the wire says how long the current stretch has run, so the figure both surfaces draw is
# `time_entry` plus the open segment measured from its own `start_epoch` against this machine's clock -- which is why
# it moves second by second rather than in ten-second steps. `device_event.duration_seconds` does not move with it:
# that column is written from the cube's own frames and from nothing else, so an app that grew it from the wall clock
# would be overwriting a measurement with a guess (`DeviceEventRecorder.refreshOpenSegment`).
#
# **Both halves in one window, which is what makes this worth a device run.** `swift test` pins each of them
# separately -- `TimingReadout.Reading.isCounting`, `DayTotal.isCounting`, the two recorder refusals -- and none of it
# can see a real cube timing while a real menu bar repaints. What is checked here is the pair: the number on screen
# moved, and the row behind it did not.
#
# **Sampled just after a fetch has landed**, so both samples fall inside one gap between fetches. A sample taken
# across a fetch would find the row legitimately changed and report the feature broken.

INTERVAL=$(sql "SELECT json_extract(setting_value, '\$.seconds') FROM setting WHERE setting_name = 'fetch_history_interval_seconds';")
INTERVAL=${INTERVAL:-10}
if [ "$INTERVAL" -lt 8 ]; then
    fail "the history interval is ${INTERVAL}s, too short to read the row twice between two fetches"
    close_settings
    finish
    exit 1
fi

if [ "$(sql "SELECT json_extract(setting_value, '\$.enabled') FROM setting WHERE setting_name = 'display_seconds';")" != "1" ]; then
    fail "display_seconds is off, so the figure moves once a minute and a few seconds cannot show it moving"
    close_settings
    finish
    exit 1
fi

if [ "$(open_paused)" = "1" ]; then
    fail "the cube is paused, so its figure is standing still and there is nothing here to measure"
    close_settings
    finish
    exit 1
fi

figure_now() { element timing-face-elapsed | sed -n 's/.*value=\(.*\)$/\1/p'; }
open_cube_row() {
    sql "SELECT duration_seconds FROM device_event WHERE finalised = 0 AND device_face <= 12 ORDER BY device_event_id DESC LIMIT 1;"
}

sampling=$(mark)
if wait_for "$sampling" "Fetching history (the timer asked)%" $((INTERVAL + 15)) >/dev/null; then
    # Landed, not merely asked for: the row is written when the frames come back, and sampling between the two would
    # put the write inside the window this is about to call quiet.
    #
    # **Short waits, because the whole sample has to fit inside one gap between fetches.** Four accessibility dumps
    # go in here too and each takes a moment, so a second and then two leaves the last read a comfortable way short
    # of the next fetch on the shortest interval this section will run on.
    sleep 1
    figure_before=$(figure_now)
    menu_before=$(status_item)
    row_before=$(open_cube_row)
    sleep 2
    figure_after=$(figure_now)
    menu_after=$(status_item)
    row_after=$(open_cube_row)
    grey "  the tab read $figure_before then $figure_after, the row held $row_before then $row_after"

    if [ -n "$figure_before" ] && [ "$figure_before" != "$figure_after" ]; then
        pass "the figure on the Faces tab counts up between fetches ($figure_before -> $figure_after)"
    else
        fail "the figure did not move ($figure_before -> $figure_after), so it is not following the clock on this machine"
    fi

    if [ "$menu_before" != "$menu_after" ]; then
        pass "and the menu bar counts up with it"
    else
        fail "the menu bar line did not change, so the status item is not repainting: $menu_after"
    fi

    check "while the row the cube reported stands still" "$row_before" "$row_after"
else
    fail "no history fetch arrived in $((INTERVAL + 15))s, so there was no gap between two of them to sample"
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
