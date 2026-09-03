#!/bin/bash
# A paired cube that refuses this app's PIN: the offer, Rescan, and taking timing by hand.
#
# **The one route into manual mode that is not "nothing answered".** `56-manual-mode` gets the offer up by putting the
# cube out of reach, so the app finds nothing at all. This gets it up with the cube sitting right there, answering,
# and refusing.
#
# **The dialog is the same one either way, and that is deliberate.** The person's situation is identical -- their cube
# is not usable and they have to decide whether to keep waiting -- and the cube that answered may well not be theirs
# at all: a colleague's on the next desk, found because it is a TimeFlip in range, on the morning theirs was left at
# home. What differs is the `debug_log` row, because "nothing was in range" and "it was right there and refused" are
# different problems with different fixes.
#
# **The wrong PIN is made, not waited for.** `DeviceLoginRules.reconnectCandidates` presents everything
# `DevicePINRules.readOrder` holds and then the vendor default, so being out of PINs means every store is wrong --
# the state a user reaches by pairing a cube to another app, or restoring a machine from a backup with a stale PIN
# in it.
#
# **There are two stores and both have to be wrong.** `config.json` is the fallback the app writes when the Keychain
# refuses, and the Keychain (`DevicePINStore`) is where a PIN belongs; `DevicePINRules.readOrder` presents the file's
# first and the Keychain's behind it. This script broke the file alone until run 146 caught it: the cube refused the
# file's PIN, the app went on to the Keychain's, and the Keychain still held the right one -- so it logged in,
# correctly, and the attempt never ran out.
#
# **The cube's real PIN is read out of the trace first, and that is what makes this safe.** It is six random digits
# now, chosen at pairing and written to the Keychain alone -- the fixed 123456 went with the developer flag on
# 2026-09-04 -- so deleting that item without a copy would leave a cube nothing on this machine can open.
# `DeviceLogin` records `The cube is now on <pin>` when it rotates one, so the trace holds it, and `00-setup` turns
# the trace on before anything runs.
#
# **Both stores come back, by different routes, and neither is left to chance.** The trap below writes the real PIN
# into the file, which is exactly the state the fallback exists for: the next launch finds the two stores
# disagreeing, presents the file's, the cube accepts it, and `DevicePINRules.reconciliation` promotes it back into
# the Keychain and clears the file. Writing the Keychain back with `security` instead would need `-A` to stop the app
# prompting on it, which would leave the cube's PIN readable by every program on the machine long after this script
# had finished.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
# What this script checks when everything passes. See `finish` in lib.sh for what a mismatch means.
#
# **21, measured on run 80 (2026-08-23), which is the first time this script ever ran to the end.** It was
# seeded at 20 from reading the source, and that was one short: 25 verdict sites less the four that only fire
# on a failure arm. The miscount was mine and the count is what caught it, on the first run that got here.
#
# **20 since the pairing became something this script inherits** rather than makes: the check that read it back was
# the one verdict that went with it.
#
# **21 since the Keychain became a store this has to break too**, the check that reads the item back after clearing
# it being the verdict that came with it. It fell to 20 while a developer build read the file alone, and is back at
# 21 now the developer flag is gone and both stores are candidates again -- plus one for reading the cube's own PIN
# out of the trace, which is what makes breaking the Keychain safe.
EXPECTED_CHECKS=22
start "a cube that refuses this app's PIN: the offer, Rescan, and timing by hand"

# **No cube check here.** `00-setup` asked once and `50-device-scan` stops the run if the answer was no, so
# anything reaching this line has a cube: every script between them needs one, and none of them runs after 50
# has failed. A second gate here would be a branch that can never be taken, and an untaken branch is checks
# that silently do not run.

CONFIG="$SUPPORT/config.json"
PIN_RESTORED=1
# The cube's real PIN, read below. Everything this script breaks is put back from it.
PIN_REAL=""

# The Keychain item the app keeps the cube's PIN in -- `DevicePINStore`'s `service` and `account`, which are the
# bundle identifier plus `.device`, and `device-pin`. Written out rather than derived, so a rename over there shows
# up here as this script failing to clear anything rather than as it silently clearing nothing.
PIN_SERVICE="au.com.tux.facet.device"
PIN_ACCOUNT="device-pin"
KEYCHAIN_CLEARED=0

