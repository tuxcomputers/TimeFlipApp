#!/bin/bash
# The status item's right half with a cube on the other end: a single click stops the cube and starts it again, a
# double click locks it and unlocks it.
#
# **What needs a real cube is the round trip.** Which gesture a click is comes out of `StatusItemClickRouter` and
# which command to send comes out of `CubeLock`, both pinned in `swift test` with no radio anywhere near them. What
# cannot be tested there is any of the rest of it: that a status item delivers a `clickCount` of 2 at all, that the
# deferred single click is really cancelled by the second one rather than merely scheduled to be, that the cube
# honours `0x06` and answers `0x10` the way the app then believes, and that both surfaces come to say so afterwards.
#
# **The direction of the flip is read from `device_event`, not from the cube.** The app already holds the cube's own
# account of what it is doing -- `HistoryIngestor` files a paused stretch as the interval the cube reports for
# `Side + 128` -- so a click flips what the glyph beside it is drawing. That is the fact this script is built around:
# every check below reads the table or a surface, never a claim the app made about itself in passing.
#
# **A locked cube is not pausable and that is a check, not a limitation.** A locked cube reports itself paused
# whatever its pause byte says (`docs/timeflip.md`), so a pause sent while it is locked could never be read back. The
# single click refuses, says so, and the double click is the way out.
#
# **Runs after `19`, and before the wipe in `99`.** It needs a live link, and `19` leaves the radio on and the device
# forgotten, so there is nothing here to inherit.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
start "pausing and locking the cube from the status item"

if ! device_required; then
    skip "no TimeFlip was made available, so there is nothing to pause"
    finish
    exit 0
fi

# ---------------------------------------------------------------------------- a cube to click at

link=$(mark)
if ! pair_a_cube; then
    skip "no cube could be paired, so there is nothing to pause ($PAIR_REASON)"
    finish
    exit 0
fi
pass "paired a cube to click at"

# **The clock, before anything else the connection does.** The cube stamps every history frame with its own clock, so
# one that has never been told the time has nothing to date an interval with -- and a factory reset clears it, which
# `15-device-reset` does. This app sent `0x08` nowhere at all until 2026-08-21.
expect_log "the cube's clock is set as the first thing after the link is confirmed" "$link" "Setting the cube's clock to %" 30
expect_log "and the cube's own answer confirms it" "$link" "The cube's clock is set" 30

# **What the cube says about its own condition**, which the app subscribed to and dropped until 2026-08-21. The row is
# what tells a reset cube apart from one whose flash memory has failed -- and a flash fault means it records no history
# at all, which from the outside looks exactly the same.
expect_log "the cube is asked how it is, and says" "$link" "The cube says%" 30

# **The lock, waited for by its answer rather than by its question.** `0x10` is the last thing the connection does, so
# at this point in the script it is the row most likely still in flight -- and `status_row` below decides from it which
# way the Lock item is currently pointing. `18-device-face` read that answer 118ms too early on 2026-08-22 and spent
# twenty seconds waiting for a pause that was never going to be sent. See `Tests/Methods.md`, under the notes.
expect_log "and says whether it is locked, which is what the clicks below are aimed at" "$link" \
    "The cube is %ocked and %" 30

# **The characteristic the whole feature stands on**, checked first because everything below reads as a different
# fault without it. The login discovery asks for the three characteristics a login needs, so `F1196F58` is not in its
# answer and only the listening phase can find it -- and when it was picked up in the wrong one, every fetch reported
# "no history characteristic" while the cube had one, the glyph never appeared on either surface, and the single click
# sent a pause it could never reverse. Nothing in `swift test` can see this: a `CBPeripheral` cannot be built outside
# CoreBluetooth, so discovery has no seam a hermetic test can reach.
expect_log "the cube's history characteristic is found when the link comes up" "$link" \
    "The cube's history characteristic is there%" 30

# **And it is asked at once, because the link came up.** Not because of anything else that happens to follow a login:
# the fetch used to ride on the face read, so the log claimed the cube had been turned when it had been sitting still,
# and a cube whose faces characteristic went missing would have brought back no history at all until the timer fired.
expect_log "the cube reports itself ready to be asked" "$link" "The cube is ready to be asked things" 30
expect_log "and its record of the day is asked for straight away" "$link" "Fetching history (the link came up)%" 30
if wait_for_value "SELECT MIN(1, COUNT(*)) FROM device_event WHERE device_face BETWEEN 1 AND 12;" "1" 30; then
    pass "so the cube's own segments reach device_event without anybody touching it"
