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
    printf '%s' "$value" | python3 -c "
import json, sys
print(json.dumps({'google_account': sys.stdin.read()}, indent=2))" > "$SEED"
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

    calendar=$(sql "SELECT json_extract(setting_value, '\$.calendar_name') FROM setting WHERE setting_name = 'google_account';")
    if [ -n "$calendar" ]; then
        pass "with its calendar ($calendar)"
    else
        skip "no calendar in the seed -- 10 will make one"
    fi
}

# Empties the calendar Facet made, so a run starts against a clean one.
#
# **Not a seed, but it belongs here**: it needs the calendar id from the private seed and the refresh
# token from the Keychain, which is everything this file exists to keep out of the repository.
#
# Without it every clean run leaves its events behind and the next one adds more, until the calendar is
# weeks of `Scripted 09:14:22` and nothing can be told apart. It is the test calendar, so there is
# nothing in it worth keeping -- and `clear-calendar.py` will not touch any other, because the only id it
# will act on is the one in the seed.
clear_google_calendar() {
    announce "the calendar is emptied before the run"
    local output
    output=$(python3 "$(dirname "${BASH_SOURCE[0]}")/clear-calendar.py" 2>&1)
    printf '%s\n' "$output" | sed 's/^/  /'
    case "$output" in
        *"cleared "*|*"already empty"*) verdict_pass ;;
        # Not a failure. The events are cosmetic, and a run that could not reach Google still has every
        # other check in it worth running -- 10 is where an unreachable Google is a real verdict.
        *) skip "the calendar could not be cleared" ;;
    esac
}