# Puts the cube's own PIN into `config.json`, leaving every other key alone.
write_real_pin() {
    python3 - "$CONFIG" "$PIN_REAL" <<'PY'
import json, os, sys
path, pin = sys.argv[1], sys.argv[2]
config = {}
if os.path.exists(path):
    try:
        with open(path) as handle:
            config = json.load(handle)
    except ValueError:
        config = {}
config["PIN"] = pin
with open(path, "w") as handle:
    json.dump(config, handle, indent=2)
PY
}

restore_pin() {
    # **Said whichever way this ends, and it is not a failure.** The app puts the item back on the next login the
    # file's PIN wins, which is the fallback healing itself rather than anything this script has to do.
    if [ "$KEYCHAIN_CLEARED" = "1" ]; then
        step "the Keychain PIN is cleared; the app puts it back on the next login the config PIN wins"
    fi
    [ "$PIN_RESTORED" = "1" ] && return 0
    # **The cube's own PIN goes into the file, rather than the file going back to what it was.** What it was is very
    # often no PIN at all -- the app clears that copy the moment the Keychain holds one -- and this script has just
    # emptied the Keychain, so restoring the backup verbatim would leave both stores naming nothing.
    if [ -n "$PIN_REAL" ] && write_real_pin; then
        rm -f "$CONFIG.58-backup"
        PIN_RESTORED=1
        step "the cube's own PIN is in config.json; the app promotes it back to the Keychain on the next login"
        return 0
    fi
    yellow "##############################################################################"
    yellow "##"
    yellow "##  THE PIN IN config.json IS STILL WRONG"
    yellow "##"
    yellow "##  This script set it to 123457 and could not put it back."
    yellow "##  Every script after this one will fail to open the cube, and so will"
    yellow "##  the next ordinary launch. Put it back by hand:"
    yellow "##    $CONFIG"
    yellow "##  The cube is on ${PIN_REAL:-a PIN this script could not read}."
    yellow "##"
    yellow "##############################################################################"
    echo ""
}
trap restore_pin EXIT INT TERM

# ---------------------------------------------------------------------------- a cube to be refused by
#
# **Already paired, with the right PIN**, so what follows is a cube this app owns rather than one it never reached.
# Inherited from `57-cube-pause` rather than paired for here -- see `require_a_paired_cube` in lib.sh. That it is
# paired is a precondition and not a check: breaking the PIN under a cube this app never owned would be a script
# about nothing.

require_a_paired_cube "there is no paired cube for the PIN to be wrong for"

# ---------------------------------------------------------------------------- the PIN goes wrong
#
# **With the app shut**, so the change is read at the next launch rather than half way through one. The app reads
# `config.json` when it reaches for the cube, and rewriting it under a running app would be a race with nothing to
# say which side won.

quit_app
sleep 1

# **What the cube is actually on, before anything is broken.** The PIN is six random digits chosen at pairing and
# written to the Keychain alone, so without a copy the deletion below would strand the cube. The file is asked first,
# it being the newer of the two whenever it holds one at all (`DevicePINRules.readOrder`); the trace answers
# otherwise, `DeviceLogin` having recorded the rotation.
PIN_REAL=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('PIN',''))" "$CONFIG" 2>/dev/null || true)
if [ -z "$PIN_REAL" ]; then
    PIN_REAL=$(dsql "SELECT replace(message, 'The cube is now on ', '') FROM debug_log WHERE message LIKE 'The cube is now on %' ORDER BY debug_log_id DESC LIMIT 1;")
fi
case "$PIN_REAL" in
    [0-9][0-9][0-9][0-9][0-9][0-9])
        pass "the cube's own PIN was found, so both stores can be broken and put back ($PIN_REAL)"
        ;;
    *)
        fail "the cube PIN is in neither config.json nor the trace, so breaking the stores would strand it"
        finish
        exit $?
        ;;
esac

[ -f "$CONFIG" ] && cp "$CONFIG" "$CONFIG.58-backup"
PIN_RESTORED=0
python3 - "$CONFIG" <<'PY'
import json, os, sys
path = sys.argv[1]
config = {}
if os.path.exists(path):
    try:
        with open(path) as handle:
            config = json.load(handle)
    except ValueError:
        config = {}
