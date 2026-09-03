#!/bin/bash
# Puts the app, the database and the cube into the state every other script starts from.
#
#   Tests/Scripted/00-setup.sh --capture   read the private seeds out of the database as it stands
#   Tests/Scripted/00-setup.sh             put everything into the known state
#
# `run.sh` calls `--capture` **before** it rebuilds and runs this normally afterwards.
#
# **This is not a test, and it reports one check.** Everything below is arrangement: nothing here asserts what
# the app does, and a green line from this script means only that the ground the other scripts stand on was
# actually laid. So it declares one expected check and answers it once at the bottom -- completed, or did not.
# Counting the seeds individually would put twenty green lines at the top of every run that say nothing about
# the app, and would make the total look like coverage that does not exist.
#
# **Everything conditional lives here.** The scripts after this one are written for one starting state and do
# not ask whether they got it: no script below checks whether a Google account is connected, whether a cube is
# paired, or whether the cube is locked, because this decides all of it. A branch in a test script is a path
# that a run does not take and so never checks, and the count of what ran is the only thing that shows it.
#
# What this guarantees to everything below:
#
#   1. **The database is seeded** -- private seeds applied, `debug` logging and `pause_on_lock` enabled, fractional
#      history present.
#   2. **The cube is factory reset**, on the vendor PIN 000000, if there is one.
#   3. **The app does not know about any device**, so `50-device-scan` starts from nothing.
#   4. **The app is not running**, so `01-launch` gets a genuine cold start.
#   5. **The Google account is connected and its calendar exists**, from the private seeds.
#
# **The cube is asked about once, here.** `ask_about_the_device` holds the whole of the consent -- it says the
# cube is wiped, and it is wiped by this script rather than twenty minutes later. Every script after this reads
# the answer through `device_required` and none of them can prompt. A no is not a failure of this script: the
# person answered honestly and the setup did everything it could. `50-device-scan` is where the run stops.
#
# **This writes straight to the tables**, which every other script in this folder is forbidden from doing.
# It is right here for the same reason it is wrong there: the app is not running while the seeds go in, so
# there is nothing to disagree with, and the app reads all of this when it starts rather than holding it
# from before. That is **made** true below rather than assumed -- the app is shut before the first write.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/seed-private.sh"

require_test_database

if [ "${1:-}" = "--capture" ]; then
    capture_private_seeds
    exit 0
fi

# What this script checks when everything passes. See `finish` in lib.sh for what a mismatch means.
EXPECTED_CHECKS=1
start "putting the app, the database and the cube into a known state"

# **Every script gets its row now, before any of them runs.** Each one is written with the count it declares and
# nothing against it, so a run that stops half way still lists the scripts it never reached instead of leaving
# them out. `passed < expected` is then the whole question: it is true of a script that failed, and equally true
# of one that was never given the chance.
testlog_prepare_scripts

# **One verdict, at the bottom, and everything above it reports into `TROUBLE`.** `step` and `trouble` are in
# lib.sh, because `seed-private.sh` reports through them too.

# ---------------------------------------------------------------------------- the database

# **Shut first, and this is the line the rest of the script stands on.** Every setting below is read by the app
# when it launches, and `debug` decides whether there is a trace at all -- so a copy left running from an earlier
# session would go on with the settings it started under, and `ensure_app_running` further down would find it up
# and leave it alone. The polling this script does of its own (the cube's auto-pause, the resting face) would then
# be reading a `debug_log` nothing is writing to.
quit_app

step "applying the private seeds"
apply_private_seeds

# **Written rather than assumed, because `--keep` does not rebuild.** A clean run gets `{"enabled":true}` from
# `011_setting.sql`, but a kept database carries whatever the last run left, and `55-device-face` reads this
# setting to decide whether it locks the cube at all -- six checks on one branch and one on the other. Pinning
# it here is what lets that script stop asking.
sql "UPDATE setting SET setting_value = '{\"enabled\":true}' WHERE setting_name = 'pause_on_lock';"
if [ "$(sql "SELECT json_extract(setting_value, '\$.enabled') FROM setting WHERE setting_name = 'pause_on_lock';")" != "1" ]; then
    trouble "pause_on_lock would not stay enabled"
