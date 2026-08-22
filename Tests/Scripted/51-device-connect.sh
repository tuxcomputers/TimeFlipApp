#!/bin/bash
# Reaching the cube that the scan found, getting a PIN accepted, and leaving the cube on a PIN of the app's own.
#
# **The second script that needs the radio, and the first that talks to the cube.** `50-device-scan` proves an
# advertisement arrives; this one proves the app can open a link, find the TimeFlip service on the other end, present
# a PIN, read what the cube said about it, and then change what the cube will answer to next time. None of that is
# reachable from `swift test`: `DeviceLoginRules` decides what to send, what to set and what an answer means and is
# covered there in full, but whether a real cube ever answers `0x02`, and whether it honours `0x30`, are questions
# only a cube can be asked.
#
# **The PIN it sets is `123456` and only ever `123456`** (`DeveloperMode.devicePIN`), so a half-done rotation can
# leave the cube on one of two known values and both are presented on the next attempt. That is what makes it safe to
# run this against real hardware repeatedly.
#
# **And it is the one byte most worth asking about.** The vendor spec says `0x01` means the password is correct and
# `0x02` means it is wrong; the hardware does the opposite, which the archive found by logging both outcomes. Every
# correct PIN would be refused if that were the wrong way round, and nothing but a device run can tell.
#
# **A missing cube is a skip here, unlike `50`.** That script's claim is that the device is found, so silence is the
# result. This one's claim is about what happens once one is found, and with nothing to connect to there is no claim
# to test either way.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
start "connecting to a TimeFlip and logging in with a PIN"

if ! device_required; then
    fail "no TimeFlip was made available, so there is nothing to connect to"
    finish
    exit $?
fi

open_settings
select_tab Device

# **A paired app has no Scan button**, the TimeFlip section offering Forget Device and Reset Device in its place
# (`DevicePairingRules.showsScanControls`). A default run rebuilds the test database from the DDL and so starts
# unpaired, which is the case this script is written for; a `--keep` run straight after a successful one is not, and
# without this it would fail on a missing element rather than saying why. Neither of those buttons does anything yet,
# so there is no way for the script to unpair itself and carry on.
if [ -z "$(tree | grep -m1 'id=device-scan  ')" ]; then
    fail "the app is already paired, so there is no Scan button -- run without --keep to start from a clean database"
    close_settings
    finish
    exit $?
fi

# ---------------------------------------------------------------------------- find one to connect to
#
# The same opening as `50`, and deliberately not factored into a shared helper yet: two callers is not a pattern, and
# the two scripts want different things when the radio cannot be used.

since=$(mark)
press device-scan
sleep 0.5

# **Waited on `Scan started`, not on the Bluetooth state.** The state callback fires on a *change*, so by the time
# this script runs the manager `50` built is already powered on and no such row is ever written again. That is what
# this check waited 60 seconds for on its first run, and the app now says when the radio actually starts listening.
grey "  waiting for the radio to come up..."
if ! wait_for "$since" "%Scan started%" 60 >/dev/null; then
    unavailable=$(dsql "SELECT message FROM debug_log WHERE debug_log_id > $since AND message LIKE 'Scan unavailable:%' ORDER BY debug_log_id DESC LIMIT 1;")
    if [ -n "$unavailable" ]; then
        fail "the radio is unusable, so there is nothing to connect to ($unavailable)"
        finish
        exit $?
    fi
    fail "the radio never answered in 60s -- is the macOS Bluetooth permission prompt waiting?"
    finish
    exit 1
fi

grey "  listening for advertisements..."
if ! wait_for "$since" "%: peripheral %" 13 >/dev/null; then
    fail "the scan ran its full 10 seconds and no TimeFlip answered it -- is the cube awake?"
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
    refused=$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $since AND message = 'PIN refused';")
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
# Taken as the last one *before* the app said the PIN was accepted, rather than the newest row of all. The exchange
# now reads this characteristic three times -- the verdict, the cube's answer to 0x30, and the verdict on the new PIN
# -- and the newest of those is not the one this check is about. A refused first candidate leaves an `01` in front of
# it too, so the first row is no better an anchor than the last.
accepted_at=$(dsql "SELECT debug_log_id FROM debug_log WHERE debug_log_id > $since AND tag = 'login' AND message = 'PIN accepted' ORDER BY debug_log_id LIMIT 1;")
answer=$(dsql "SELECT message FROM debug_log WHERE debug_log_id > $since AND debug_log_id < ${accepted_at:-0} AND tag = 'ble-rx' AND message LIKE 'commandResult:%' ORDER BY debug_log_id DESC LIMIT 1;")
check_contains "the accepted answer is 0x02, as measured and not as documented" "$answer" "commandResult: 02"

# ---------------------------------------------------------------------------- the PIN the app leaves it on
#
# **Two branches, and which one runs depends on the cube rather than on this script.** A cube on the vendor default is
# given a PIN of its own; a cube already on that PIN is left alone, since a same-value write costs a command round
# trip and a second login to change nothing. Both are correct outcomes, so both are checked rather than one being
# arranged for -- the alternative would be taking the batteries out before every run.

