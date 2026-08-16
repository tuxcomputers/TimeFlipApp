#!/bin/bash
# The seeds that cannot be written down here: real accounts, real ids, anything belonging to one person.
#
# **Sourced by `00-setup.sh`, never run on its own.** It is separated from the ordinary seeds because the
# two have opposite rules. An ordinary seed is written into `00-setup.sh` in full, where anybody can read
# what a run starts from. A private one holds a real email address, a real calendar id, and in time
# whatever else identifies a person's account -- so what lives here is the *mechanism*, and the values
# live outside the repository entirely.
#
# This repository takes outside contributions. A seed committed into it would put one developer's account
# into everybody's checkout, and the first anybody would know is their own calendar filling with somebody
# else's time.
#
# Where the values go: `~/.config/facet/scripted-seed.json`, 0600, in the directory that already holds
# the OAuth client credentials for the same reason.
#
# To add another private seed: capture it in `capture_private_seeds` and write it back in
# `apply_private_seeds`, keyed by name in the same file. Nothing else needs to change.

SEED_DIR="$HOME/.config/facet"
SEED="$SEED_DIR/scripted-seed.json"

# Reads the private values out of the database as it stands, before a rebuild takes them away.
#
# **Silent and never fatal.** This runs before every clean run, and a machine with nothing to capture --
# anybody who has not connected an account -- is the ordinary case rather than a problem.
capture_private_seeds() {
    local value email
    value=$(sql "SELECT setting_value FROM setting WHERE setting_name = 'google_account';" 2>/dev/null || true)
    email=$(printf '%s' "$value" | python3 -c "
import json, sys
try:
    print(json.load(sys.stdin).get('email') or '')
except Exception:
    print('')" 2>/dev/null || true)

    [ -z "$email" ] && return 0

    mkdir -p "$SEED_DIR"
    chmod 700 "$SEED_DIR" 2>/dev/null || true

    # **Merged into the seed, not written over it.** The file also carries every calendar the harness has
    # made and not yet deleted, and that list is the only record there is: `calendarList.list` returns
    # nothing usable under `calendar.app.created` (measured 2026-08-15), so a calendar dropped from here
    # can never be found again and has to be deleted by hand. Clobbering the file each capture would do
    # exactly that, one calendar per run.
    printf '%s' "$value" | SEED_FILE="$SEED" python3 -c "
import json, os, pathlib, sys

path = pathlib.Path(os.environ['SEED_FILE'])
seed = {}
if path.exists():
    try:
        seed = json.loads(path.read_text())
    except ValueError:
        seed = {}

account = sys.stdin.read()
seed['google_account'] = account

waiting = [str(one) for one in seed.get('calendars') or []]
current = (json.loads(account).get('calendar_id') or '').strip()
if current and current not in waiting:
    waiting.append(current)
seed['calendars'] = waiting

path.write_text(json.dumps(seed, indent=2))
path.chmod(0o600)
"
    chmod 600 "$SEED" 2>/dev/null || true
    echo "Captured the connected Google account for the next run ($email)."
}

# Writes them into the fresh database.
apply_private_seeds() {
    if [ ! -f "$SEED" ]; then
        skip "no private seeds at $SEED"
        skip "connect a Google account once -- it is captured before the next rebuild and put back after"
        return 0
    fi

    # **The token survives a rebuild and the account does not.** The refresh token is in the login
    # Keychain, which no rebuild touches, so the machine can still reach Google perfectly well while a
    # fresh database says nobody is connected. Putting the row back is what lets the calendar checks run
    # on a clean database instead of skipping every time.
    local account email stored calendar
    account=$(python3 -c "
import json
with open('$SEED') as f:
    print(json.load(f).get('google_account', ''))" 2>/dev/null || true)

    if [ -z "$account" ]; then
        skip "the private seed file holds no Google account"
        return 0
    fi

    email=$(printf '%s' "$account" | python3 -c "import json,sys; print(json.load(sys.stdin).get('email') or '')")

    # Written and then read back, as the app does for its own writes: a statement that reported success
    # and did not happen would leave every later script testing a connection that is not there, and
    # reporting it as a Google failure.
    sql "UPDATE setting SET setting_value = '$(printf '%s' "$account" | sed "s/'/''/g")' WHERE setting_name = 'google_account';"

    stored=$(sql "SELECT json_extract(setting_value, '\$.email') FROM setting WHERE setting_name = 'google_account';")
    check "the Google account is seeded ($email)" "$email" "$stored"

    # Reported because it is what the next step needs in order to delete the right calendar, not because
    # the run wants to keep it. Either way 10 makes a fresh one.
    calendar=$(sql "SELECT json_extract(setting_value, '\$.calendar_name') FROM setting WHERE setting_name = 'google_account';")
    if [ -n "$calendar" ]; then
        pass "naming last run's calendar, which is the one to delete ($calendar)"
    else
        skip "the seed names no calendar, so there is none to delete"
    fi
}

# Deletes the calendar Facet made and forgets it locally, so the run starts with no calendar at all and
# `10-google-calendar` makes a fresh one.
#
# **Not a seed, but it belongs here**: it needs the calendar id from the private seed and the refresh
# token from the Keychain, which is everything this file exists to keep out of the repository.
#
# **The two halves are one act and must not drift apart.** Deleting it at Google without clearing the row
# leaves Facet holding an id that no longer resolves; clearing the row without deleting it leaves an
# orphan calendar behind on every run. So they live in one function.
#
# Deleting rather than emptying is the fix for a bug a whole green run hid -- a deleted Google *event*
# keeps its id for ever, and a rebuilt database hands those same ids straight back out. `delete-calendar.py`
# has the full account. It will not touch any calendar but the one in the seed.
delete_google_calendar() {
    announce "the calendar is deleted before the run, so a fresh one is made"
    local output
    output=$(python3 "$(dirname "${BASH_SOURCE[0]}")/delete-calendar.py" 2>&1)
    printf '%s\n' "$output" | sed 's/^/  /'
    case "$output" in
        *"none left behind"*) verdict_pass ;;
        # **Not a failure, and not silent either.** A calendar that would not go is invisible to everything
        # but the seed file, so it is retried next run rather than forgotten -- but saying nothing here is
        # how somebody ends up with a column of them and no idea when it started.
        *"will be tried again"*) skip "a calendar would not delete; it is kept and retried next run" ;;
        *) skip "the calendar could not be deleted" ;;
    esac

    # **Blanked, not removed.** Writing "" is how the app itself forgets a calendar when Google says it is
    # gone (`forgetAndOfferGoogleCalendar`), so the row is left in the shape the app already reads rather
    # than in a second one invented here.
    sql "UPDATE setting
            SET setting_value = json_set(setting_value, '\$.calendar_id', '', '\$.calendar_name', '')
          WHERE setting_name = 'google_account';"

    check "and Facet no longer holds a calendar" "|" \
        "$(sql "SELECT json_extract(setting_value, '\$.calendar_id') || '|' || json_extract(setting_value, '\$.calendar_name') FROM setting WHERE setting_name = 'google_account';")"
}
