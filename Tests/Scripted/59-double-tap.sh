#!/bin/bash
# The cube's double tap, which this app turns off and never turns back on.
#
# **The gesture is gone from the app entirely** (owner's decision, 2026-09-11). There is no control on the Device
# tab, nothing reads `double_tap_settings`, and `DoubleTapRules.alwaysSent` is the only thing ever sent: the
# factory registers with `window` at 0.
#
# **Why it is worth the trouble of sending anything at all.** A double tap stops the cube's tracking *in firmware
# with no command involved* (finding 11, `docs/timeflip2-firmware-observations.md`). It produces no face change,
# writes no command result, and `systemState` does not carry it, so nothing can tell the app it happened: the app
# finds out on its next history fetch and not before. Off, that state cannot arise.
#
# **What this checks is that the cube is off and is left alone, which is not what it checked first.** The
# rewrite of 2026-09-11 tried to check the correction firing, and run 180 proved that cannot be arranged: the
# registers survive a factory reset (finding 11a, measured that day), so once the gesture is off there is
# nothing in the app or this suite that can put it back. The check that wanted a disagreement waited 60s for one
# and failed. What is left is the property that actually matters on every connection.
#
# **`0x16` never going out is the half a blind send would get wrong.** `0x17` answers the question, so the app
# compares and writes only on a disagreement; a version that sent on every connection would pass a check that
# only looked for the gesture being off, and would spend a flash write each time.
#
# **Runs after `58`, which leaves a launched app logged in to the cube, and before the wipe in `99`.**
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
# What this script checks when everything passes. See `finish` in lib.sh for what a mismatch means.
#
# **Four, not three: the relink's own `pass` counts.** Declared as three in the rewrite and run 181 stopped the
# whole suite on the mismatch with nothing actually wrong, which is `finish` working as intended.
EXPECTED_CHECKS=4
start "the cube's double tap, which is off and is left alone"

require_a_paired_cube "there is no cube to ask about its double tap"

# ---------------------------------------------------------------------------- a fresh login, and what it asks
#
# **The link is put down and brought back up** so the reads below belong to a login this script watched, rather
# than to one some earlier script made. `relink_a_cube` quits the app and starts it again.

since=$(mark)
if relink_a_cube; then
    pass "the app got back to the cube"
else
    fail "the app could not get back to the cube, so there is nothing to ask about its registers"
    finish
    exit 1
fi

# **Read on every connection, which is what makes the write unnecessary.** `0x16` has an answer of its own in
# `0x17` and `CLAUDE.md` requires a command with one to be read back rather than believed.
expect_log "the login asks the cube what its registers are" "$since" \
    "The double tap on the cube is set to%" 60

# **Window 0 is the gesture off**, the hardware having no switch for it: the vendor spec defines no command that
# disables double tap and the archive measured the same (finding 11). The other three are the factory values.
# This is the hardware's own answer rather than anything the app remembers.
reported=$(dsql "SELECT message FROM debug_log WHERE debug_log_id > $since AND message LIKE 'The double tap on the cube is set to%' ORDER BY debug_log_id DESC LIMIT 1;")
check "and the cube says the gesture is off" \
    "The double tap on the cube is set to Threshold: 90, Limit: 20, Latency: 50, Window: 0" "$reported"

# ---------------------------------------------------------------------------- and it is left alone
#
# **A cube already off is told nothing.** The comparison is against `DoubleTapRules.alwaysSent`, so a cube
# running those registers costs no write at all. Counted rather than waited for: the claim is that nothing
# happened, and a wait can only ever time out to say so.
check "so nothing is written to it" "0" \
    "$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND message LIKE '%16 3A%';")"

finish