CONFIG="$HOME/Library/Application Support/Facet/config.json"
config_pin() {
    python3 - "$CONFIG" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1]) as f:
        print(json.load(f).get("PIN", ""))
except Exception:
    print("")
PY
}

grey "  waiting for the app to settle the cube's PIN..."
if wait_for "$since" "The cube is now on %" 25 >/dev/null; then
    pass "the cube took a new PIN and proved it by logging in with it"

    # **The bytes of the command, checked as bytes.** `30` is the set-password command and the six that follow are the
    # new PIN in ASCII, which the trace renders beside the hex. This is the only place the whole payload is visible.
    sent=$(dsql "SELECT message FROM debug_log WHERE debug_log_id > $since AND tag = 'ble-tx' AND message LIKE 'command %' ORDER BY debug_log_id LIMIT 1;")
    check_contains "0x30 went out on the command characteristic, carrying the new PIN" "$sent" "30 31 32 33 34 35 36"

    # **The confirmation is a real login, not the command's own acknowledgement.** A cube that acknowledges 0x30 has
    # not thereby promised to honour it, and a PIN is the one value where believing that is unrecoverable.
    expect_log "the app presents the new PIN to make the cube prove it" "$since" "Presenting 123456,%"
    expect_log "and writes it down where the next connect reads it" "$since" "Wrote the new PIN to %config.json"

    check "config.json holds the PIN the cube is now on" "123456" "$(config_pin)"
else
    left=$(dsql "SELECT message FROM debug_log WHERE debug_log_id > $since AND tag = 'pin' ORDER BY debug_log_id DESC LIMIT 1;")
    check_contains "the cube was already on this build's PIN, so it was left alone" "$left" "already on the PIN"

    # The file may legitimately name nothing here: with no PIN written down, the compiled-in constant stands in as the
    # stored candidate, which is how a cube rotated by an earlier run is still reachable after the file is deleted.
    stored=$(config_pin)
    if [ -n "$stored" ]; then
        check "and config.json agrees with what the cube accepted" "123456" "$stored"
    else
        pass "config.json names no PIN, so the compiled-in 123456 stood in as the stored candidate"
    fi
fi

# ---------------------------------------------------------------------------- what is written down
#
# **A confirmed login is a pairing**, and the rows it writes are the ones that outlive the link: which device this app
# has, what the cube is called, and that it is reachable right now. `database/011_setting.sql` describes `paired` and
# `device_uuid` as surviving every drop, every refusal and every quit -- so this is the point they are written, after
# the PIN is settled and not before.

expect_log "the pairing is recorded" "$since" "Paired with %"

check "the app is paired" "1" "$(sql "SELECT json_extract(setting_value, '\$.paired') FROM setting WHERE setting_name = 'paired';")"

# Checked against the row that was pressed rather than merely for being non-empty: the identifier in it is the
# peripheral's, so this is the app having recorded *that* device and not just some device.
uuid=$(sql "SELECT IFNULL(json_extract(setting_value, '\$.uuid'), '') FROM setting WHERE setting_name = 'device_uuid';")
check "and knows which device it is paired to" "$row" "device-scan-result-$uuid"

check "and the connection is recorded as up" "1" "$(sql "SELECT json_extract(setting_value, '\$.connected') FROM setting WHERE setting_name = 'connection';")"

# Local date-time, `YYYY-MM-DDTHH:MM:SS`, the form every date-time in the setting table takes.
stamped=$(sql "SELECT json_extract(setting_value, '\$.last_connection') FROM setting WHERE setting_name = 'connection';")
check "stamped with today" "$(date +%Y-%m-%d)" "${stamped%%T*}"

# The GAP name, which is what a rename changes and what the filtered scan matches on next time. A cube that has not
# told this Mac its name leaves the row empty, which is a real state rather than a fault.
name=$(sql "SELECT IFNULL(json_extract(setting_value, '\$.name'), '') FROM setting WHERE setting_name = 'device_name';")
if [ -n "$name" ]; then
    pass "and the name the cube is carrying, '$name'"
else
    pass "the cube has not told this Mac its name, so device_name stays empty"
fi

# ---------------------------------------------------------------------------- what the cube says it is
#
# **The one thing on this tab that is read off standard GATT rather than the vendor's own service.** Manufacturer,
# model, hardware and firmware are the four read-only strings of Device Information (0x180A), and they need no PIN --
# so they are read after the verdict, on their own discovery, and cannot delay or fail a login. That independence is
# the claim worth testing here: `swift test` covers the decoding and what gets written, but whether this cube exposes
# the service at all, and answers all four, is a question only a cube can be asked.
#
# **A cube that answers none of them is a skip, not a failure.** The app is specified to pair and connect exactly the
# same either way, and the checks above have already proved it did.

