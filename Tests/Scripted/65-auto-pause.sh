#!/bin/bash
# The cube's auto-pause delay, stepped on the Device tab, sent as 0x05, read back with 0x10, and only then written down.
#
# **What needs a real cube is the sequence, not the bytes.** Which bytes `0x05` carries and what a `0x10` answer has to
# say to count as a confirmation are `DeviceCommandRules`, pinned in `swift test` with no radio in sight. What cannot be
# tested there is the order the first rule in `CLAUDE.md` is about: the cube is told, the cube is asked, and the table
# is written only once the cube's own answer agrees. An app that wrote the row beside the send would pass every unit
# test in the repo and would be recording its own wish as the cube's state.
#
# **This one is confirmed rather than acknowledged, which is where it differs from `63`.** The LED pair have no read
# command in the spec at all, so what the app calls success there is the cube taking the bytes. Auto-pause has `0x10`,
# which reports the delay the cube is set to, so the row this script waits for is the cube saying what it is on rather
# than the app saying what it sent.
#
# **A cube is needed to change this setting at all**, which is worth knowing before reading a failure here: with
# nothing connected the command cannot go, so the field goes back and the table keeps what it had. The same is true of
# every other writing row on the tab.
#
# **Runs after `64`, which leaves a launched app logged in to the cube, and before the wipe in `99`.**
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
# What this script checks when everything passes. See `finish` in lib.sh for what a mismatch means.
EXPECTED_CHECKS=13
start "the cube auto-pause delay, sent to the cube, read back, and then written down"

# **No cube check here.** `00-setup` asked once and `50-device-scan` stops the run if the answer was no, so anything
# reaching this line has a cube.

# ---------------------------------------------------------------------------- arranging, not checking
#
# **The row is put back to its seed before anything opens.** Every pattern below names the number it expects, and a run
# inheriting a delay somebody left at 5 would step to 6 and match nothing.
#
# **Written with the window shut**, which is what makes it safe. An open Settings window is the source of truth for what
# it shows (`CLAUDE.md`), so writing underneath one would be the two-answers problem this script exists to check for.

close_settings
sql "UPDATE setting
        SET setting_value = json_set(setting_value, '\$.minutes', 0)
      WHERE setting_name = 'auto_pause_minutes';"
step "the auto-pause row starts at 0, which is off"

open_settings
select_tab Device

require_a_paired_cube "there is no cube to send an auto-pause delay to"

# **A precondition rather than a second copy of the claim.** That the field follows `isCubeConnected` is `56`'s, which
# reads it live and then dead either side of one drop; what this needs to know is only that the arrows below can be
# pressed at all, since a refusal from a dead control would look exactly like a cube refusing a command.
check "the Auto-pause field is live, so the presses below mean something" "0" \
    "$(tree | grep -cE "id=device-auto-pause[[:space:]].*disabled" || true)"

# ---------------------------------------------------------------------------- turning it on
#
# **The arrow rather than the field**, as `08-app-settings`, `59-double-tap` and `63` do: the arrows are what a person
# uses, and what the field ends up holding is read back out of the table anyway.
#
# **0x05 0x00 0x01 is one minute, high byte then low.** The order is the archive's and the way round `0x10` answers, so
# a transposition would show up here as 256 minutes on the wire.

since=$(mark)
press device-auto-pause-up
expect_log "stepping Auto-pause sends 0x05 to the cube" "$since" \
    "command withResponse: 05 00 01"
expect_log "and the app says what it sent" "$since" \
    "Auto-pause: sending 1m"
expect_log "and asks the cube whether it took, rather than believing the write" "$since" \
    "Asking whether it took: 10" 30
expect_log "and the cube's own answer is what confirms it" "$since" \
    "The cube confirms it took: auto-pause 1m" 30
expect_log "and only then is the row written" "$since" \
    "Auto-pause: the table now holds 1m" 30

# **The order of those last two, read as row ids rather than trusted from the order they were waited for.**
# `expect_log` polls, so two patterns can both match rows that arrived the other way round -- and the whole of what this
# script adds over `swift test` is that the table follows the cube rather than accompanying it.
confirmed=$(dsql "SELECT MIN(debug_log_id) FROM debug_log WHERE debug_log_id > $since AND message LIKE 'The cube confirms it took: auto-pause 1m';")
stored=$(dsql "SELECT MIN(debug_log_id) FROM debug_log WHERE debug_log_id > $since AND message LIKE 'Auto-pause: the table now holds 1m';")
if [ -n "$confirmed" ] && [ -n "$stored" ] && [ "$stored" -gt "$confirmed" ]; then
    pass "the table was written after the cube confirmed it, not beside it"
else
    fail "the confirmation was row ${confirmed:-none} and the write row ${stored:-none}"
fi

wait_for_value "SELECT json_extract(setting_value, '\$.minutes') FROM setting WHERE setting_name = 'auto_pause_minutes';" "1" 10
check "the table holds the stepped delay" "1" "$(setting auto_pause_minutes minutes)"

# ---------------------------------------------------------------------------- turning it off again
#
# **0 is the vendor protocol's own way of disabling it**, not an absence: `0x05 0x00 0x00` is a command like any other
# and the cube answers `0x10` with 0 minutes. So this is a real round trip rather than the app declining to send, and
# it puts the seeded row back on the way past.

since=$(mark)
press device-auto-pause-down
expect_log "stepping it back to zero sends the delay off" "$since" \
    "command withResponse: 05 00 00"
expect_log "and the cube confirms it is off" "$since" \
    "The cube confirms it took: auto-pause 0m" 30
wait_for_value "SELECT json_extract(setting_value, '\$.minutes') FROM setting WHERE setting_name = 'auto_pause_minutes';" "0" 10
check "and the row is back to 0, which is off" "0" "$(setting auto_pause_minutes minutes)"

# ---------------------------------------------------------------------------- the floor
#
# **0 is the bottom of the field's range** (`DeviceCommandRules.autoPauseRange`), which the command clamps to as well.
# A step that cannot move reports nothing, so what is checked is that nothing at all went out: a field that sent its
# floor again on every press would be a command and a read-back per click for no change.

since=$(mark)
press device-auto-pause-down
sleep 2
check "stepping below zero sends nothing" "0" \
    "$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND message LIKE 'Auto-pause: sending%';")"
check "and leaves the row where it was" "0" "$(setting auto_pause_minutes minutes)"

close_settings
finish
