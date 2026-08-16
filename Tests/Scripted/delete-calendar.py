#!/usr/bin/env python3
"""Deletes every event from the one calendar Facet made, so a run starts against an empty one.

Without this a clean run leaves its events behind and the next one adds more, so the calendar fills with
weeks of `Scripted 09:14:22` and nothing can be told apart by eye. Clearing it makes what a run put there
the only thing in it.

**Scoped to one calendar and refuses to widen.** The id comes from the private seed and nothing else, and
this will not run without one: a bug that reached for the primary calendar would be deleting somebody's
actual diary. The OAuth scope this app holds (`calendar.app.created`) cannot touch a calendar it did not
make, which is a second wall behind this one rather than a reason to skip the first.

The refresh token comes out of the login Keychain, which is not this script's item -- **macOS asks the
first time**, once, and remembers if you answer "Always Allow". There is no way around that short of
keeping a second copy of the token outside the Keychain, which is exactly what the app deliberately does
not do.

Exits 0 with a message when it cannot run (no seed, no token, no network). Nothing here is worth failing
a whole run over: the events are cosmetic.
"""
import json
import os
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
    print(f"  not clearing the calendar: {reason}")
    sys.exit(0)


def calendar_id():
    if not SEED.exists():
        give_up("no private seed, so no calendar is known")
    account = json.loads(json.loads(SEED.read_text()).get("google_account", "{}"))
    found = (account.get("calendar_id") or "").strip()
    if not found:
        give_up("the seed holds no calendar id")
    return found, (account.get("calendar_name") or "unnamed")


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


def request(url, token, method="GET"):
    call = urllib.request.Request(url, method=method)
    call.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(call, timeout=30) as answer:
        raw = answer.read()
        return json.loads(raw) if raw else {}


def main():
    identifier, name = calendar_id()
    token = access_token()
    quoted = urllib.parse.quote(identifier, safe="")

    # Every page, since a calendar with a few hundred events in it is exactly the one worth clearing.
    # `showDeleted=false` so events already cancelled are not deleted a second time.
    events, page = [], None
    while True:
        url = f"{API}/{quoted}/events?maxResults=250&showDeleted=false"
        if page:
            url += f"&pageToken={page}"
        try:
            answer = request(url, token)
        except urllib.error.HTTPError as error:
            give_up(f"could not list events ({error.code})")
        events.extend(item["id"] for item in answer.get("items", []) if item.get("id"))
        page = answer.get("nextPageToken")
        if not page:
            break

    if not events:
        print(f"  the {name} calendar is already empty")
        return

    deleted, failed = 0, 0
    for event in events:
        try:
            request(f"{API}/{quoted}/events/{urllib.parse.quote(event, safe='')}", token, method="DELETE")
            deleted += 1
        except urllib.error.HTTPError as error:
            # 410 is already gone, which is the outcome being asked for.
            if error.code == 410:
                deleted += 1
            else:
                failed += 1

    print(f"  cleared {deleted} event(s) from the {name} calendar" + (f", {failed} refused" if failed else ""))


if __name__ == "__main__":
    main()
