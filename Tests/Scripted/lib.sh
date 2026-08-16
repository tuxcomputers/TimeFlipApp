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

# The durable record. `logs/screen.txt` is this run and only what was printed; `logs/testlog.sqlite` keeps
# every run, and keeps the app's own debug_log rows, which the next clean rebuild of test.sqlite destroys.
# Sourced after `DB` is set, because it reads from it.
source "$(dirname "${BASH_SOURCE[0]}")/testlog.sh"

# ---------------------------------------------------------------------------- output

blue()   { printf '\033[1;34m%s\033[0m\n' "$*"; }
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
grey()   { printf '\033[0;90m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }

# Stops the run and waits for the person running it. Answers 0 for yes, 1 for anything else.
#
#     action_required "Sign in to Google" "1. A browser opens." "2. Approve the account."
#
# **Drawn big on purpose.** Almost every check here runs untouched, so a run is something you start and
# come back to. A step that needs hands has to survive being scrolled past, which a sentence among two
# hundred lines of PASS does not.
#
# **Reads the terminal directly.** run.sh sends stdout through `tee` into a process substitution, so a
# prompt printed the ordinary way can sit in a buffer while the run looks like it has hung. `/dev/tty` is
# the terminal itself whatever stdout has been pointed at.
#
# **Non-interactive answers no**, rather than waiting for a person who is not there. A run with no
# terminal is CI or a pipe, and a step needing hands is one it should skip and say so.
action_required() {
    local title="$1"
    shift
    echo ""
    yellow "##############################################################################"
    yellow "##"
    yellow "##  ACTION REQUIRED"
    yellow "##"
    yellow "##  $title"
    yellow "##"
    local line
    for line in "$@"; do
        yellow "##    $line"
    done
    yellow "##"
    yellow "##############################################################################"
    echo ""

    if [ ! -r /dev/tty ]; then
        grey "  no terminal to ask, so this is being skipped"
        return 1
    fi

    local answer=""
    printf '  Type y and press Return when you are ready (anything else skips this): '
    read -r answer < /dev/tty || return 1
    echo ""
    case "$answer" in
        y | Y | yes | YES | Yes) return 0 ;;
        *) return 1 ;;
    esac
}

start() {
    echo ""
    blue "=============================================================================="
    blue "$SCRIPT_NAME: $*"
    blue "=============================================================================="
    testlog_script_start "$SCRIPT_NAME" "$*"
}

# **What is being checked is printed before the verdict, on its own line.**
#
#     a segment is open going into the quit (id 113)
#       PASS
#
# Two lines rather than one because a run is watched as well as read afterwards: several checks here wait
# on a network round trip or a ten-second timer, and a single line printed on the way out leaves the
# terminal silent for as long as the slowest step takes, with nothing saying which step it is. The
# description goes out first, and the verdict lands under it when the answer is known.
#
# `LAST` is what the description was, so the summary at the end can name a failure without every caller
# repeating itself.
LAST=""
LAST_STARTED=0
LAST_LOG_MARK=0
LAST_EXPECTED=""
LAST_ACTUAL=""
announce() {
    LAST="$*"
    # Stamped here rather than at the verdict, so the log records how long the check actually waited. The
    # slow ones are the ones worth knowing about: a check that takes 45s is usually timing out.
    LAST_STARTED=$(date +%s)
    LAST_LOG_MARK=$(app_log_mark)
    LAST_EXPECTED=""
    LAST_ACTUAL=""
    printf '  %s\n' "$*"
}

verdict_pass() { PASSED=$((PASSED + 1)); green "    PASS"; testlog_check pass; }

# **A failed check stops its script there and then.** Every check starts from the state the ones above it
# left, so once one has failed the rest are being run against a state nobody intended and their verdicts
# mean nothing. Carrying on produced exactly that on 2026-08-16: a rename that never happened was
# reported as one failure, and the check that read the name back was reported as a second, as though two
# things were wrong.
#
# The cost is real and worth knowing: independent failures further down are not found until the next run.
# That same run had a daily limit fault with nothing to do with the rename, and stopping at the first
# would have hidden it. `--keep-going` is there for the pass where finding everything matters more than
# reading it cleanly.
FAIL_FAST="${FAIL_FAST:-1}"
verdict_fail() {
    FAILED=$((FAILED + 1))
    FAILURES="$FAILURES
  - $LAST${1:+ ($1)}"
    red "    FAIL${1:+  $1}"
    testlog_check fail "${1:-}"

    if [ "$FAIL_FAST" = "1" ]; then
        red "    stopping here: everything below starts from the state this check just failed to reach"
        grey "    (Tests/Scripted/run.sh --keep-going runs the rest anyway)"
        finish
        exit 1
    fi
}