config["PIN"] = "123457"
with open(path, "w") as handle:
    json.dump(config, handle, indent=2)
PY
check "config.json now holds a PIN the cube is not on" "123457" \
    "$(python3 -c "import json;print(json.load(open('$CONFIG'))['PIN'])" 2>/dev/null)"

# **And the Keychain's, which is the other half of being out of PINs.** Deleting is prompt-free: the dialog the
# Keychain raises is for *reading* an item another program owns, and this reads nothing (confirmed 2026-08-31,
# `security delete-generic-password` returned at once). `find` without `-w` is the same -- attributes, not the
# secret -- which is what makes the check below safe to run at all inside a suite nobody is watching.
#
# Asserted rather than assumed. A delete that quietly did nothing would leave the app holding the real PIN, and the
# failure would arrive four checks later as the cube accepting a login this script is here to see refused.
security delete-generic-password -s "$PIN_SERVICE" -a "$PIN_ACCOUNT" >/dev/null 2>&1
KEYCHAIN_CLEARED=1
check "and the Keychain no longer holds one either, so every store is wrong" "gone" \
    "$(security find-generic-password -s "$PIN_SERVICE" -a "$PIN_ACCOUNT" >/dev/null 2>&1 && echo present || echo gone)"

# ---------------------------------------------------------------------------- found, and refused
#
# **Found is the half that matters.** A cube out of reach and a cube refusing look identical in the menu bar and are
# not the same fault, so this asserts the app got as far as talking to it before being turned away.

launched=$(mark)
ensure_app_running

expect_log "a paired app goes looking for its cube" "$launched" "Paired, so going to look for the cube" 30
expect_log "and reaches it, so the cube is plainly in range" "$launched" "Connected to %" 60
# **The order is worked out before anything is connected to**, which is the shape this had to be rebuilt into on
# 2026-08-23. Trying each device as it advertised put a connect, a scan being stopped and a modal dialog inside one
# another, and the retry made from that dialog was overwritten by the tail of the connect it interrupted.
expect_log "the reach works out an order to ask in first" "$launched" \
    "% device(s) to ask, in the order they will be asked" 30
expect_log "the cube refuses the PIN it was given" "$launched" "Refused,%" 30
# Both candidates: the stored one and the vendor default behind it. The second refusal is what ends the attempt, and
# without it the app would still have somewhere to go.
expect_log "and refuses the fallback behind it, so the attempt is out of PINs" "$launched" \
    "%: wrongPIN" 60

# ---------------------------------------------------------------------------- the offer, which reads the same
#
# **The same dialog as `56-manual-mode` gets by putting the cube out of reach**, and that is the point rather than an
# economy. The situation a person is in is the same in both: their cube is not usable and they have to decide whether
# to keep waiting. The cube that answered here may well not even be theirs -- a colleague's on the next desk, found
# because it is a TimeFlip in range -- so a dialog naming a PIN problem would send them hunting one they do not have.
# `ManualModeAlert.ask` takes no reason at all, which is what makes that structural.
#
# **The reason still reaches the log**, and only the log: "nothing was in range" and "it was right there and refused"
# are different problems with different fixes, and the archive recorded a run where a handed-in string blamed a cube
# sitting on the desk. Asserted here because this is the one script that can produce the refusal half of it.

expect_log "so manual mode is offered" "$launched" "Offering manual mode:%" 60
offer=$(dsql "SELECT message FROM debug_log WHERE debug_log_id > $launched AND message LIKE 'Offering manual mode:%' ORDER BY debug_log_id LIMIT 1;")
check_contains "and the log says why, which the dialog does not" "$offer" "refused the PIN this app has"

# ---------------------------------------------------------------------------- Rescan, which asks again
#
# **Rescan is one more attempt and the same question after it.** There is no limit on how many times it may be chosen,
# and nothing about it is a countdown: the cube is still on a PIN this app does not have, so the second round finds
# exactly what the first did.

retried=$(mark)
press_title "Rescan"
sleep 2

