"""Runs once per supervisor invocation, before any checklist: warns the developer this
run manipulates a real physical device, then establishes the known state every checklist
assumes (test database active, device connected) -- see "Switch to the test database" in
../../Tests/Methods.md for the underlying pre-flight rules this mirrors.
"""

import json
import os
import sqlite3
import subprocess
import time

APP_BINARY_REL = ".build/bundler/apps/TimeFlip/TimeFlip.app/Contents/MacOS/TimeFlip"

WARNING_TEMPLATE = """
################################################################################
  WARNING -- this run manipulates the REAL, PHYSICAL TimeFlip device.

  It switches the app to a TEST database first. Your production history is NOT
  at risk: it first restarts the app to force a fresh history fetch against
  production (rather than waiting on the periodic fetch timer, which may be
  set as long as 15 minutes) and confirms that fetch completed, so everything
  real is already safely recorded before any testing starts. From that point
  on, all test activity -- locking/unlocking,
  pausing/resuming, changing settings (LED, auto-pause, double-tap
  sensitivity), event history -- happens only against the test database, never
  production.{reset_warning}

  At the end of the run, the device is factory reset and needs a quick re-pair
  click from you. This wipes the test session's activity from the device's own
  onboard counter, so none of it can leak into your real history. You'll then
  be asked whether to switch the app back to the production database now, or
  stay on test (handy if you're about to run more tests).

  Do NOT run this while you're relying on the device to track real time --
  its current activity will be interrupted until you switch back to production.
################################################################################
"""

RESET_WARNING = (
    "\n\n  This run also includes the reset-device checklist itself (02b/02i) -- in\n"
    "  addition to the end-of-run cleanup reset described below, the device is\n"
    "  factory reset and re-paired mid-run, as the test being exercised."
)


def confirm_warning(checklist_paths):
    includes_reset = any(
        "02b" in os.path.basename(p) or "02i" in os.path.basename(p) for p in checklist_paths
    )
    print(WARNING_TEMPLATE.format(reset_warning=RESET_WARNING if includes_reset else ""))
    while True:
        answer = input("Type 'I understand' to proceed, or 'Not yet' if you're not ready: ").strip().lower()
        if answer == "i understand":
            return True
        if answer == "not yet":
            return False
        print("Not recognized -- please type exactly 'I understand' or 'Not yet'.")


def _read_db_type(db_path):
    """db_type is stored as JSON, e.g. {"type":"test"} -- returns just "test"/"production"."""
    conn = sqlite3.connect(db_path)
    try:
        row = conn.execute("SELECT setting_value FROM setting WHERE setting_name='db_type';").fetchone()
        if not row:
            return None
        return json.loads(row[0]).get("type")
    finally:
        conn.close()


def _last_event_is_paused(db_path):
    """The most recent device_event's is_paused flag, ordered by start_epoch (the schema's
    stable time ordering -- event_number can reset independently of wall-clock time, see
    database/CLAUDE.md). Returns True (paused), False (timing an activity), or None if the
    database has no events yet."""
    conn = sqlite3.connect(db_path)
    try:
        row = conn.execute(
            "SELECT is_paused FROM device_event ORDER BY start_epoch DESC, device_event_id DESC LIMIT 1;"
        ).fetchone()
    finally:
        conn.close()
    if row is None:
        return None
    return row[0] == 1


def ensure_not_timing_on_production(db_path):
    """Pre-flight guard: refuses to start a test run while the app is on the PRODUCTION
    database and the device is mid-timing a real activity (its last synced event isn't a
    pause). This run switches to the test database and factory-resets the device at the
    end, so proceeding would interfere with that live timing event. Only guards production
    -- on the test database there's nothing real to protect. Returns True if it's safe to
    proceed, False (with an explanatory print) if the developer must pause the device
    first. Reflects the last state the app synced to the DB; if you just flipped the
    device, give it a moment to sync before re-running."""
    # Runs first, before any prompt -- so don't let sqlite3.connect() create an empty file
    # if it's missing; the setup checklist (00-test-setup.md) surfaces a missing DB itself.
    if not os.path.exists(db_path):
        return True
    if _read_db_type(db_path) != "production":
        return True
    # Read the concrete production.sqlite directly (the symlink points at it right now),
    # consistent with the rest of this module's post-switch queries.
    if _last_event_is_paused(os.path.realpath(db_path)) is False:
        print(
            "\n!!! The app is on the PRODUCTION database and the device is currently TIMING a\n"
            "    real activity (its last event isn't a pause). Pause the device first, then\n"
            "    re-run -- otherwise this test run (which switches to the test database and\n"
            "    factory-resets the device at the end) would interfere with that real timing\n"
            "    event."
        )
        return False
    return True