# `pass "what was checked"` and `fail "what was checked"` for the cases a script decides for itself.
pass() { [ $# -gt 0 ] && announce "$*"; verdict_pass; }
fail() { [ $# -gt 0 ] && announce "$*"; verdict_fail; }

# `check "name" "expected" "actual"` -- the common shape, so a failure prints both sides without every
# script formatting its own message.
check() {
    announce "$1"
    LAST_EXPECTED="$2"
    LAST_ACTUAL="$3"
    if [ "$2" = "$3" ]; then
        verdict_pass
    else
        verdict_fail "expected '$2', got '$3'"
    fi
}

check_contains() {
    local name="$1" haystack="$2" needle="$3"
    announce "$name"
    case "$haystack" in
        *"$needle"*) verdict_pass ;;
        *)
            # Truncated: the haystack is often the whole accessibility tree, and printing it buries the
            # failure it is supposed to explain.
            local shown="${haystack:0:160}"
            [ "${#haystack}" -gt 160 ] && shown="$shown..."
            verdict_fail "no '$needle' in '$shown'"
            ;;
    esac
}

# Neither passed nor failed: the thing could not be checked here, and saying so is more honest than a
# tick. A skipped check does not fail the script -- an account nobody has connected is not a defect --
# but it is printed loudly enough that nobody reads the run as fuller coverage than it was.
SKIPPED=0
skip() { SKIPPED=$((SKIPPED + 1)); announce "$*"; printf '\033[0;33m    SKIP\033[0m\n'; testlog_check skip; }

# Ends the script and decides its exit status. Non-zero on any failure, which is what lets run.sh stop
# rather than carry on into scripts whose starting state the failure just invalidated.
FINISHED=0
finish() {
    # Called twice where a script does `fail ...; finish; exit 1` and the failure already stopped it. The
    # second call must report the same verdict and not write the record again.
    if [ "$FINISHED" = "1" ]; then
        [ "$FAILED" -eq 0 ]
        return
    fi
    FINISHED=1

    # Before anything is printed, because this is where the app's own debug_log rows are copied out of
    # test.sqlite -- and a script that exits straight after `finish` would otherwise take them with it.
    testlog_script_finish "$PASSED" "$FAILED" "${SKIPPED:-0}"
    echo ""
    local skipped=""
    [ "${SKIPPED:-0}" -gt 0 ] && skipped=", $SKIPPED skipped"
    if [ "$FAILED" -eq 0 ]; then
        green "$SCRIPT_NAME: $PASSED passed, 0 failed$skipped"
    else
        red "$SCRIPT_NAME: $PASSED passed, $FAILED FAILED$skipped$FAILURES"
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

# The next unused name in a numbered family: `next_name Timer` answers `Timer 1` on a database built from
# nothing, and `Timer 18` on one that already holds seventeen.
#
# **Because an active category name has to be unique.** These scripts create categories and delete none,
# so a fixed name works once and collides on every `--keep` run afterwards -- the app would raise its
# "already exists" alert and the create would be refused, failing a check that has nothing to do with what
# is being tested. The names used to carry a clock stamp for that reason, which worked and made every
# category unreadable (`Scripted 09:14:22`) and every failure message different from the last.
#
# The number is a high-water mark, not a count. It reads the largest number already used and goes one
# past, so a gap left by a deleted row is simply never reused -- which is what makes it safe to derive
# other names from it (`$NAME renamed`, `$NAME reactivate`) without checking each one.
next_name() {
    local prefix="$1" highest
    highest=$(sql "SELECT IFNULL(MAX(CAST(SUBSTR(category_name, LENGTH('$prefix') + 2) AS INTEGER)), 0)
                     FROM category
                    WHERE category_name GLOB '$prefix [0-9]*';")
    printf '%s %s' "$prefix" "$(( ${highest:-0} + 1 ))"
}

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
    # Announced before the wait, not after it. This is the one that can sit for a minute waiting on
    # Google, and a terminal that says nothing for a minute looks stuck rather than busy.
    announce "$name"
    if found=$(wait_for "$since" "$pattern" "$timeout"); then
        verdict_pass
        grey "          $found"
    else
        verdict_fail "no debug_log row matching '$pattern' within ${timeout}s"
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
        if ! codesign -dvvv "$APP" 2>&1 | grep -q "TeamIdentifier=[A-Z0-9]"; then
            grey "  note: the running app is ad-hoc signed, so anything reading the Keychain (Google sync)"
            grey "        will stall on a prompt. Quit it and let this rebuild, or use scripts/run.sh."
        fi
        return 0
    fi
    if [ ! -x "$BINARY" ] || [ -n "$(find Sources -newer "$BINARY" -name '*.swift' -print -quit 2>/dev/null)" ]; then
        grey "  building (sources are newer than the bundle)..."
        # **Signed, exactly as scripts/run.sh signs it.** An ad-hoc build is a different application to
        # the Keychain, so the refresh token behind Google sync stops being readable without a prompt --
        # and nothing says so: the sweep just never runs. That is how 10-google-calendar failed the first
        # time it was written, against a binary this function had built unsigned.
        identity="$(scripts/codesign-identity.sh)"
        signing=""
        [ -n "$identity" ] && signing="--codesign --identity $identity"
        if ! mint run stackotter/swift-bundler@main bundle Facet $signing >/dev/null 2>&1; then
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

# For a field nothing has clicked into, where the Return that follows has to commit an edit.
#
# **`set_field` alone is not enough there.** It writes AXValue, which changes what the field shows without
# opening an editing session, so a `press_return` afterwards goes to whatever does have focus and the
# value is never committed -- the field displays the new number and the table keeps the old one. A
# category name escapes this because pressing the name makes the field first responder itself; a daily
# limit does not, and typed into with `set_field` it silently did nothing (measured 2026-08-16: the tree
# showed `category-limit-3 value=45` while the table still held 0).
set_field_focused() { python3 scripts/ax-set.py --focus "$1" "$2" >/dev/null 2>&1; }
tree()       { python3 scripts/ax-dump.py 2>/dev/null; }

# The buttons of the alert that is up, in the order they are drawn, joined with `|` so one check can
# assert the whole set rather than probing for each.
#
# **Read off the sheet, not off the window.** Several checks here turn on a button being *absent*, and
# a grep over the tree would count a `Cancel` belonging to something else -- reporting the button as
# present when the alert never offered it. Empty when no sheet is up, which fails such a check instead
# of passing it silently.
alert_buttons() { python3 scripts/ax-alert.py 2>/dev/null | tr '\n' '|' | sed 's/|$//'; }

# Whether a sheet is up at all. Worth its own check before opening the next one: an alert nobody
# dismissed is modal, so every later press lands on nothing and the failures arrive somewhere else.
alert_is_open() { python3 scripts/ax-alert.py >/dev/null 2>&1; }

# One element's line from the tree, so a check reads the thing it is about rather than searching the
# whole window -- and a failure prints that line rather than several hundred.
element() { tree | grep -m1 "id=$1 " || true; }

settings_is_open() { tree | grep -q "close-settings"; }

# Waits for an element to appear, rather than sleeping a guessed amount and hoping.
#
# **Pressing something that rebuilds the pane leaves a gap.** A refused rename reloads the whole list, so
# for a moment the row being addressed is a view on its way out, and a press lands on nothing. A fixed
# sleep either loses that race or wastes time on every run that would not have. This lost it on
# 2026-08-16: the name cell was still a button when the field was written to, so nothing was committed and
# no log row was written at all -- a failure with no evidence in it beyond the tree.
wait_for_element() {
    local identifier="$1" timeout="${2:-5}" waited=0
    while [ "$waited" -lt "$((timeout * 5))" ]; do
        tree | grep -q "id=$identifier " && return 0
        sleep 0.2
        waited=$((waited + 1))
    done
    return 1
}

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