else
    fail "no cube segment ever reached device_event, so there is nothing for the glyph to draw"
fi

# **`19` leaves manual mode on**, and pairing is what ends it (`SettingsWindowController`). Reported rather than
# asserted, because it is only on at all when `19` actually ran -- but it is the first thing to look at if the
# routing check below fails, since a click in manual mode is routed to the app's own clock instead of the cube.
grey "  $(sql "SELECT message FROM debug_log WHERE debug_log_id > $link AND tag = 'mode' AND message LIKE 'Manual mode:%' ORDER BY debug_log_id DESC LIMIT 1;")"

# What the cube last said about itself. Written by `BluetoothRadio` and only when the answer is news, which is enough:
# the ask made when a link comes up always writes one, since the held status is cleared with the connection.
status_row() {
    sql "SELECT message FROM debug_log WHERE debug_log_id > $link AND tag = 'command' AND message LIKE 'The cube is %ocked and %' ORDER BY debug_log_id DESC LIMIT 1;"
}

# The status item's own line. Matched through the spoken description rather than the drawn title: the glyph is an
# image attachment and every attachment is the same character in text, so a title cannot tell a pause apart from a
# category icon. `StatusItemTitle` spells "device paused" and "device running" into the spoken form, which is what
# makes it assertable at all.
status_item() {
    python3 scripts/ax-dump.py --menu-bar 2>/dev/null | grep -m1 "id=status-item" || true
}

# Whether the cube is stopped, as the app's own record has it. The open segment is what both surfaces draw from.
open_paused() {
    sql "SELECT paused FROM device_event WHERE finalised = 0 ORDER BY start_epoch DESC, device_event_id DESC LIMIT 1;"
}

click_right()        { python3 scripts/status-item-click.py --right >/dev/null 2>&1; }
double_click_right() { python3 scripts/status-item-click.py --right --double >/dev/null 2>&1; }

# ---------------------------------------------------------------------------- a known starting state
#
# **Unlocked, or nothing below means anything**: a locked cube refuses the pause on purpose, which is checked further
# down but would swallow every check before it.

if [[ "$(status_row)" == *"is locked"* ]]; then
    unlocking=$(mark)
    python3 scripts/status-item-click.py >/dev/null 2>&1
    sleep 0.8
    press toggle-cube-lock
    sleep 1.5
    expect_log "the cube starts the run unlocked" "$unlocking" "The cube is unlocked" 20
fi

if [[ "$(status_row)" == *"is locked"* ]]; then
    fail "the cube is still locked, and a locked cube refuses the pause this script is about"
    finish
    exit 1
fi

# The app has to have ingested something before the direction of the first click means anything. A cube reset and not
# yet flipped has no open segment at all, which the app treats as running -- a true answer, but not one this script
# can predict, so it is reported rather than assumed.
grey "  the app's record says the cube is $( [ "$(open_paused)" = "1" ] && echo "paused" || echo "running" )"

# ---------------------------------------------------------------------------- one click stops it
#
# **The pause is deferred by the system's double-click interval**, so a second click can still cancel it. Every wait
# below therefore has that interval in it before anything is sent, which is why none of them are tight.

was_paused=$(open_paused)
[ "$was_paused" = "1" ] && wanted="running" || wanted="paused"

since=$(mark)
click_right
expect_log "a single click on the right half is routed as a cube pause" "$since" \
    "Status item clicked: side=right clicks=1%toggleCubePause" 10
if [ "$was_paused" = "1" ]; then
    expect_log "and the cube is started again, because the record said it was stopped" "$since" "The cube is running" 20
else
    expect_log "and the cube is stopped, because the record said it was running" "$since" "The cube is paused" 20
fi

# **The fetch is not tidying up, it is how the app finds out.** Nothing notifies after `0x06`, so without it the open
# segment would go on reporting the old state until the timer next fired -- which a shipped build floors at a minute.
expect_log "the app fetches the history straight afterwards" "$since" \
    "Fetching history (the cube was paused from the menu bar)%" 20

[ "$was_paused" = "1" ] && want_flag="0" || want_flag="1"
if wait_for_value "SELECT paused FROM device_event WHERE finalised = 0 ORDER BY start_epoch DESC, device_event_id DESC LIMIT 1;" "$want_flag" 25; then
    pass "and the cube's own record of it reaches device_event, which now reads $wanted"