def _app_running():
    r = subprocess.run(["pgrep", "-f", "TimeFlip.app/Contents/MacOS/TimeFlip"], capture_output=True, text=True)
    return r.returncode == 0


def _quit_app(timeout=10):
    """Sends the AppleScript quit, then polls until the process actually disappears --
    a fixed sleep trusted the quit silently, so a stuck/ignored quit (a dialog waiting
    on input, an AppleScript error swallowed by capture_output) would fall through to
    _launch_app() launching a second instance on top of the still-running first one,
    instead of surfacing the failure. Returns False (without launching anything) if the
    process is still there after timeout."""
    subprocess.run(["osascript", "-e", 'tell application "TimeFlip" to quit'], capture_output=True, text=True)
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not _app_running():
            return True
        time.sleep(1)
    return False


def _launch_app(repo_root):
    binary = os.path.join(repo_root, APP_BINARY_REL)
    subprocess.Popen([binary], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def _latest_debug_log_id(db_path):
    conn = sqlite3.connect(db_path)
    try:
        row = conn.execute("SELECT MAX(debug_log_id) FROM debug_log;").fetchone()
        return row[0] or 0
    finally:
        conn.close()


def _sibling_db_path(db_path, filename):
    """db_path is the appdata.sqlite symlink; resolves to one of the actual files it can
    point at (production.sqlite/test.sqlite), directly, regardless of what the symlink
    currently points at -- needed because debug_log_id is per-file, not global, so a
    baseline captured through the symlink before a switch is only meaningful if it's
    read from the file the switch will land on, not whichever file happened to be
    active a moment ago."""
    return os.path.join(os.path.dirname(db_path), filename)


def _wait_for_reconnect(db_path, since_id=0, timeout=30):
    """since_id must be the max debug_log_id captured BEFORE quitting/launching --
    debug_log persists across restarts, so an unscoped query would immediately match
    a stale pre-restart login row instead of waiting for a genuine new one."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        conn = sqlite3.connect(db_path)
        try:
            row = conn.execute(
                "SELECT debug_log_id FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Login accepted%' "
                "AND debug_log_id > ? ORDER BY debug_log_id DESC LIMIT 1;",
                (since_id,),
            ).fetchone()
        finally:
            conn.close()
        if row:
            return True
        time.sleep(2)
    return False


def restore_production_database(db_path, repo_root):
    """Runs once, after the end-of-run device cleanup reset: repoints appdata.sqlite back
    at production.sqlite (scripts/use-production-database.sh) and confirms the app
    reconnects against it, the reverse of the production->test switch that
    Tests/00-test-setup.md does at the start. Without this, the app is silently left pointed
    at test.sqlite until someone
    notices and runs that script by hand."""
    print("\n=== End-of-run cleanup: restoring the production database ===")

    db_type = _read_db_type(db_path)
    if db_type == "production":
        print("Already on the production database -- nothing to restore.")
        return True
    if db_type != "test":
        print(f"  unexpected db_type {db_type!r} -- not switching automatically. "
              "Run scripts/use-production-database.sh manually once you've confirmed it's safe.")
        return False

    # Read production.sqlite's own current max id directly, by its real path -- not
    # through the appdata.sqlite symlink, which still points at test.sqlite at this
    # point. debug_log_id is per-file: a since_id read through the symlink here would be
    # test.sqlite's own (small, session-local) counter, which production.sqlite's much
    # larger, already-accumulated history would trivially exceed immediately, making the
    # reconnect wait below pass on a stale pre-existing row instead of a genuinely fresh
    # one (the mirror image of the prod->test bug this session just fixed).
    since_id = _latest_debug_log_id(_sibling_db_path(db_path, "production.sqlite"))
    if not _quit_app():
        print("  app did not quit -- refusing to launch a second instance on top of it. "
              "Quit it manually, then re-run.")
        return False
    r = subprocess.run(["scripts/use-production-database.sh"], cwd=repo_root, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  error running use-production-database.sh: {r.stderr.strip()}")
        return False
    _launch_app(repo_root)
    # Pinned now, right after use-production-database.sh repointed the symlink -- query
    # this concrete file directly for the reconnect wait, not the symlink.
    production_path = os.path.realpath(db_path)
    if not _wait_for_reconnect(production_path, since_id=since_id):
        print("  error: device did not reconnect after switching back to production.")
        return False
    db_type = _read_db_type(db_path)
    if db_type != "production":
        print(f"  error: expected db_type='production' after switching back, got {db_type!r}.")
        return False
    print("  Switched back to the production database; device reconnected.")
    return True


def reset_device_for_cleanup(db_path):
    """Runs once, at the end of the whole invocation (after every requested checklist
    has finished, pass or fail): factory-resets the device and re-pairs it, so no
    test-session activity (event counter advances, LED/auto-pause/double-tap changes)
    can leak into production history once the developer switches back manually. Reuses
    the exact AX paths verified live in Tests/Bench/02b's own reset scenario -- see that
    file's toml step blocks for where these were derived and confirmed."""
    from actions import run_step  # local import: avoids a hard circular dependency at module load

    ctx = {"db_path": db_path, "vars": {}}
    print("\n=== End-of-run cleanup: factory-resetting the device ===")

    r = run_step(
        {
            "actions": [
                {"action": "click_menu_item", "item": "Settings..."},
                {"action": "shell", "command": "sleep 1"},
                {
                    "action": "applescript",
                    "script": (
                        'tell application "System Events"\n'
                        '    tell process "TimeFlip"\n'
                        '        click radio button 1 of radio group 1 of group 1 of toolbar 1 of window "TimeFlip Settings"\n'
                        "    end tell\n"
                        "end tell"
                    ),
                },
            ]
        },
        ctx,
    )
    if not r.success:
        print(f"  could not open Settings/Device tab: {r.detail} -- skipping cleanup reset.")
        return False

    run_step({"action": "sql_query", "query": "SELECT MAX(debug_log_id) FROM debug_log;", "capture": "cleanup_before_id"}, ctx)

    r = run_step(
        {
            "action": "applescript",
            "script": (
                'tell application "System Events"\n'
                '    tell process "TimeFlip"\n'
                '        if exists button 2 of group 3 of scroll area 1 of group 1 of window "TimeFlip Settings" then\n'
                '            click button 2 of group 3 of scroll area 1 of group 1 of window "TimeFlip Settings"\n'
                "            delay 0.5\n"
                '            click button 2 of sheet 1 of window "TimeFlip Settings"\n'
                '            return "clicked"\n'
                "        else\n"
                '            return "not_paired"\n'
                "        end if\n"
                "    end tell\n"
                "end tell"
            ),
        },
        ctx,
    )
    if not r.success:
        print(f"  could not click Reset Device: {r.detail} -- skipping cleanup reset.")
        return False
    if r.detail.strip() == "not_paired":
        print("  device already shows unpaired -- nothing to reset.")
        return True

    r = run_step(
        {
            "action": "wait_for_sql",
            "query": "SELECT message FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Factory reset confirmed%' "
            "AND debug_log_id > $cleanup_before_id ORDER BY debug_log_id DESC LIMIT 1;",
            "expect_contains": "Factory reset confirmed",
            "timeout_seconds": 60,
        },
        ctx,
    )
    if not r.success:
        print(f"  reset did not confirm: {r.detail} -- pair/reset the device manually before relying on it again.")
        return False
    print("  Factory reset confirmed -- the test session's activity is wiped from the device.")

    run_step(
        {
            "actions": [
                {
                    "action": "applescript",
                    "script": (
                        'tell application "System Events"\n'
                        '    tell process "TimeFlip"\n'
                        '        click button 1 of group 3 of scroll area 1 of group 1 of window "TimeFlip Settings"\n'
                        "    end tell\n"
                        "end tell"
                    ),
                },
                {"action": "shell", "command": "sleep 2"},
            ]
        },
        ctx,
    )

    r = run_step(
        {
            "action": "ask_user_or_detect",
            "prompt": "End-of-run cleanup: click the discovered device's row in Settings to re-pair it (can't be scripted).",
            # Select debug_log_id (unique, monotonic), not message -- "Login accepted,
            # code=0x02" repeats verbatim on every login, including the reset
            # confirmation itself, so comparing text never detects a genuinely new row.
            "detect_query": "SELECT debug_log_id FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Login accepted%' "
            "ORDER BY debug_log_id DESC LIMIT 1;",
            "timeout_seconds": 120,
        },
        ctx,
    )
    if not r.success:
        print(f"  re-pair not detected: {r.detail} -- please pair the device manually before using it again.")
        return False
    print("  Device re-paired. Cleanup complete.")
    return True
