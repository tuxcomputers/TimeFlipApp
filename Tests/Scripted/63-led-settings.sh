#!/bin/bash
# The cube's LED: brightness and blink period, stepped on the Device tab, sent to the cube, and only then written down.
#
# **What needs a real cube is that the command leaves the Mac at all, and in the right order.** Which bytes `0x09` and
# `0x0A` carry is `DeviceCommandRules`, pinned in `swift test` with no radio in sight; that one field of `led_settings`
# is written without disturbing the other is `SettingStore`, pinned the same way. What cannot be tested there is the
# sequence the first rule in `CLAUDE.md` is about -- the cube is told, and the table is written only once the cube has
# taken it. An app that wrote the row beside the send would pass every unit test in the repo and would be recording
# its own wish as the cube's state.
#
# **These two are the weakest confirmation in the app, and that is the point of reading the wire.** The vendor spec
# defines no command that asks a cube what its LED is set to, so `DeviceCommandRules.readBack` answers `nil` for both
# and what the app calls success is the cube acknowledging the write. There is nothing to compare against afterwards,
# which is exactly why the `ble-tx` row is checked here rather than only the app's own account of it.
#
# **One debounce each is checked as far as it can be from here.** `WriteDebounce` holds a write until the arrows stop,
# and the two fields own one apiece because a shared queue would drop whichever write was still waiting when the other
# was scheduled (`W07-debounced-device-writes`). What this script can see is that moving both leaves both on the cube
# and in the table; whether a sub-500ms interleave drops one is below the resolution of a shell pressing buttons, and
# is not claimed.
#
# **Runs after `62`, which leaves a launched app logged in to the cube, and before the wipe in `99`.**
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
# What this script checks when everything passes. See `finish` in lib.sh for what a mismatch means.
EXPECTED_CHECKS=18
start "the cube LED: brightness and blink period, sent to the cube and then written down"

# **No cube check here.** `00-setup` asked once and `50-device-scan` stops the run if the answer was no, so anything
# reaching this line has a cube.

# ---------------------------------------------------------------------------- arranging, not checking
#
# **The row is put to its seeded pair before anything opens.** Every pattern below names the number it expects, and a
# run inheriting a brightness somebody left at 51 would step to 52 and match nothing. The same licence
# `08-app-settings` and `59-double-tap` take, and for the same reason: no control reaches an arbitrary starting state
# in one press.
#
# **Written with the window shut**, which is what makes it safe. An open Settings window is the source of truth for
# what it shows (`CLAUDE.md`), so writing underneath one would be the two-answers problem this script exists to check
# for.

close_settings
sql "UPDATE setting
        SET setting_value = json_set(setting_value, '\$.brightness', 50, '\$.blink_interval', 15)
      WHERE setting_name = 'led_settings';"
step "the LED row starts at brightness 50, blink interval 15"

open_settings
select_tab Device

require_a_paired_cube "there is no cube to send an LED setting to"

# ---------------------------------------------------------------------------- reaching the two fields
#
# **`LED` is a `DisclosureRow` inside the Settings `PanelSection`**, and like `Double tap` it starts shut. Opening
# Settings puts it back to shut however it was left, so this is unconditional rather than a state to be tolerated.

check "the LED group starts folded" "0" "$(on_tab device-led-brightness-up)"

press device-led-heading-button
sleep 1
opened=$(on_tab device-led-brightness-up)
if [ "${opened:-0}" -gt 0 ]; then
    pass "and its two fields come out when the heading is pressed"
else
    fail "the LED group opened but its Brightness stepper is not on the tab"
fi

# ---------------------------------------------------------------------------- brightness
#
# **The arrow rather than the field**, as `08-app-settings` and `59-double-tap` do: the arrows are what a person uses,
# and what the field ends up holding is read back out of the table anyway.

since=$(mark)
press device-led-brightness-up
expect_log "stepping Brightness sends 0x09 to the cube" "$since" \
    "command withResponse: 09 33"
