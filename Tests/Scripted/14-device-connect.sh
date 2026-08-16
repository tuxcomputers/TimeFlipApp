#!/bin/bash
# Reaching the cube that the scan found, and getting a PIN accepted.
#
# **The second script that needs the radio, and the first that talks to the cube.** `13-device-scan` proves an
# advertisement arrives; this one proves the app can open a link, find the TimeFlip service on the other end, present
# a PIN and read what the cube said about it. None of that is reachable from `swift test`: `DeviceLoginRules` decides
# what to send and what the answer means and is covered there in full, but whether a real cube ever answers `0x02` is
# a question only a cube can be asked.
#
# **And it is the one byte most worth asking about.** The vendor spec says `0x01` means the password is correct and
# `0x02` means it is wrong; the hardware does the opposite, which the archive found by logging both outcomes. Every
# correct PIN would be refused if that were the wrong way round, and nothing but a device run can tell.
#
# **A missing cube is a skip here, unlike `13`.** That script's claim is that the device is found, so silence is the
# result. This one's claim is about what happens once one is found, and with nothing to connect to there is no claim
# to test either way.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
start "connecting to a TimeFlip and logging in with a PIN"

if ! action_required \
    "Put your TimeFlip within a few metres of this Mac, and make sure it is awake." \
    "1. Flip the cube onto any face -- a sleeping cube does not advertise, so it cannot be found." \
    "2. Check Bluetooth is on." \
    "3. Press y and leave everything alone; the connect runs by itself." \
    "" \
    "This one talks to the cube. It presents the vendor default PIN (000000) and then," \
    "in a developer build, the PIN the previous app used to rotate to. It does not" \
    "change anything on the device: no PIN is set, no setting is written, nothing is" \
    "paired. The link is dropped again when the window closes." \
    "" \
    "Answer anything else to skip this script. The rest of the run is unaffected."; then
    skip "no TimeFlip was made available, so there is nothing to connect to"
    finish
    exit 0
fi

open_settings
select_tab Device

# ---------------------------------------------------------------------------- find one to connect to
#
# The same opening as `13`, and deliberately not factored into a shared helper yet: two callers is not a pattern, and
# the two scripts want different things when the radio cannot be used.

since=$(mark)
press device-scan
sleep 0.5

# **Waited on `Scan started`, not on the Bluetooth state.** The state callback fires on a *change*, so by the time
# this script runs the manager `13` built is already powered on and no such row is ever written again. That is what
# this check waited 60 seconds for on its first run, and the app now says when the radio actually starts listening.
grey "  waiting for the radio to come up..."
if ! wait_for "$since" "%Scan started%" 60 >/dev/null; then
    unavailable=$(sql "SELECT message FROM debug_log WHERE debug_log_id > $since AND message LIKE 'Scan unavailable:%' ORDER BY debug_log_id DESC LIMIT 1;")
    if [ -n "$unavailable" ]; then
        skip "the radio is unusable, so there is nothing to connect to ($unavailable)"
        finish
        exit 0
    fi
    fail "the radio never answered in 60s -- is the macOS Bluetooth permission prompt waiting?"
    finish
    exit 1
fi

grey "  listening for advertisements..."
if ! wait_for "$since" "%: peripheral %" 25 >/dev/null; then
    fail "the scan ran for 25 seconds and no TimeFlip answered it"
    press device-scan
    finish
    exit 1
fi

# The row's own identifier carries the peripheral uuid, which is how a step addresses one device out of several
# without hunting by position. Taking the first is right for the filtered scan: `DeviceScanRules.ordered` puts
# anything eligible at the top.
row=$(tree | grep -m1 -o "device-scan-result-[0-9A-Fa-f-]*")
if [ -z "$row" ]; then
    fail "the app logged a device but drew no row to press"
    press device-scan
    finish
    exit 1
fi
grey "  pressing $row"

# ---------------------------------------------------------------------------- the connection