else
    step "pause on lock is enabled"
fi

# **The whole suite stands on this one.** Every check in every script is press by name, then poll for the
# `debug_log` row (`Tests/Methods.md`), and nothing is recorded unless this row says so. `011_setting.sql` seeds it
# **off**, which is right for somebody installing the app and wrong for a run that is about to read the trace, so it
# is turned on here.
#
# **Written with the app shut, which is what the quit above is for.** The switch is live *through the App tab* --
# pressing it tells the running logger -- but a row changed underneath the app by sqlite tells it nothing, and it is
# only read again at launch.
#
# **Here rather than in `lib.sh`**, so it is arranged once, in the script whose whole job is arranging, and by the
# same hand that pins `pause_on_lock` above. Every script after this one inherits it, and none of them has to ask.
#
# **Written with the folder alongside it**, because a row holding only `enabled` would leave the trace to fall back
# to the seeded folder while the rest of this file addresses `$DEBUG_DB`. The two must name the same place.
sql "UPDATE setting SET setting_value = '{\"enabled\":true,\"directory\":\"~/Library/Application Support/Facet\"}' WHERE setting_name = 'debug';"
if [ "$(setting debug enabled)" != "1" ]; then
    trouble "debug logging would not stay on, so nothing below can poll for a row"
else
    step "debug logging is on, and the trace is in $SUPPORT"
fi

# ---------------------------------------------------------------------------- history with fractions
#
# **Segments whose `duration_seconds` carries a fraction, and unsynced entries for them.** A regression
# seed: it recreates the shape of the data that broke Google sync completely, so every run meets it again.
#
# What happened. A `time_entry` held `duration_seconds = 147.612311840057`. The event body sent to Google
# truncated that to whole seconds and the expectation it was checked against did not, so the read-back
# disagreed by 0.6 of a second, the row was never ticked, and every later sweep retried the same row for
# ever -- taking every entry behind it down with it. `swift test` cannot find this: the app only ever
# writes whole seconds now, so the shape arrives only from history already recorded.
#
# **An hour old, worked out from the clock rather than written down.** A date in the file would be a date
# that ages: it drifts out of every range the report covers and the seed quietly stops being reachable.
# An hour rather than a day so the entries are on the day the Report tab already opens on -- a seed
# nobody can see without scrolling back is a seed nobody checks.
#
# The one hour it is wrong: a run inside the hour after `daily_reset_time` puts them in yesterday's
# window, since the app's day starts at 3 AM rather than at midnight. They are still there, one day back.
#
# On the app's own faces (13, 14) rather than a cube's, so they read as manual rows: a seeded segment carries
# the epoch as its event number and only `DeviceEventRecorder.startSegment` ever does that, so a seed on a cube
# face is a row no cube could have produced. That cost a real debugging session on 2026-08-21 --
# `DeviceEventRecorder.newestFromTheCube` filters the app's faces out precisely so a manual segment cannot
# answer "where is the cube's history up to", and a seed on face 8 walked straight past it. The app then asked
# a cube for event 1,787,051,381 on every refresh, got nothing, and recorded nothing, for ever.
#
# Alternating rather than all three on one face, for the reason `ManualFace` alternates: consecutive segments on
# one face means a face reassigned under a finished segment changes the answer to whose time it was.

fractional=$(sql "SELECT COUNT(*) FROM time_entry WHERE duration_seconds != CAST(duration_seconds AS INTEGER);")

if [ "${fractional:-0}" -gt 0 ]; then
    step "history with fractional durations is already here ($fractional entries), leaving it alone"