expect_log "and the app says what it sent" "$since" \
    "LED: sending brightness 51 percent"
expect_log "and calls it acknowledged rather than confirmed, there being no read-back" "$since" \
    "LED: the cube acknowledged brightness 51 percent, and there is no read-back to confirm it with" 30
expect_log "and only then is the row written" "$since" \
    "LED: the table now holds brightness 51 percent" 30

# **The order of those last two, read as row ids rather than trusted from the order they were waited for.**
# `expect_log` polls, so two patterns can both match rows that arrived the other way round -- and the whole of what
# this script adds over `swift test` is that the table follows the cube rather than accompanying it.
acked=$(dsql "SELECT MIN(debug_log_id) FROM debug_log WHERE debug_log_id > $since AND message LIKE 'LED: the cube acknowledged brightness 51 percent%';")
stored=$(dsql "SELECT MIN(debug_log_id) FROM debug_log WHERE debug_log_id > $since AND message LIKE 'LED: the table now holds brightness 51 percent';")
if [ -n "$acked" ] && [ -n "$stored" ] && [ "$stored" -gt "$acked" ]; then
    pass "the table was written after the cube took it, not beside it"
else
    fail "the acknowledgement was row ${acked:-none} and the write row ${stored:-none}"
fi

wait_for_value "SELECT json_extract(setting_value, '\$.brightness') FROM setting WHERE setting_name = 'led_settings';" "51" 10
check "the table holds the stepped brightness" "51" "$(setting led_settings brightness)"
check "and the blink period beside it in the same row is untouched" "15" "$(setting led_settings blink_interval)"

# ---------------------------------------------------------------------------- the blink period
#
# **Its own command and its own field of the same row.** `0x0A` rather than `0x09`, and `blink_interval` rather than
# `brightness`, which is what the check below is really about: the two share a `setting` row and nothing else.

since=$(mark)
press device-led-blink-up
expect_log "stepping Blink Interval sends 0x0A to the cube" "$since" \
    "command withResponse: 0A 10"
expect_log "and the table takes it once the cube has" "$since" \
    "LED: the table now holds blink interval 16 sec" 30

wait_for_value "SELECT json_extract(setting_value, '\$.blink_interval') FROM setting WHERE setting_name = 'led_settings';" "16" 10
check "the table holds the stepped blink period" "16" "$(setting led_settings blink_interval)"
check "and the brightness this script set a moment ago survived it" "51" "$(setting led_settings brightness)"

# ---------------------------------------------------------------------------- the floor the device sets
#
# **5 seconds is the vendor's own minimum for `0x0A`**, not a judgement about useful values, and the field is built
# from the same range the command clamps to (`DeviceCommandRules.blinkRange`). A step that cannot move reports
# nothing, so what is checked is that nothing at all went out -- a field that sent its floor again on every press
# would be a flash write per click for no change.

close_settings
sql "UPDATE setting SET setting_value = json_set(setting_value, '\$.blink_interval', 5) WHERE setting_name = 'led_settings';"
open_settings
select_tab Device
press device-led-heading-button
sleep 1

since=$(mark)
press device-led-blink-down
sleep 2
check "stepping the blink period below its floor sends nothing" "0" \
    "$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND message LIKE 'LED: sending%';")"
check "and leaves the row where it was" "5" "$(setting led_settings blink_interval)"

# ---------------------------------------------------------------------------- both at once
#
# **Two settings, two commands, two debounces.** Moving one must not lose the other. The presses here are as close
# together as a shell can make them, which is not close enough to reach the half-second window on its own -- so this
# is the observable half of that property and the comment at the top says so.

since=$(mark)
press device-led-brightness-up
press device-led-blink-up
expect_log "moving both sends the brightness" "$since" "LED: the table now holds brightness 52 percent" 30
expect_log "and the blink period as well" "$since" "LED: the table now holds blink interval 6 sec" 30
check "and the row holds both" "52/6" \
    "$(setting led_settings brightness)/$(setting led_settings blink_interval)"

close_settings
finish
