#!/usr/bin/env python3
"""Deletes the calendar Facet made, so a run starts by making a new one.

**Deleting the calendar, not emptying it.** Emptying it was the obvious version and it was wrong, in a
way that took a whole green run to notice (2026-08-16):

Google does not remove a deleted event. It keeps it as `cancelled`, and **its id can never be used
again**. Facet's event ids are derived from the row -- `facet<time_entry_id>` -- and a clean run rebuilds
the database, so `time_entry_id` restarts at 1. Deleting the events therefore burned exactly the ids the
next run was going to ask for: `insert` came back 409, the read-back said `cancelled`, the row was never
ticked, and every later sweep retried the same rows for ever. The suite reported ALL PASSED with four
entries permanently stuck, because it only ever checked the entry it had just made.

A new calendar has no cancelled ids in it, so the collision cannot happen at all. That is the whole
reason this deletes rather than empties.

**Scoped to the calendar in the private seed and refuses to widen.** The id comes from there and nowhere
else, and this will not run without one: a bug that reached for the primary calendar would be deleting
somebody's actual diary. The OAuth scope Facet holds (`calendar.app.created`) cannot touch a calendar it
did not make, which is a second wall behind this one rather than a reason to drop the first.

The refresh token comes out of the login Keychain, which is not this script's item -- **macOS asks the
first time**, once, and remembers if you answer "Always Allow".

Exits 0 with a message when it cannot run (no seed, no token, no network). Nothing here is worth failing
a whole run over: the app makes a calendar when it finds none, so a run that could not delete the old one
still has every other check in it.
"""
import json
import pathlib
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

SEED = pathlib.Path.home() / ".config" / "facet" / "scripted-seed.json"
CLIENT = pathlib.Path.home() / ".config" / "facet" / "google-client.json"
KEYCHAIN_SERVICE = "au.com.tux.facet.google"
TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token"
API = "https://www.googleapis.com/calendar/v3/calendars"


def give_up(reason):
    print(f"  not deleting the calendar: {reason}")
    sys.exit(0)


def pending():
    """Every calendar this harness has made and not yet managed to delete.

    **A list rather than the one current id, because nothing can go and look afterwards.**
    `calendarList.list` returns nothing usable under `calendar.app.created` (measured 2026-08-15), so a
    calendar this misses is invisible from then on and has to be deleted by hand in Google Calendar. A
    delete that fails therefore cannot be forgotten: the id stays here and is tried again next run, so a
    run without network defers the cleanup instead of orphaning it.
    """
    if not SEED.exists():
        give_up("no private seed, so no calendar is known")
    seed = json.loads(SEED.read_text())

    ids = [str(one).strip() for one in seed.get("calendars") or [] if str(one).strip()]
    # A seed written before the list existed carries only the current id.
    account = json.loads(seed.get("google_account", "{}"))
    current = (account.get("calendar_id") or "").strip()
    if current and current not in ids:
        ids.append(current)

    if not ids:
        give_up("the seed names no calendar")
    return seed, ids


def remember(seed, ids):
    seed["calendars"] = ids
    SEED.write_text(json.dumps(seed, indent=2))
    SEED.chmod(0o600)


def access_token():
    if not CLIENT.exists():
        give_up(f"no OAuth client at {CLIENT}")
    installed = json.loads(CLIENT.read_text()).get("installed") or {}

    try:
        refresh = subprocess.run(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", "refresh-token", "-w"],
            capture_output=True, text=True, timeout=60,
        )
    except subprocess.TimeoutExpired:
        give_up("the Keychain prompt went unanswered")
    if refresh.returncode != 0:
        give_up("no refresh token in the Keychain -- sign in to Google once")

    body = urllib.parse.urlencode({
        "client_id": installed.get("client_id", ""),
        "client_secret": installed.get("client_secret", ""),
        "refresh_token": refresh.stdout.strip(),
        "grant_type": "refresh_token",
    }).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(TOKEN_ENDPOINT, data=body), timeout=30) as answer:
            return json.load(answer)["access_token"]
    except (urllib.error.URLError, KeyError, TimeoutError) as error:
        give_up(f"could not get an access token ({error})")


def delete(identifier, token):
    """True when the calendar is gone, however it got that way."""
    call = urllib.request.Request(f"{API}/{urllib.parse.quote(identifier, safe='')}", method="DELETE")
    call.add_header("Authorization", f"Bearer {token}")
    try:
        urllib.request.urlopen(call, timeout=30)
        return True
    except urllib.error.HTTPError as error:
        # Already gone is the outcome being asked for.
        return error.code in (404, 410)
    except (urllib.error.URLError, TimeoutError):
        return False


def main():
    seed, ids = pending()
    token = access_token()

    left = [one for one in ids if not delete(one, token)]
    remember(seed, left)

    deleted = len(ids) - len(left)
    if left:
        # Said out loud rather than passed over. These are invisible to everything but this file, so a run
        # that quietly gave up on them is how somebody ends up with a column of Facet-test calendars.
        print(f"  deleted {deleted} calendar(s), {len(left)} would not go and will be tried again")
    else:
        print(f"  deleted {deleted} calendar(s), none left behind")


if __name__ == "__main__":
    main()