else
    # The zone the machine is in, created if this is the first time it has been seen -- the same
    # get-or-create the app does. A row filed under the seeded `Unknown` (id 0) would be testing the
    # fallback rather than the ordinary case.
    zone_name=$(python3 -c "import time; print(time.tzname[0])")
    sql "INSERT INTO timezone (timezone_name) SELECT '$zone_name'
         WHERE NOT EXISTS (SELECT 1 FROM timezone WHERE timezone_name = '$zone_name');"
    zone=$(sql "SELECT timezone_id FROM timezone WHERE timezone_name = '$zone_name';")
    zone=${zone:-0}

    # An hour back, spread over the next twenty minutes so the three are distinguishable in a list.
    hour_ago=$(( $(date +%s) - 3600 ))

    seeded=0
    offset=0
    manual_face=13
    for pair in "147.612311840057:1" "38.6364130973816:2" "9.5:1"; do
        secs="${pair%%:*}"
        category="${pair##*:}"
        start_at=$((hour_ago + offset))
        offset=$((offset + 600))
        whole=${secs%%.*}

        sql "INSERT INTO device_event (
                 event_number, event_type_id, device_face, start_time, timezone_id,
                 start_epoch, duration_seconds, paused, finalised, processed
             ) VALUES (
                 $start_at, 1, $manual_face, strftime('%Y-%m-%dT%H:%M:%S', $start_at, 'unixepoch', 'localtime'), $zone,
                 $start_at, $secs, 0, 1, 1
             );"

        [ "$manual_face" = "13" ] && manual_face=14 || manual_face=13

        event=$(sql "SELECT device_event_id FROM device_event WHERE start_epoch = $start_at AND event_number = $start_at;")
        [ -z "$event" ] && continue

        # **Unsynced on purpose.** The sweep in 10 is what carries them, and carrying a fractional one is
        # the thing that used to be impossible.
        sql "INSERT INTO time_entry (
                 category_id, device_event_id, started_at, start_timezone_id,
                 ended_at, end_timezone_id, duration_seconds, synced_to_google_calendar
             ) VALUES (
                 $category, $event,
                 strftime('%Y-%m-%dT%H:%M:%S', $start_at, 'unixepoch', 'localtime'), $zone,
                 strftime('%Y-%m-%dT%H:%M:%S', $((start_at + whole)), 'unixepoch', 'localtime'), $zone,
                 $secs, 0
             );"
        seeded=$((seeded + 1))
    done

    [ "$seeded" = "3" ] || trouble "only $seeded of 3 fractional segments could be seeded"

    waiting=$(sql "SELECT COUNT(*) FROM time_entry WHERE synced_to_google_calendar = 0 AND duration_seconds != CAST(duration_seconds AS INTEGER);")
    [ "${waiting:-0}" = "3" ] || trouble "${waiting:-0} of 3 seeded entries are waiting to sync"

    # The one that mattered, kept exactly. If this stops being a fraction the seed has stopped guarding anything.
    case "$(sql "SELECT group_concat(duration_seconds) FROM time_entry WHERE duration_seconds != CAST(duration_seconds AS INTEGER);")" in
        *147.612311840057*) step "seeded three fractional segments, including the duration that broke sync" ;;
        *) trouble "the duration that broke Google sync (147.612311840057) is not among the seeds" ;;
    esac

    # Dated rather than assumed. The point of the hour is that these show up beside what the run itself
    # records, without anybody changing the range to find them.
    dated=$(sql "SELECT date(de.start_epoch, 'unixepoch', 'localtime') FROM device_event de
                   JOIN time_entry te ON te.device_event_id = de.device_event_id
                  WHERE te.duration_seconds != CAST(te.duration_seconds AS INTEGER)
                  ORDER BY de.start_epoch LIMIT 1;")
    [ "$dated" = "$(date -r $hour_ago '+%Y-%m-%d')" ] || trouble "the seeds are dated $dated, not today"
fi

# ---------------------------------------------------------------------------- the app, up once for both
#
# Google and the cube both need a running app with the Settings window open, so it is launched once here rather
# than twice below. It is shut again at the bottom, so `01-launch` gets a genuine cold start.

ensure_app_running
open_settings

# ---------------------------------------------------------------------------- the Google account
#
# **Proved by making the app do it, not by reading the row.** A `google_account` row with an email in it says
# somebody signed in once; it says nothing about whether the refresh token still works. It can be revoked at
# myaccount.google.com, expire through disuse, or belong to a project whose consent screen changed -- and the
# row looks identical either way. Pressing Create is a real Google request, so it either comes back with a
# calendar or it does not, and that is the only answer worth having.
#
# **Through the app rather than from this script.** The credentials and the refresh token are both the app's:
# it reads `~/.config/facet/google-client.json` and owns the Keychain item. Reaching into the Keychain from a
# script means `security` asking macOS for another process's item, which puts a dialog on screen mid-run.
#
# **Deleted first when one is stored, so the end state is exactly one fresh calendar.** Pressing Create on top
# of a stored one would leave the old orphaned at Google, a new one every run for ever. This does not take
# anything away from `03-settings-window`: it deletes what it finds and makes its own, and what it finds is now
# the one made here rather than one left over from a run that may have died half way through.

google_calendar_id() { sql "SELECT IFNULL(json_extract(setting_value, '\$.calendar_id'), '') FROM setting WHERE setting_name = 'google_account';"; }

# **The delete-then-create, on its own so it can be run twice.** Once as the run finds things, and again after
# somebody has signed back in. It reports nothing and decides nothing: the caller owns what a failure means,
# because the same failure means "your token is dead" the first time and "signing in did not help" the second.
make_a_calendar() {
    local since

    if [ -n "$(google_calendar_id)" ]; then
        since=$(mark)
        press app-google-calendar-delete
        sleep 1
        press_title "Delete Calendar"
        # **Not fatal, and it carries on to Create.** The commonest reason a delete fails is that the calendar
        # is already gone -- somebody removed it at Google, or a run died between 03's delete and its create --
        # and stopping there would refuse to reach the known state over a calendar that is already in the state
        # wanted. A delete that failed for any other reason (no network, dead token) is caught by the Create
        # below, which cannot succeed without the thing the delete needed.
        if wait_for "$since" "Google calendar deleted,%" 45 >/dev/null; then
            step "last run's calendar is gone"
        else
            step "last run's calendar could not be deleted, so it was probably already gone; making a fresh one"
        fi
    fi

    # The one real request, and so the one real proof: this fails if the token is dead, if the account was
    # disconnected at Google, or if there is no network.
    since=$(mark)
    press app-google-calendar-create
    wait_for "$since" "Google calendar created,%" 45 >/dev/null
}

setup_google() {
    local email

    select_tab App
    email=$(sql "SELECT IFNULL(json_extract(setting_value, '\$.email'), '') FROM setting WHERE setting_name = 'google_account';")

    # **Only a person can fix this**, so it is asked rather than reported: signing in needs a browser and
    # somebody to consent, and `seed-private.sh` can only put back an account that existed. Asked here, at the
    # top, because the alternative is 03 failing four minutes in with a fault that looks like the app.
    if [ -z "$email" ]; then
        if action_required \
            "No Google account is connected, and this run needs one." \
            "03-settings-window and 10-google-calendar both fail without it, so the run cannot" \
            "clear CI as it stands." \
            "" \
            "The Settings window is open on the App tab. Press Connect, sign in in the browser," \
            "and come back here. It is captured and reseeded from then on, so this is asked once" \
            "per machine rather than once per run." \
            "" \
            "Answer n to carry on without one and let 03 and 10 fail."; then
            email=$(sql "SELECT IFNULL(json_extract(setting_value, '\$.email'), '') FROM setting WHERE setting_name = 'google_account';")
        fi
    fi

    if [ -z "$email" ]; then
        trouble "no Google account is connected, so 03 and 10 have nothing to work with"
        return 1
    fi

    if ! make_a_calendar; then
        # **The state a row cannot show, and this is the only place in the suite that deals with it.** Everything
        # above proves there is an email. Nothing about an email proves the connection behind it works, because the
        # two live in different places: the identity is in `google_account`, and the refresh token that makes it
        # usable is in the Keychain. The row reads identically whether the token beside it is present, revoked at
        # myaccount.google.com, expired through disuse, or simply not there at all. It is why the calendar is made
        # by pressing the button rather than by reading the row, and the press failing is the whole of the evidence
        # that the two have parted company.
        #
        # **Measured 2026-08-26**, which is what this branch was written for: `google_account` held a name, an email,
        # a calendar id and a calendar name, the App tab said Connected, and the app refused the delete with
        # `Facet is not connected to a Google account`. That message is `GoogleCalendarClient.currentAccessToken`
        # finding no refresh token in the Keychain -- so the missing half was the token, with a complete-looking row
        # sitting in front of it.
        #
        # **Reporting it is not enough, because the state repairs nothing on its own and the setup rebuilds it.**
        # `apply_private_seeds` writes the whole `google_account` value back at the top of this script, so a dead
        # token means the email is present on every run from now on, this branch is taken on every run from now on,
        # and a `trouble` line saying "sign in again" scrolls past while 03 and 10 fail for a reason that looks like
        # the app. So it stops and asks, in the same shape as the missing-email case above.
        if action_required \
            "The settings hold a Google account ($email) but the connection does not work." \
            "The identity is in the database and the token that makes it usable is in the" \
            "Keychain, and only the first of those is still there. The App tab says Connected" \
            "because the row is complete, which is exactly what cannot be trusted here." \
            "" \
            "03-settings-window and 10-google-calendar both fail without a working one." \
            "" \
            "The Settings window is open on the App tab. Press Disconnect, then Sign in with" \
            "Google, consent in the browser, and come back here." \
            "" \
            "Answer n to carry on with the dead connection and let 03 and 10 fail."; then
            email=$(sql "SELECT IFNULL(json_extract(setting_value, '\$.email'), '') FROM setting WHERE setting_name = 'google_account';")
        else
            trouble "the Google connection does not work and was left alone, so 03 and 10 have nothing to work with"
            return 1
        fi

        # **Checked before retrying, rather than pressing at a button that is not there.** The calendar row is only
        # drawn while the app thinks an account is connected, so after a Disconnect that was never followed by a
        # sign-in there is no Create to press -- and `press` says nothing when it finds nothing, so the retry would
        # spend 45 seconds waiting and then blame Google.
        if [ -z "$email" ]; then
            trouble "the account was disconnected but nothing was signed back in, so there is no connection to use"
            return 1
        fi

        if ! make_a_calendar; then
            trouble "the app still could not make a calendar at Google after signing in again, so the connection does not work"
            return 1
        fi

        # **Captured again, because the account signed in may not be the one that was there.** The seed still holds
        # the old email, and `apply_private_seeds` would write it over the row on the next run while the Keychain
        # holds a token for this one: the same two-answers disagreement, moved somewhere it is harder to see. This
        # is also what stops the question being asked again on every run from now on.
        capture_private_seeds
        step "signed in again, and the seeds now hold the account that works"
    fi

    if [ -z "$(google_calendar_id)" ]; then
        trouble "a calendar was made but no id was recorded, so nothing has anywhere to sync"
        return 1
    fi
    step "the Google account works and a calendar exists ($email, $(sql "SELECT json_extract(setting_value, '\$.calendar_name') FROM setting WHERE setting_name = 'google_account';"))"
    return 0
}

setup_google || true

# ---------------------------------------------------------------------------- the cube
#
# **Paired, wiped, and forgotten, in that order.** The reset needs a link, so the only way to hand the rest of
# the run a factory cube is to pair one first and give it up again. `52-device-reset` asserts every step of
# this; here it is only driven, and only the end state is read back.

setup_the_cube() {
    local since verdict resting autopause stored pressed

    select_tab Device

    # **Before a single button is pressed.** A radio left off by a run that was killed is the state this run would
    # otherwise spend a minute failing at, in `pair_a_cube` and then again in `50-device-scan`, both times reporting
    # it correctly and neither asking for it.
    if ! require_bluetooth; then
        trouble "Bluetooth is off, so there is no radio to reach a cube with"
        return 1
    fi

    if ! pair_a_cube; then
        trouble "the cube could not be paired, so it cannot be reset ($PAIR_REASON)"
        return 1
    fi
    step "paired, so there is a link to send the reset down"

    # ------------------------------------------------------------------ the cube stopping itself
    #
    # **A cube set to pause itself will do it in the middle of any script, and no script would survive that.** The
    # delay lives in the cube's flash and **a factory reset does not clear it** (finding 10,
    # `docs/timeflip2-firmware-observations.md`), so once one is set every run afterwards inherits it -- including
    # the two resets this run makes.
    #
    # **Run 135 (2026-08-29) is what that costs.** The cube had five minutes on it, sat untouched through
    # `60-device-backlog`'s wait for somebody to turn Bluetooth off, and stopped itself. The check that watches the
    # figure carry on counting failed, correctly, about a cube that had genuinely stopped -- and it read as the app
    # having given up on a cube that was still going, which is a different fault entirely and is where the next hour
    # went.
    #
    # **Asked of the cube rather than of the table**, because they are different questions: the row says what the app
    # last set, and this is about what the hardware is carrying. `0x10` answers with it on every status, and the app
    # says so in the log whenever it is not zero -- which is the only place the answer appears.
    autopause=$(dsql "SELECT message FROM debug_log WHERE tag = 'command' AND message LIKE 'The cube is %pausing itself after %' ORDER BY debug_log_id DESC LIMIT 1;")
    stored=$(setting auto_pause_minutes minutes)
    if [ -z "$autopause" ]; then
        step "the cube is not set to pause itself, so there is nothing to turn off"
    elif tree | grep -qE "id=device-auto-pause[[:space:]].*disabled"; then
        # **The field is dead unless a cube is connected**, so this names that rather than reporting the arrows as
        # broken. Checked before pressing anything, because `press` swallows its own failure: a press on a dead
        # control does nothing and says nothing, and the wait afterwards would blame the write.
        trouble "the Auto-pause field is dead, so the cube cannot be told to stop pausing itself -- is it connected?"
    elif [ "${stored:-0}" -gt 30 ]; then
        # Stepped one minute per press, so a long delay is a lot of clicking. Nothing in the suite sets one, and a
        # delay this long is somebody's own doing -- so it is handed back to them rather than clicked down by force.
        trouble "the Auto-pause field is on ${stored}m; turn that down to 0 on the Device tab by hand"
    else
        # **Stepped rather than typed.** Typing needs the field to take focus first, and `set_field_focused` throws
        # away both the reason it could not and the fact that it did not: run 137 (2026-08-29) failed this step having
        # produced no row at all, and the log could not say why. The arrows are what `65-auto-pause` drives, they need
        # no focus, and the debounce turns a run of presses into one command half a second after the last of them.
        #
        # **The field has to move, and from 0 it can only move up.** This is the case a clean run is always in: the
        # database was rebuilt, so `auto_pause_minutes` is the seeded 0 while the cube carries whatever it was last
        # told -- the table saying 0 is exactly why nobody noticed. Pressing down at the floor changes nothing, sends
        # nothing, and would fail this step for a third reason. So it goes up one and comes back.
        step "the cube is set to pause itself ($autopause), and the field is on ${stored:-0}m: stepping it to 0"
        since=$(mark)
        if [ "${stored:-0}" = "0" ]; then
            press device-auto-pause-up
            press device-auto-pause-down
        else
            pressed=0
            while [ "$pressed" -lt "${stored:-0}" ]; do
                press device-auto-pause-down
                pressed=$((pressed + 1))
            done
        fi
        if wait_for "$since" "Auto-pause: the table now holds 0m" 30 >/dev/null; then
            step "the cube will not stop itself during this run"
        else
            trouble "the cube would not take an auto-pause of 0 (the field reads $(element device-auto-pause)), so it may stop itself mid-run"
        fi
    fi

    # ------------------------------------------------------------------ where the cube is lying
    #
    # **The one thing about the device no later script can work out**, and it decides more than it looks. A face with
    # nothing assigned to it stops the cube by itself now (`ForcedPause`), so a cube resting on one is a cube every
    # script from `50` inherits stopped -- and which face it is resting on is simply where somebody last put it down.
    #
    # **Run 117 (2026-08-27) is what that costs.** The cube sat on face 1 from `50` to `55`, nothing before `55` having
    # any reason to ask for a turn, and the app duly stopped it. `57-cube-pause` then reported 36 of a declared 37 with
    # nothing failing, because the arm that checks a stop was skipped on a cube that arrived stopped.
    #
    # **Asked here because here is the only place it can be asked.** Every other script is entitled to know what it
    # inherits; this one is the only one facing a desk it knows nothing about. Asked while the cube is still connected,
    # so the answer is read back rather than trusted, and before the wipe, which clears the cube's flash and not the
    # desk it is lying on.
    #
    # **Satisfied by a cube already in the right place, and not asked about at all in that case.** This reads the
    # newest face the app knows rather than waiting for a change, because the face characteristic notifies on change
    # only: asking for a turn onto the face it is already on would wait for a notification nobody can produce.
    # `ask_and_detect` runs the query before it prints anything, so a run that starts with the cube already on Break
    # goes straight past this -- much the commonest case, since every run ends with it there.
    resting=$(sql "SELECT f.face_id FROM face f JOIN category c ON c.category_id = f.category_id WHERE c.category_name = 'Break' AND f.face_id BETWEEN 1 AND 12 ORDER BY f.face_id LIMIT 1;")
    if ! ask_and_detect \
        "SELECT message FROM debug_log WHERE debug_log_id = (SELECT MAX(debug_log_id) FROM debug_log WHERE tag = 'face' AND message LIKE 'Face % is up') AND message = 'Face $resting is up';" \
        "Put the cube down on the Break face, and leave it there" \
        "That is face $resting. Every device script starts from wherever the cube is now." \
        "If it is already there, this clears itself the moment the app reports the face." \
        "A face with nothing assigned stops the cube by itself, which is why the run needs a known one."
    then
        trouble "the cube was never put on the Break face, so the device scripts would start from an unknown one"
        return 1
    fi
    step "the cube is resting on face $resting, which is where the device range starts"

    since=$(mark)
    press device-reset
    sleep 1
    if ! alert_is_open; then
        trouble "Reset Device asked nothing, so the cube was not wiped"
        return 1
    fi
    press_sheet "Reset Device"

    # **Up to 140s, and the wait is the cube erasing.** It goes on answering its old PIN for several seconds
    # after acknowledging the command (8.5s and 11s across two measured runs), so the app retries; the verdict
    # lands when it gets in on the vendor PIN, which is the only proof a wipe happened at all.
    step "waiting for the cube to finish erasing and answer on the vendor PIN (up to 140s)..."
    verdict=$(wait_for "$since" "Reset: %" 140)
    case "$verdict" in
        *confirmed*) step "the cube is back on the vendor PIN, which is the wipe proved" ;;
        *) trouble "the cube never came back on the vendor PIN, so the wipe cannot be confirmed (${verdict:-no verdict in 140s})"
           return 1 ;;
    esac

    # The reset forgets the device as part of itself, so this is a read-back rather than another step.
    if [ "$(sql "SELECT json_extract(setting_value, '\$.paired') FROM setting WHERE setting_name = 'paired';")" != "0" ]; then
        trouble "the app still holds a pairing after the reset, so 50-device-scan would not start from nothing"
        return 1
    fi
    step "and the app has forgotten it, so the run starts from a cube it has never seen"
    return 0
}

