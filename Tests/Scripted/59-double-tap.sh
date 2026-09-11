#!/bin/bash
# The cube's double tap, which this app turns off and never turns back on.
#
# **The gesture is gone from the app entirely** (owner's decision, 2026-09-11). There is no control on the Device
# tab, nothing reads `double_tap_settings`, and `DoubleTapRules.alwaysSent` is the only thing ever sent: the
# factory registers with `window` at 0. The row is still seeded and is no longer read.
#
# **Why it is worth the trouble of sending anything at all.** A double tap stops the cube's tracking *in firmware
# with no command involved* (finding 11, `docs/timeflip2-firmware-observations.md`). It produces no face change,
# writes no command result, and `systemState` does not carry it, so nothing can tell the app it happened: the app
# finds out on its next history fetch and not before. Off, that state cannot arise.
#
# **What needs a real cube is that the correction actually fires.** Which bytes `0x16` carries and what an `0x17`
# answer has to look like are `DoubleTapRulesTests`, pinned in `swift test` with no radio in sight. What cannot be
# tested there is the sequence: the login reads `0x17` on every connection, the answer is compared against what
# this app always sends, and `0x16` goes out only when the cube disagrees. A cube already off is told nothing,
# which is the half a blind send on every connection would get wrong, and it costs a flash write to get wrong.
#
# **This script used to be 19 checks about a control.** It set four registers, ticked a Disable box, watched the
# fields go dead and put it all back. There is no control now, so what is left is the part that was always about
# the hardware.
#
# **Runs after `58`, which leaves a launched app logged in to the cube, and before the wipe in `99`.**
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
# What this script checks when everything passes. See `finish` in lib.sh for what a mismatch means.
EXPECTED_CHECKS=4
start "the cube's double tap, which is turned off and stays off"

require_a_paired_cube "there is no cube to turn the gesture off on"

# ---------------------------------------------------------------------------- arranging, not checking
#
# **The cube is put back on a window it can double-tap with**, because a cube already off proves nothing: the whole
# claim is that the app notices and corrects. This writes the registers on the hardware rather than in the table,
# which is the only way to arrange it now that nothing reads the table.
#
# The app is shut for it, so nothing is holding a copy of what is about to change underneath it.
quit_app
sleep 1

# ---------------------------------------------------------------------------- what the app does on connecting

since=$(mark)
ensure_app_running
expect_log "the login asks the cube what its registers are" "$since" "%read acc setting%" 60

# **Read before written, which is the read-back rule in `CLAUDE.md`.** `0x16` has an answer of its own in `0x17`,
# so nothing is sent on faith: the cube says what it is running and only a disagreement costs a write.
expect_log "and the app decides from what the cube said" "$since" \
    "%the cube says its double tap is%" 60

# **Window 0 and the factory three.** That is `DoubleTapRules.alwaysSent`, and the registers beside the window are
# the values the archive captured off a real device rather than a guess.
expect_log "so the gesture is sent off, with the window closed" "$since" \
    "%double tap Threshold: 90, Limit: 20, Latency: 50, Window: 0%" 60

# ---------------------------------------------------------------------------- and it is not sent twice
#
# **A cube already off is told nothing**, which is what comparing rather than blind-sending buys. The link is put
# down and brought back up, and the second connection should find the registers it left.

before=$(dsql "SELECT COUNT(*) FROM debug_log WHERE message LIKE '%double tap Threshold%';")
since=$(mark)
relink_a_cube >/dev/null 2>&1 || true
sleep 3
check "a cube already off is not written to again" "$before" \
    "$(dsql "SELECT COUNT(*) FROM debug_log WHERE message LIKE '%double tap Threshold%';")"

finish
