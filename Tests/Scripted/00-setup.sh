#!/bin/bash
# Seeds the database before anything runs against it.
#
# **First, because a rebuilt database is empty and some checks need something to have been true already.**
# The default run rebuilds `test.sqlite` from the DDL, which is what makes a run say what the app does
# from nothing -- but a few things cannot be created by driving the app, and are lost with the rebuild.
# This is where they are put back. Add a section per seed.
#
#   Tests/Scripted/00-setup.sh --capture   read the private seeds out of the database as it stands
#   Tests/Scripted/00-setup.sh             write every seed into the database
#
# `run.sh` calls `--capture` **before** it rebuilds and runs this normally afterwards.
#
# **Ordinary seeds are written out here in full**, so anybody reading this file can see exactly what a run
# starts from. The ones that cannot be -- a real account, a real calendar id, anything belonging to one
# person -- live in `seed-private.sh`, which holds the mechanism while the values stay outside the
# repository altogether. See that file for why.
#
# **This writes straight to the tables**, which every other script in this folder is forbidden from doing.
# It is right here for the same reason it is wrong there: nothing is running yet, so there is no app to
# disagree with, and the app reads all of this when it starts rather than holding it from before.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/seed-private.sh"

require_test_database

if [ "${1:-}" = "--capture" ]; then
    capture_private_seeds
    exit 0
fi

start "seeding the database before anything runs against it"

apply_private_seeds

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
# On a device face (8) rather than one of the app's own (13, 14), so they read as a cube's rows and
# nothing in the suite that reasons about manual faces picks them up by accident. Finalised and
# processed, because they already have their entries: an unprocessed row would be re-examined by the
# entry sweep and counted twice.

fractional=$(sql "SELECT COUNT(*) FROM time_entry WHERE duration_seconds != CAST(duration_seconds AS INTEGER);")

if [ "${fractional:-0}" -gt 0 ]; then
    pass "history with fractional durations is already here ($fractional entries), leaving it alone"
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
    for pair in "147.612311840057:1" "38.6364130973816:2" "9.5:1"; do
        secs="${pair%%:*}"
        category="${pair##*:}"
        start=$((hour_ago + offset))
        offset=$((offset + 600))
        whole=${secs%%.*}

        sql "INSERT INTO device_event (
                 event_number, event_type_id, device_face, start_time, timezone_id,
                 start_epoch, duration_seconds, paused, finalised, processed
             ) VALUES (
                 $start, 1, 8, strftime('%Y-%m-%dT%H:%M:%S', $start, 'unixepoch', 'localtime'), $zone,
                 $start, $secs, 0, 1, 1
             );"

        event=$(sql "SELECT device_event_id FROM device_event WHERE start_epoch = $start AND event_number = $start;")
        [ -z "$event" ] && continue

        # **Unsynced on purpose.** The sweep in 10 is what carries them, and carrying a fractional one is
        # the thing that used to be impossible.
        sql "INSERT INTO time_entry (
                 category_id, device_event_id, started_at, start_timezone_id,
                 ended_at, end_timezone_id, duration_seconds, synced_to_google_calendar
             ) VALUES (
                 $category, $event,
                 strftime('%Y-%m-%dT%H:%M:%S', $start, 'unixepoch', 'localtime'), $zone,
                 strftime('%Y-%m-%dT%H:%M:%S', $((start + whole)), 'unixepoch', 'localtime'), $zone,
                 $secs, 0
             );"
        seeded=$((seeded + 1))
    done

    check "three segments seeded with fractional durations" "3" "$seeded"

    check "and their entries are all waiting to sync" "3" \
        "$(sql "SELECT COUNT(*) FROM time_entry WHERE synced_to_google_calendar = 0 AND duration_seconds != CAST(duration_seconds AS INTEGER);")"

    # The one that mattered, kept exactly. If this stops being a fraction the seed has stopped guarding
    # anything.
    check_contains "including the duration that broke it" \
        "$(sql "SELECT group_concat(duration_seconds) FROM time_entry WHERE duration_seconds != CAST(duration_seconds AS INTEGER);")" \
        "147.612311840057"

    # Dated rather than assumed. The point of the hour is that these show up beside what the run itself
    # records, without anybody changing the range to find them.
    check "dated within the last hour" "$(date -r $hour_ago '+%Y-%m-%d')" \
        "$(sql "SELECT date(de.start_epoch, 'unixepoch', 'localtime') FROM device_event de
                 JOIN time_entry te ON te.device_event_id = de.device_event_id
                WHERE te.duration_seconds != CAST(te.duration_seconds AS INTEGER)
                ORDER BY de.start_epoch LIMIT 1;")"
fi

finish