if ask_about_the_device; then
    setup_the_cube || true
else
    # **Not trouble.** The person answered honestly and this script did everything it could; the run is
    # incomplete rather than broken, and that is `50-device-scan`'s to say. Said plainly here because it is
    # the moment somebody can still change their mind.
    yellow "##############################################################################"
    yellow "##"
    yellow "##  NO CUBE, SO THIS RUN CANNOT CLEAR CI"
    yellow "##"
    yellow "##  Everything up to 50-device-scan still runs. The run then STOPS there:"
    yellow "##  every script after it needs a cube, so there is nothing left to run."
    yellow "##"
    yellow "##  The stamp this writes will not pass CI, and the pull request cannot"
    yellow "##  merge on it. Somebody with a TimeFlip has to run the suite against this"
    yellow "##  branch and commit the stamp. See CONTRIBUTING.md."
    yellow "##"
    yellow "##############################################################################"
    echo ""
fi

# **Shut, both of them.** The window goes so nothing below inherits an open Settings, and the app goes so
# `01-launch` measures a launch it caused rather than finding one already up.
close_settings
quit_app

# ---------------------------------------------------------------------------- the one verdict

if [ -n "$TROUBLE" ]; then
    fail "the setup did not complete, so nothing below is starting from the state it expects:$TROUBLE"
else
    pass "the app, the database and the cube are in the state the rest of the run expects"
fi

finish
