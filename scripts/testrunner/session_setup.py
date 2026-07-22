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


def _wait_for_history_fetch_complete(db_path, trigger, since_id=0, timeout=60):
    """Polls for HistoryIngestor.refreshHistory()'s own "history fetch complete: trigger=..."
    marker (logged on every exit path, whether or not anything actually changed -- unlike
    the old, narrower "DB refreshed" text, which is only ever logged on the
    nothing-changed branch and never appears at all for a fetch that pulls in a real
    backlog). since_id must be captured before the triggering restart/action, same
    reasoning as _wait_for_reconnect."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        conn = sqlite3.connect(db_path)
        try:
            row = conn.execute(
                "SELECT debug_log_id FROM debug_log WHERE tag='history' "
                "AND message = ? AND debug_log_id > ? ORDER BY debug_log_id DESC LIMIT 1;",
                (f"history fetch complete: trigger={trigger}", since_id),
            ).fetchone()
        finally:
            conn.close()
        if row:
            return True
        time.sleep(2)
    return False


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


def ensure_known_state(db_path, repo_root):
    """Returns True once the test database is active and the device is connected;
    False (with an explanatory print) if that state can't be safely established."""
    print("\n=== Establishing known device/database state ===")

    if not os.path.exists(db_path):
        print(f"error: {db_path} does not exist. Launch the app manually once first, then re-run.")
        return False

    db_type = _read_db_type(db_path)
    print(f"Current db_type: {db_type!r}")

    if db_type == "test":
        print("Already on the test database -- not switching again this session.")
    elif db_type == "production":
        print(
            "Ensuring real history is fully preserved against production before switching -- "
            "restarting the app now to force a fresh history fetch, rather than waiting on "
            "the periodic fetch timer (a developer may have set that as long as 15 minutes)."
        )
        since_id = _latest_debug_log_id(db_path)
        if _app_running():
            if not _quit_app():
                print("error: app did not quit -- refusing to launch a second instance on top of it. "
                      "Quit it manually, then re-run.")
                return False
        _launch_app(repo_root)
        if not _wait_for_reconnect(db_path, since_id=since_id):
            print("error: device did not reconnect after restarting against production.")
            return False
        if not _wait_for_history_fetch_complete(db_path, trigger="startup", since_id=since_id):
            print("error: startup history fetch against production did not complete in time -- "
                  "check the device connection, then re-run.")
            return False
        print("Real history confirmed synced against production. Switching to the test database...")
        since_id = _latest_debug_log_id(db_path)
        if not _quit_app():
            print("error: app did not quit -- refusing to launch a second instance on top of it. "
                  "Quit it manually, then re-run.")
            return False
        r = subprocess.run(["scripts/use-test-database.sh"], cwd=repo_root, capture_output=True, text=True)
        if r.returncode != 0:
            print(f"error running use-test-database.sh: {r.stderr.strip()}")
            return False
        _launch_app(repo_root)
        if not _wait_for_reconnect(db_path, since_id=since_id):
            print("error: device did not reconnect after switching to the test database.")
            return False
        db_type = _read_db_type(db_path)
        if db_type != "test":
            print(f"error: expected db_type='test' after switching, got {db_type!r}. Stopping.")
            return False
        print("Switched to the test database; device reconnected.")
    else:
        print(f"error: unexpected db_type {db_type!r} -- stopping rather than guessing what to do.")
        return False

    if not _app_running():
        print("App isn't running -- launching it...")
        since_id = _latest_debug_log_id(db_path)
        _launch_app(repo_root)
        if not _wait_for_reconnect(db_path, since_id=since_id):
            print("error: device did not connect after launching. Pair/reconnect it, then re-run.")
            return False
    elif not _wait_for_reconnect(db_path, since_id=0, timeout=5):
        # App was already running -- a quick, unscoped check is enough here (any past
        # login row is fine, we're not restarting anything); a real disconnect would
        # still surface once checklist steps start querying/asserting against it.
        print("warning: no 'Login accepted' row found at all -- the device may never have "
              "paired against this database. Continuing, but expect early steps to fail if so.")

    print("Device connected. Known state established.")
    return True


def restore_production_database(db_path, repo_root):
    """Runs once, after the end-of-run device cleanup reset: repoints appdata.sqlite back
    at production.sqlite (scripts/use-production-database.sh) and confirms the app
    reconnects against it, mirroring ensure_known_state()'s production->test switch in
    reverse. Without this, the app is silently left pointed at test.sqlite until someone
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

    since_id = _latest_debug_log_id(db_path)
    if not _quit_app():
        print("  app did not quit -- refusing to launch a second instance on top of it. "
              "Quit it manually, then re-run.")
        return False
    r = subprocess.run(["scripts/use-production-database.sh"], cwd=repo_root, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  error running use-production-database.sh: {r.stderr.strip()}")
        return False
    _launch_app(repo_root)
    if not _wait_for_reconnect(db_path, since_id=since_id):
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
