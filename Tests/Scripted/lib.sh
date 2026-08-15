#!/bin/bash
# Shared machinery for every script in this folder. Sourced, never run.
#
# What a script written against this looks like: `start "what is being checked"`, then a series of
# `check` calls, then `finish`. Everything else here exists to make those three honest.
#
# Three rules are baked in rather than left to each script to remember:
#
#   1. **It refuses to run against production.** These scripts write real rows -- categories, segments,
#      time entries -- and there is no undo. The database must be the test one.
#   2. **Evidence comes from the database, not from the screen.** A check waits for a `debug_log` row or
#      queries a table. Asking a person "did it work?" records their optimism.
#   3. **Every wait is baselined.** `mark` records the newest `debug_log` id *before* the action, and
#      `wait_for` only looks at rows after it. Without that, a matching row from ten minutes ago passes
#      a step that did nothing -- and this database is used by a person as well as by these scripts, so
#      it is never safe to assert on a total count.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

SUPPORT="$HOME/Library/Application Support/Facet"
DB="$SUPPORT/appdata.sqlite"
APP=".build/bundler/apps/Facet/Facet.app"
BINARY="$APP/Contents/MacOS/Facet"

PASSED=0
FAILED=0
SCRIPT_NAME="$(basename "${BASH_SOURCE[1]:-unknown}" .sh)"
FAILURES=""

# ---------------------------------------------------------------------------- output

blue()  { printf '\033[1;34m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
grey()  { printf '\033[0;90m%s\033[0m\n' "$*"; }

start() {
    echo ""
    blue "=============================================================================="
    blue "$SCRIPT_NAME: $*"
    blue "=============================================================================="
}

# A named check with its own verdict. The name is what a reader sees when it fails, so it says what
# was expected rather than what was called.
pass() { PASSED=$((PASSED + 1)); green "  PASS  $*"; }
fail() {
    FAILED=$((FAILED + 1))
    FAILURES="$FAILURES
  - $*"
    red "  FAIL  $*"
}

# `check "name" "expected" "actual"` -- the common shape, so a failure prints both sides without every
# script formatting its own message.
check() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$name"
    else
        fail "$name (expected '$expected', got '$actual')"
    fi
}

check_contains() {
    local name="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) pass "$name" ;;
        *) fail "$name (no '$needle' in '$haystack')" ;;
    esac
}

# Ends the script and decides its exit status. Non-zero on any failure, which is what lets run.sh stop
# rather than carry on into scripts whose starting state the failure just invalidated.
finish() {
    echo ""
    if [ "$FAILED" -eq 0 ]; then
        green "$SCRIPT_NAME: $PASSED passed, 0 failed"
    else
        red "$SCRIPT_NAME: $PASSED passed, $FAILED FAILED$FAILURES"
    fi
    [ "$FAILED" -eq 0 ]
}

# ---------------------------------------------------------------------------- the database

# Refuses production, and says how to switch. Every script calls this before it touches anything.
require_test_database() {
    if [ ! -e "$DB" ]; then
        red "No database at $DB. Run scripts/switch-database.sh test first."
        exit 2
    fi
    local target
    target="$(readlink "$DB" || echo "$DB")"
    case "$target" in
        *test.sqlite) grey "  database: test.sqlite" ;;
        *)
            red "REFUSING TO RUN: appdata.sqlite points at '$target', not test.sqlite."
            red "These scripts write real rows and nothing undoes them."
            red "Switch with: scripts/switch-database.sh test"
            exit 2
            ;;
    esac
}

sql() { sqlite3 "$DB" "$1"; }

# The newest debug_log id right now. Every wait is measured from one of these -- see rule 3 above.
mark() { sql "SELECT IFNULL(MAX(debug_log_id), 0) FROM debug_log;"; }

# Waits for a debug_log row after `since` whose message matches `pattern` (a SQL LIKE, so % is the
# wildcard). Prints the message it found, empty on timeout.
#
# Polling the table rather than sleeping a fixed time: the app writes the row when the thing actually
# happened, so this is as fast as the app is and still correct on a slow machine.
wait_for() {
    local since="$1" pattern="$2" timeout="${3:-15}"
    local waited=0 found=""
    while [ "$waited" -lt "$((timeout * 10))" ]; do
        found=$(sql "SELECT message FROM debug_log WHERE debug_log_id > $since AND message LIKE '$pattern' ORDER BY debug_log_id LIMIT 1;")
        [ -n "$found" ] && { printf '%s' "$found"; return 0; }
        sleep 0.1
        waited=$((waited + 1))
    done
    return 1
}