since=$(mark)
press "$row"
sleep 0.5

expect_log "pressing a device asks the app to reach it" "$since" "Device clicked:%"
expect_log "and the scan stops, the list having been acted on" "$since" "%Scan stopped: a device was chosen%"
expect_log "the app opens a link to it" "$since" "Connecting to %"
expect_log "and the cube answers" "$since" "Connected to %presenting a PIN%" 20

# **The service is the test of what this is**, not the name that got it into the list: names are chosen by people and
# this is the hardware saying what it is. A device with no TimeFlip service on it ends the attempt as `notATimeFlip`.
expect_log "the TimeFlip service is on the other end" "$since" "Found characteristic password%" 20
expect_log "and so is the characteristic the answer comes back on" "$since" "Found characteristic commandResult%"

# ---------------------------------------------------------------------------- the PIN
#
# **Both directions, out of the trace rather than out of the login's own summary.** `ble-tx` and `ble-rx` are written
# by the code that touches the radio, so a row here is bytes that actually moved; the `login` rows above are the app
# narrating itself. The whole point of tracing every frame is that the two can be compared.

expect_log "the PIN goes out on the password characteristic" "$since" "password withResponse: %" 20
expect_log "the cube acknowledges the write" "$since" "password: write acknowledged"
expect_log "and answers on the command result characteristic" "$since" "commandResult: %"

# The attempt may take two connections: the vendor default first, then the stored PIN, with a second's settle in
# between so the refused link has finished coming down. Forty seconds covers both, generously.
grey "  waiting for the cube's verdict..."
verdict=$(wait_for "$since" "%PIN accepted%" 40)
if [ -n "$verdict" ]; then
    pass "the cube accepted a PIN"
else
    refused=$(sql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND message = 'PIN refused';")
    if [ "${refused:-0}" -gt 0 ]; then
        fail "the cube refused every PIN offered ($refused attempt(s)) -- it is on a PIN this app cannot name, so take its batteries out to put it back on 000000"
    else
        fail "no verdict on the PIN within 40s"
    fi
    close_settings
    finish
    exit 1
fi

# **The bytes behind the verdict, checked as bytes.** This is the assertion the whole script exists for: `02` is what
# a real cube sends when the PIN is right, and the vendor spec says that value means the opposite. If a firmware
# release ever swaps them to match the document, this is the line that says so.
answer=$(sql "SELECT message FROM debug_log WHERE debug_log_id > $since AND tag = 'ble-rx' AND message LIKE 'commandResult:%' ORDER BY debug_log_id DESC LIMIT 1;")
check_contains "the accepted answer is 0x02, as measured and not as documented" "$answer" "commandResult: 02"

# ---------------------------------------------------------------------------- what the tab says

status=$(tree | grep -m1 "id=device-scan-status" || true)
check_contains "the tab says it is connected" "$status" "Connected to"

# **Nothing durable is written**, and that is the design rather than an omission: reaching a cube is not pairing with
# it. `database/011_setting.sql` describes `paired` as surviving every drop and every refusal, which is only coherent
# if a connection never touches it.
check "connecting did not claim a pairing" "0" "$(sql "SELECT json_extract(setting_value, '\$.paired') FROM setting WHERE setting_name = 'paired';")"
check "and did not record a device uuid" "" "$(sql "SELECT IFNULL(json_extract(setting_value, '\$.uuid'), '') FROM setting WHERE setting_name = 'device_uuid';")"

# ---------------------------------------------------------------------------- letting go
#
# The link goes when the window does, for the same reason the scan does: nothing outside this tab uses it yet, so a
# connection left open is hardware being talked to with no control on screen that could end it.

since=$(mark)
close_settings
sleep 1

expect_log "closing the window drops the connection" "$since" "Disconnecting from %the Settings window closed"
expect_log "and the link actually came down" "$since" "Disconnected from %as asked%"

finish