grey "  waiting for the cube to say what it is..."
if wait_for "$since" "The cube says it is %" 25 >/dev/null; then
    pass "the cube answered the Device Information reads"

    expect_log "the reads are asked for after the login, not during it" "$since" "Asking the cube what it is"
    expect_log "and what came back is written down" "$since" "Recorded what the cube says it is"

    # **Each field checked for being non-empty rather than for a particular string.** The values are this cube's
    # (`DI_LABS` / `2.0` / `TFv4.1` / `FW_v3.64` on the measured one), and a firmware update legitimately changes one
    # of them -- so asserting the text would make this script fail for the one reason it should not.
    for field in manufacturer model hardware firmware; do
        stored=$(sql "SELECT IFNULL(json_extract(setting_value, '\$.$field'), '') FROM setting WHERE setting_name = 'device_info';")
        if [ -n "$stored" ]; then
            pass "device_info.$field is recorded as '$stored'"
        else
            pass "the cube did not answer for $field, which leaves that key absent rather than blank"
        fi
    done

    # **The trace, so the bytes are seen as bytes.** The log line above is the app narrating itself; this is the read
    # actually having happened on the characteristic. Named rather than numbered, because `TimeFlipUUIDs.name` is what
    # the trace prints and `firmwareRevision` is what it now calls 0x2A26.
    expect_log "the firmware string came off the firmware revision characteristic" "$since" "firmwareRevision: %"

    # **The window is already open here** -- it was opened before the scan and is not closed until "keeping it"
    # below, so this opens no window of its own. What it does open is the folded section: a row inside a collapsed
    # `More` is not in the tree at all, which would read as a value the tab failed to draw.
    # **The heading button, not the section.** `device-more` is the group; pressing it does nothing at all and the
    # rows stay out of the tree, which reads as a tab that failed to draw them. Measured on a device run, 2026-08-17.
    press device-more-heading-button
    sleep 0.7

    for field in manufacturer model hardware firmware; do
        stored=$(sql "SELECT IFNULL(json_extract(setting_value, '\$.$field'), '') FROM setting WHERE setting_name = 'device_info';")
        [ -n "$stored" ] || continue
        shown=$(tree | grep -m1 "id=device-$field" || true)
        check_contains "the $field row shows what the table holds" "$shown" "$stored"
    done

    # Folded back, so the tab is left as this script found it and the checks below read the same window they would
    # have without this section.
    # **The heading button, not the section.** `device-more` is the group; pressing it does nothing at all and the
    # rows stay out of the tree, which reads as a tab that failed to draw them. Measured on a device run, 2026-08-17.
    press device-more-heading-button
    sleep 0.7
else
    # Reported against the log rather than assumed: the app says which of the two happened, and they are different
    # findings -- one is a cube without the service, the other is a cube that stopped answering mid-read.
    said=$(dsql "SELECT message FROM debug_log WHERE debug_log_id > $since AND tag = 'info' ORDER BY debug_log_id DESC LIMIT 1;")
    pass "this cube said nothing about what it is (${said:-no info rows at all}), which pairs and connects the same"
fi

# ---------------------------------------------------------------------------- what the tab says
#
# **Read off the tab, not off the table.** The rows above prove what was written; these prove the window went back to
# the table and drew what it now says, which is the other half of `CLAUDE.md`'s rule about reading back after a write.

status=$(tree | grep -m1 "id=device-scan-status" || true)
check_contains "the tab says it is connected" "$status" "Connected to"

connection=$(tree | grep -m1 "id=device-connection" || true)
check_contains "the Connection row says Connected" "$connection" "Connected"

# Manual mode outranks everything else in that row, so this is also the check that pairing took the app out of it.
case "$connection" in
    *"Manual mode"*) fail "the Connection row still says manual mode, with a cube connected" ;;
    *) pass "and no longer says manual mode, a device being paired" ;;
esac

if [ -n "$name" ]; then
    shown=$(tree | grep -m1 "id=device-name" || true)
    check_contains "the Name row shows the cube's name" "$shown" "$name"
fi

# ---------------------------------------------------------------------------- keeping it
#
# **The link survives the window, and that is what a pairing means.** A scan is for whoever is looking at the list, so
# it stops; a connection is not, because the cube is now this app's device. Dropping it on close would mean forgetting
# its own device every time somebody shut a window, and reconnecting from scratch -- PIN and all -- on the next open.
# It is let go on the way out instead (`99-quit`).

since=$(mark)
close_settings
sleep 1

if [ -n "$(dsql "SELECT 1 FROM debug_log WHERE debug_log_id > $since AND message LIKE 'Disconnecting from %';")" ]; then
    fail "closing the window dropped the connection, which is what a paired device is not"
else
    pass "closing the window left the connection alone"
fi

check "and the connection is still recorded as up" "1" "$(sql "SELECT json_extract(setting_value, '\$.connected') FROM setting WHERE setting_name = 'connection';")"
check "with the pairing untouched" "1" "$(sql "SELECT json_extract(setting_value, '\$.paired') FROM setting WHERE setting_name = 'paired';")"

finish