# `expect_log "name" "$since" "pattern"` -- the shape most checks take.
expect_log() {
    local name="$1" since="$2" pattern="$3" timeout="${4:-15}"
    local found
    if found=$(wait_for "$since" "$pattern" "$timeout"); then
        pass "$name"
        grey "        $found"
    else
        fail "$name (no debug_log row matching '$pattern' within ${timeout}s)"
    fi
}

# Waits for a query to return `want`, for a side effect that lands in a table rather than the log.
wait_for_value() {
    local query="$1" want="$2" timeout="${3:-15}"
    local waited=0
    while [ "$waited" -lt "$((timeout * 10))" ]; do
        [ "$(sql "$query")" = "$want" ] && return 0
        sleep 0.1
        waited=$((waited + 1))
    done
    return 1
}

# ---------------------------------------------------------------------------- the app

is_running() { pgrep -x Facet >/dev/null 2>&1; }

# Builds if the bundle is missing or older than the sources, then launches.
#
# **The build is not optional and not a convenience.** A binary older than the change under test passes
# and proves nothing; that has cost this project an hour once already (see Tests/Methods.md, Method 1).
ensure_app_running() {
    if is_running; then
        grey "  app: already running"
        return 0
    fi
    if [ ! -x "$BINARY" ] || [ -n "$(find Sources -newer "$BINARY" -name '*.swift' -print -quit 2>/dev/null)" ]; then
        grey "  building (sources are newer than the bundle)..."
        if ! mint run stackotter/swift-bundler@main bundle Facet >/dev/null 2>&1; then
            red "  the build failed; running an old binary would prove nothing"
            exit 2
        fi
    fi
    grey "  launching $(stat -f '%Sm' "$BINARY")"
    open "$APP"
    local waited=0
    while [ "$waited" -lt 100 ]; do
        is_running && { sleep 1; return 0; }
        sleep 0.1
        waited=$((waited + 1))
    done
    red "  the app did not start"
    exit 2
}

# Quits through the menu, which is the app's own way out and the only one that runs the quit sequence.
quit_app() {
    is_running || return 0
    close_settings
    python3 scripts/status-item-click.py >/dev/null 2>&1
    sleep 0.5
    python3 scripts/ax-press.py quit-app >/dev/null 2>&1
    local waited=0
    while [ "$waited" -lt 100 ]; do
        is_running || return 0
        sleep 0.1
        waited=$((waited + 1))
    done
    grey "  the menu quit did not take; killing"
    pkill -x Facet
}

# ---------------------------------------------------------------------------- driving the window

press()      { python3 scripts/ax-press.py "$1" >/dev/null 2>&1; }
press_title() { python3 scripts/ax-press.py --title "$1" >/dev/null 2>&1; }

# Posts Return, for the one thing a value cannot be written into: an inline edit that commits on the key
# rather than on a button (Tests/Methods.md Method 10). The field being typed into holds focus, so there
# is nowhere else for the key to land.
#
# **Escape is never posted, here or anywhere.** It reaches whatever has focus, and what has focus is
# often the terminal session driving the app.
press_return() {
    python3 - <<'PYTHON'
import Quartz, time
for down in (True, False):
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, Quartz.CGEventCreateKeyboardEvent(None, 36, down))
    time.sleep(0.05)
PYTHON
}
press_desc() { python3 scripts/ax-press.py --desc "$1" >/dev/null 2>&1; }
set_field()  { python3 scripts/ax-set.py "$1" "$2" >/dev/null 2>&1; }
tree()       { python3 scripts/ax-dump.py 2>/dev/null; }

settings_is_open() { tree | grep -q "close-settings"; }

open_settings() {
    settings_is_open && return 0
    python3 scripts/status-item-click.py >/dev/null 2>&1
    sleep 0.5
    press open-settings
    sleep 1
    settings_is_open
}

close_settings() {
    settings_is_open || return 0
    press close-settings
    sleep 0.5
}

# The tabs carry no AXIdentifier -- a Settings tab button is matched on its description instead, which
# is Archive/Tests/Methods.md Method 10's finding and still true of this app's window.
select_tab() {
    press_desc "$1"
    sleep 0.7
}
