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

  It will switch the app to a TEST database and, depending which checklists you
  passed, may lock/unlock it, pause/resume it, and change its settings (LED,
  auto-pause, double-tap sensitivity).{reset_warning}

  Do NOT run this while you're relying on the device to track real time --
  its current activity will be interrupted, and it will not resume tracking
  normally in your production data until you switch back to the production
  database (scripts/use-production-database.sh) and relaunch the app.
################################################################################
"""

RESET_WARNING = (
    "\n\n  This run INCLUDES a reset-device checklist -- the device WILL be factory\n"
    "  reset (0xFF) and end up unpaired. A fresh Scan/re-pair is required after."
)


def confirm_warning(checklist_paths):
    includes_reset = any(
        "02b" in os.path.basename(p) or "02i" in os.path.basename(p) for p in checklist_paths
    )
    print(WARNING_TEMPLATE.format(reset_warning=RESET_WARNING if includes_reset else ""))
    answer = input("Type 'yes' to confirm you understand and want to proceed: ").strip().lower()
    return answer == "yes"


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


def _history_fetch_confirmed(db_path):
    conn = sqlite3.connect(db_path)
    try:
        row = conn.execute(
            "SELECT message FROM debug_log WHERE tag='history' AND message LIKE '%DB refreshed%' "
            "ORDER BY debug_log_id DESC LIMIT 1;"
        ).fetchone()
        return row is not None
    finally:
        conn.close()


def _app_running():
    r = subprocess.run(["pgrep", "-f", "TimeFlip.app/Contents/MacOS/TimeFlip"], capture_output=True, text=True)
    return r.returncode == 0


def _quit_app():
    subprocess.run(["osascript", "-e", 'tell application "TimeFlip" to quit'], capture_output=True, text=True)
    time.sleep(2)


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
        if not _app_running():
            print("error: app isn't running, so a production->test switch can't be pre-flighted safely. "
                  "Launch the app on production first, let it sync, then re-run.")
            return False
        if not _history_fetch_confirmed(db_path):
            print("error: no completed history fetch found against production yet -- wait for the "
                  "device to finish syncing (debug_log tag 'history', 'DB refreshed'), then re-run.")
            return False
        print("History fetch confirmed against production. Switching to the test database...")
        since_id = _latest_debug_log_id(db_path)
        _quit_app()
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