else
    fail "device_event still says the cube is $( [ "$want_flag" = "1" ] && echo "running" || echo "paused" )"
fi

# Both surfaces, and they are read rather than inferred: the whole point of taking the direction from the table is
# that the click flips what is drawn.
check_contains "the menu bar says the cube is $wanted" "$(status_item)" "device $wanted"
open_settings
select_tab Faces
# The glyph is a symbol, and a symbol is one character to anything reading the tree, so what is matched is the label
# beside it -- `TimingView` says "Device paused" or "Device running" in words for exactly this reason.
check_contains "and the Faces tab draws the same" "$(element timing-face-glyph)" "Device $wanted"

# ---------------------------------------------------------------------------- and one click starts it again
#
# The one that matters. A single click could have been the app sending whatever it always sends; this is what says
# the direction came out of the record rather than being written down somewhere.

since=$(mark)
click_right
if [ "$was_paused" = "1" ]; then
    expect_log "clicking again stops it" "$since" "The cube is paused" 20
    back="paused"
else
    expect_log "clicking again starts it" "$since" "The cube is running" 20
    back="running"
fi
if wait_for_value "SELECT paused FROM device_event WHERE finalised = 0 ORDER BY start_epoch DESC, device_event_id DESC LIMIT 1;" "$was_paused" 25; then
    pass "and the record goes back to where it started"
else
    fail "device_event did not follow the second click"
fi
check_contains "with the menu bar following it back" "$(status_item)" "device $back"

close_settings

# ---------------------------------------------------------------------------- two clicks lock it
#
# **Gated on the same setting the app gates it on.** `pause_on_lock` decides whether locking from the app means
# anything at all, and with it off `CubeLock.lock` sends nothing -- so this would sit waiting for a state the app is
# deliberately refusing to reach.

if [ "$(sql "SELECT json_extract(setting_value, '\$.enabled') FROM setting WHERE setting_name = 'pause_on_lock';")" != "1" ]; then
    skip "pause_on_lock is off, so the app will not lock from here and the double click has nothing to do"
    finish
    exit 0
fi

since=$(mark)
double_click_right
expect_log "a double click is routed as a lock rather than a pause" "$since" \
    "Status item clicked: side=right clicks=2%toggleCubeLock" 10

# **The check the deferral exists for.** AppKit sends the action for the first click of a pair with a count of 1, so
# without the cancellation a double click would pause the cube *and* lock it. This row is the cancellation happening.
expect_log "and the pause the first click scheduled is dropped rather than also sent" "$since" \
    "The waiting cube pause was dropped: a second click made it a lock" 10

# **The pause goes first and is confirmed first, and that order is load-bearing**: a locked cube reports itself paused
# whatever its pause byte says, so a pause confirmed after the lock would be confirming nothing.
expect_log "the lock pauses the cube first" "$since" "The cube is paused" 20
expect_log "and then locks it" "$since" "The cube is locked" 20
check_contains "the menu bar shows the lock" "$(status_item)" "device locked"

# ---------------------------------------------------------------------------- and a click on a locked cube does nothing

since=$(mark)
click_right
expect_log "a single click on a locked cube is refused, and says why" "$since" \
    "The cube is locked, so pausing it means nothing; unlock it first" 10
check "and nothing was put on the wire for it" "0" \
    "$(sql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND tag = 'command' AND message LIKE 'Sending 06 %';")"

# ---------------------------------------------------------------------------- and two more unlock it

since=$(mark)
double_click_right
expect_log "a second double click unlocks the cube" "$since" "The cube is unlocked" 20
# Unlocking lifts the pause the lock applied, which the archive's Unlock deliberately did not: there, the Pause item
# commanded the device and could resume it separately; here it is the app's own clock, so an unlock that left the cube
# paused would leave it paused for good.
expect_log "and lifts the pause with it" "$since" "The cube is running" 20
expect_log "then fetches the history, so the glyph is not a minute behind" "$since" \
    "Fetching history (the cube was unlocked from the menu bar)%" 20

case "$(status_item)" in
    *"device locked"*) fail "the menu bar still shows the cube as locked" ;;
    *) pass "and the lock goes from the menu bar with it" ;;
esac

finish
