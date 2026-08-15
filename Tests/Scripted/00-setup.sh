#!/bin/bash
# Seeds the database before anything runs against it.
#
# **First, because a rebuilt database is empty and some checks need something to have been true already.**
# The default run rebuilds `test.sqlite` from the DDL, which is what makes a run say what the app does
# from nothing -- but a few things cannot be created by driving the app and are lost with the rebuild.
# This is where they are put back. Add a section per seed.
#
# Two directions, one file:
#
#   Tests/Scripted/00-setup.sh --capture   read the seeds out of the database as it stands now
#   Tests/Scripted/00-setup.sh             write them into the database
#
# `run.sh` calls `--capture` **before** it rebuilds and runs this normally afterwards, so a connection
# made once carries across every later run without anybody thinking about it.
#
# **The seed file lives outside the repository**, beside the OAuth client credentials it is a companion
# to (`~/.config/facet/`). It holds a real email address and a real calendar id, which are nobody else's
# business: this repository takes outside contributions, and a seed committed into it would put one
# developer's account into everybody's checkout.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEED_DIR="$HOME/.config/facet"
SEED="$SEED_DIR/scripted-seed.json"

require_test_database

# ---------------------------------------------------------------------------- capture

if [ "${1:-}" = "--capture" ]; then
    # Quietly, and never fatally: this runs before every rebuild, and a machine with nothing to capture
    # is the normal case for anybody who has not connected an account.
    value=$(sql "SELECT setting_value FROM setting WHERE setting_name = 'google_account';" 2>/dev/null || true)
    email=$(printf '%s' "$value" | python3 -c "import json,sys
try: print(json.load(sys.stdin).get('email') or '')
except Exception: print('')" 2>/dev/null || true)

    if [ -z "$email" ]; then
        exit 0
    fi

    mkdir -p "$SEED_DIR"
    chmod 700 "$SEED_DIR" 2>/dev/null || true
    printf '%s' "$value" | python3 -c "import json,sys
print(json.dumps({'google_account': sys.stdin.read()}, indent=2))" > "$SEED"
    chmod 600 "$SEED" 2>/dev/null || true
    echo "Captured the connected Google account for the next run ($email)."
    exit 0
fi

# ---------------------------------------------------------------------------- seed

start "seeding the database before anything runs against it"

# **Nothing is running yet.** This writes straight to the table, which every other script in this folder
# is forbidden from doing -- and it is right here for the same reason it is wrong there: there is no app
# to disagree with, and the app reads this row when its window opens rather than holding it from launch.

if [ ! -f "$SEED" ]; then
    skip "no seed file at $SEED, so nothing to seed"
    skip "connect a Google account and run again -- run.sh captures it before the next rebuild"
    finish
    exit 0
fi

# ---------------------------------------------------------------------------- the Google account
#
# **The token survives a rebuild and the account does not.** The refresh token is in the login Keychain,
# which no database rebuild touches, but the identity and the calendar the app reads are rows -- so a
# fresh database shows "not connected" while the machine is still perfectly able to reach Google. Putting
# the row back is what lets 10-google-calendar run on a clean database instead of skipping every time.

account=$(python3 -c "
import json, sys
with open('$SEED') as f:
    print(json.load(f).get('google_account', ''))
" 2>/dev/null || true)

if [ -z "$account" ]; then
    skip "the seed file holds no Google account"
    finish
    exit 0
fi

email=$(printf '%s' "$account" | python3 -c "import json,sys; print(json.load(sys.stdin).get('email') or '')")

# Written and then read back, which is the same rule the app follows for its own writes: a statement that
# reported success and did not happen would leave every later script testing a connection that is not
# there, and reporting it as a Google failure.
sql "UPDATE setting SET setting_value = '$(printf '%s' "$account" | sed "s/'/''/g")' WHERE setting_name = 'google_account';"

stored=$(sql "SELECT json_extract(setting_value, '\$.email') FROM setting WHERE setting_name = 'google_account';")
check "the Google account is seeded ($email)" "$email" "$stored"

calendar=$(sql "SELECT json_extract(setting_value, '\$.calendar_name') FROM setting WHERE setting_name = 'google_account';")
if [ -n "$calendar" ]; then
    pass "with its calendar ($calendar)"
else
    skip "no calendar in the seed -- 10 will make one"
fi

# ---------------------------------------------------------------------------- fractional segments
#
# **Rows whose `duration_seconds` carries a fraction, and unsynced entries for them.** This is a
# regression seed: it recreates the shape of the data that broke Google sync completely, so every run
# meets it again.
#
# What happened. `time_entry` 27 held `duration_seconds = 147.612311840057`. The event body sent to
# Google truncated that to whole seconds and the expectation it was checked against did not, so the
# read-back disagreed by 0.6 of a second, the row was never ticked, and every later sweep retried the
# same row for ever -- taking every entry behind it down with it. Nothing in `swift test` could find it:
# the app only ever writes whole seconds now, so this shape arrives only from history already recorded.
#
# A device face (8), not one of the app's own (13, 14), so these look like a cube's rows and nothing in
# the suite that reasons about manual faces picks them up by accident. Finalised and processed, because
# they already have their entries: an unprocessed row would be re-examined by the entry sweep.

seeded_before=$(sql "SELECT COUNT(*) FROM time_entry WHERE duration_seconds != CAST(duration_seconds AS INTEGER);")

if [ "${seeded_before:-0}" -gt 0 ]; then
    pass "fractional entries are already here ($seeded_before), leaving them alone"
else
    zone=$(sql "SELECT timezone_id FROM timezone WHERE timezone_name = '$(date '+%Z' >/dev/null 2>&1; echo "$(python3 -c 'import time;print(time.tzname[0])')")' LIMIT 1;")
    # Falls back to the seeded Unknown row (id 0), which every timestamp column defaults to anyway. That
    # is itself a path worth having in the data: an entry filed before a real zone was resolved.
    zone=${zone:-0}

    now=$(date +%s)
    for pair in "147.612311840057:1" "38.6364130973816:2" "9.5:1"; do
        secs="${pair%%:*}"
        category="${pair##*:}"
        # Spread back through the last couple of hours so they land inside the day the report covers.
        start=$((now - 7200 + RANDOM % 3600))
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
    done

    fractional=$(sql "SELECT COUNT(*) FROM time_entry WHERE duration_seconds != CAST(duration_seconds AS INTEGER);")
    check "three entries seeded with fractional durations" "3" "$fractional"

    unsynced=$(sql "SELECT COUNT(*) FROM time_entry WHERE synced_to_google_calendar = 0 AND duration_seconds != CAST(duration_seconds AS INTEGER);")
    check "and all of them are waiting to sync" "3" "$unsynced"

    # The one that mattered, kept exactly: if this stops being a fraction the regression seed has stopped
    # regressing anything.
    check_contains "including the duration that broke it" \
        "$(sql "SELECT group_concat(duration_seconds) FROM time_entry WHERE duration_seconds != CAST(duration_seconds AS INTEGER);")" \
        "147.612311840057"
fi

finish