if ! wait_for "$retried" "Rescan chosen;%" 5 >/dev/null; then
    step "the alert did not answer to an AXPress, so asking for a hand"
    if ! action_required \
        "Click **Rescan** on the dialog" \
        "The app could not open your TimeFlip, and is asking what to do about it." \
        "Do not click Time by Hand or Quit yet: this script needs the rescan first."
    then
        fail "the offer was not answered, so the retry could not be checked"
        finish
        exit $?
    fi
fi

expect_log "Rescan is recorded as chosen" "$retried" "Rescan chosen;%" 10
expect_log "and it looks again rather than standing down" "$retried" "Reaching for %" 30
# **A scan, not the last answer repeated.** The whole of what Rescan means is going to look again, and the fault it hid
# was that it did not: on 2026-08-23 this button came back in eight milliseconds, having connected to a handle the failed
# attempt had already torn down, and reported "nothing answered" about a cube on the desk. A `Scan started` row after
# the retry is the difference between looking again and answering from memory.
expect_log "and it is a real scan rather than the last answer again" "$retried" "Scan started%" 30
expect_log "the cube refuses it a second time" "$retried" "%: wrongPIN" 60
expect_log "so the offer comes back" "$retried" "Offering manual mode:%" 60

# ---------------------------------------------------------------------------- giving up on it
#
# The same dialog, answered the other way. Two things follow, and they are one decision: no attempt of the app's own
# from any path for the rest of the launch, and this launch times from the app instead. What does **not** follow is
# anything about the pairing -- a refused PIN says nothing about which cube this app has, and the row is checked below
# to say so.

chosen=$(mark)
press_title "Time by Hand"
sleep 2

if ! wait_for "$chosen" "Time by hand chosen;%" 5 >/dev/null; then
    step "the alert did not answer to an AXPress, so asking for a hand"
    if ! action_required \
        "Click **Time by Hand** on the dialog" \
        "The app still could not open your TimeFlip, and is asking again." \
        "This is the last thing this script needs from you."
    then
        fail "the second offer was not answered, so the app was never told to stand down"
        finish
        exit $?
    fi
fi

expect_log "choosing it stops the loop for the rest of the launch" "$chosen" "Time by hand chosen;%" 60
check "the cube is still this app's cube, refused PIN and all" "1" "$(setting paired paired)"
# **And it does it without restarting**, which is what the old switching needed and what makes this worth pinning: a
# second `Launch mode:` row would mean the launch had been replaced rather than changed. Whether the click starts a
# clock is `56-manual-mode`, which has the tab open for it.
check "and the launch is still the one that started" "0" \
    "$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $chosen AND tag = 'mode' AND message LIKE 'Launch mode:%';")"

# **Nothing is looked for again**, which is the whole of what taking it means. Checked against the log rather than by
# waiting: an attempt would announce itself, so the absence of one over a stretch is the evidence.
quiet=$(mark)
sleep 12
check "and no further attempt is made on its own" "0" \
    "$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $quiet AND message LIKE 'Reaching for %';")"
check "nor is the question put again" "0" \
    "$(dsql "SELECT COUNT(*) FROM debug_log WHERE debug_log_id > $quiet AND message LIKE 'Offering manual mode:%';")"

# ---------------------------------------------------------------------------- putting the PIN back
#
# **Before the app is restarted, so the next launch opens the cube.** Everything after this script needs a cube it can
# reach, and `99-quit` wipes it -- which it cannot do through a PIN this app does not have.

restore_pin
check "config.json holds the working PIN again" "123456" \
    "$(python3 -c "import json;print(json.load(open('$CONFIG'))['PIN'])" 2>/dev/null)"

quit_app
sleep 1
relaunched=$(mark)
ensure_app_running
expect_log "and a fresh launch opens the cube again" "$relaunched" "%: loggedIn" 90

# **The quit above locked and paused the cube, and nothing else here undoes it.** This script relaunches on its own
# terms rather than through `relink_a_cube`, the relaunch being the thing it is checking, so it has to hand the cube on
# itself. Without this it leaves a stopped cube to `59`, which does not care, and then to `60-device-backlog`, which
# takes it out of range expecting it to go on counting.
free_the_cube

finish
