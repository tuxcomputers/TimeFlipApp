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
# **The trace lives in its own file**, beside the app's rather than inside it, so a check that waits on a `debug_log`
# row reads a different database from one that reads `device_event`. `dsql` is that database's `sql`, and which one a
# query wants is decided by which table it names -- see the two of them below.
#
# It is not a symlink like `appdata.sqlite` and does not need to be: it holds no data worth keeping between runs, and
# `switch-database.sh` repoints the app's file without this one caring which side it lands on.
DEBUG_DB="$SUPPORT/debug.sqlite"
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
#
# **Only `y` or `n` is an answer, and anything else asks again.** This used to treat every key that was
# not a yes as a no, which is a mistyped character silently choosing the destructive one: on 2026-08-18 a
# stray `t` skipped the whole Google calendar section, and the run finished green having not checked it.
# A skip is a real answer somebody may want to give, so it keeps its key -- what it no longer has is every
# other key on the keyboard as a synonym. EOF still ends it, so a closed pipe cannot loop for ever.
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
    while true; do
        printf '  Answer y (go ahead) or n (skip this): '
        read -r answer < /dev/tty || return 1
        case "$answer" in
            y | Y | yes | YES | Yes) echo ""; return 0 ;;
            n | N | no | NO | No) echo ""; return 1 ;;
            *) red "  '$answer' is not an answer here. Type y or n." ;;
        esac
    done
}

# Holds the run until the person running it says go. Unlike `action_required` there is nothing to decide:
# any answer continues, and the return is always 0.
#
# **For the point where something has just happened and is worth watching.** A script that detects a state
# change and races straight on gives nobody time to bring a window forward or start looking, and the part
# they wanted to see is over before they find it. This stops instead, says what it found, and waits.
#
# Reads `/dev/tty` for the same reason `action_required` does: run.sh pipes stdout through tee, so an
# ordinary prompt can sit in a buffer while the run looks like it has hung. With no terminal it carries on
# rather than blocking a run nobody is watching.
wait_for_dev() {
    local title="$1"
    shift
    echo ""
    yellow "##############################################################################"
    yellow "##"
    yellow "##  PAUSED -- $title"
    yellow "##"
    local line
    for line in "$@"; do
        yellow "##    $line"
    done
    yellow "##"
    yellow "##############################################################################"
    echo ""

    if [ ! -r /dev/tty ]; then
        grey "  no terminal to wait on, so carrying straight on"
        return 0
    fi
    # **No key in particular**, unlike `action_required`: there is nothing being decided here, so there is no
    # wrong key to press and nothing a mistyped one could choose. Asking for `y` would only be a rule with
    # no answer behind it.
    printf '  Press Return when you are ready to carry on: '
    read -r _ < /dev/tty || true
    echo ""
    return 0
}

# Asks for something only a pair of hands can do, then watches the database until it has happened.
#
#     ask_and_detect "SELECT message FROM debug_log WHERE ... ;" \
#         "Turn the cube to the Break face" \
#         "Break is face 8; the app is watching for it"
#
# Answers 0 once the query returns anything at all, and 1 when there is no terminal to ask.
#
# **Detected, not confirmed**, which is the archive's rule and the reason nothing here says "have you done
# that? (y/n)". A person answering yes records their optimism; the app's own row records the cube. It is
# also what makes a mis-turn harmless: the query names the face that was asked for, so turning the cube to
# some other one simply does not satisfy it and the banner is still on screen saying which one.
#
# **No timeout, deliberately.** A physical action takes as long as the person takes, and a run that failed
# because they answered the door would be failing about the wrong thing. `Archive/testrunner/actions.py`
# reached the same place from the other direction: `act_ask_user_or_detect` treats `timeout_seconds = 0` as
# "wait indefinitely" and says why in the same words. It reports that it is still waiting every half minute,
# so an unattended run reads as waiting rather than as hung.
#
# **A run with no terminal skips rather than blocking.** That is CI or a pipe, and there is nobody there to
# turn anything -- the same answer `action_required` gives, for the same reason.
ask_and_detect() {
    local query="$1" title="$2"
    shift 2
    echo ""
    yellow "##############################################################################"
    yellow "##"
    yellow "##  OVER TO YOU -- THE CUBE NEEDS TURNING"
    yellow "##"
    yellow "##  $title"
    yellow "##"
    local line
    for line in "$@"; do
        yellow "##    $line"
    done
    yellow "##"
    yellow "##  Nothing to press: this is watching the database and carries on by itself."
    yellow "##"
    yellow "##############################################################################"
    echo ""

    if [ ! -r /dev/tty ]; then
        grey "  no terminal to ask, so this is being skipped"
        return 1
    fi

    local waited=0 found=""
    while true; do
        found=$(anysql "$query")
        if [ -n "$found" ]; then
            grey "  seen: $found"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
        [ $((waited % 30)) -eq 0 ] && yellow "  still waiting ($((waited))s) -- $title"
    done
}


# Asked once a run: is the TimeFlip here? Answers 0 for yes, 1 for anything else, and every script after
# the first gets that answer back without asking again.
#
#     device_required || { fail "no TimeFlip was made available"; finish; exit $?; }
#
# **Several scripts need the cube and one person is answering for all of them.** Asking each time treats
# them as separate questions when they are one, and the repetition is what makes it worse than useless: a
# prompt drawn this big is meant to stop somebody, and the third identical one in two minutes is the one
# they answer without reading. Nothing between them changed the answer.
#
# **This is the archive's shape, massaged.** `Archive/Tests/00-test-setup.md` established the device once
# for a whole run and every feature checklist after it simply assumed the result -- neither
# `02b-reset-device` nor `09b-device-rename` asks whether the cube is there. What does not carry over is
# how: that was a setup checklist of its own, driven by a Python supervisor holding state between steps.
# There is no supervisor here, so the gate lives where the need does and the first script to want the cube
# is the one that asks.
#
# **A no is remembered too**, which is half of it: declining because the cube is in another room should
# skip the device scripts, not ask again in thirty seconds whether it has come back. It is also what makes
# this safe to be the only prompt: one no covers the wipe as well, since the reset script asks nothing of
# its own and simply does not run.
#
# **Kept in a file, because each script is its own process.** run.sh runs them as `bash "$script"`, so a
# variable set in one is gone before the next starts and an export only ever travels downwards.
# `TESTLOG_RUN_ID` is the run's own identity and reaches every script -- exported by run.sh, or made by
# `testlog_script_start` for a script run on its own -- so a file naming the run it answered for is
# set-once-per-run with nothing to tidy up: the next run reads an id that is not its own and asks.
DEVICE_GATE="logs/device-gate"

device_required() {
    local run="${TESTLOG_RUN_ID:-}" answered="" remembered=""

    # **No identity, no memory.** Everything `testlog.sh` does is best-effort and may answer nothing at all, and
    # a run with no id must then ask rather than fall back to a shared one: two runs both calling themselves `0`
    # would have the second inherit the first's answer, about a cube that left the room hours ago.
    if [ -n "$run" ] && [ -r "$DEVICE_GATE" ]; then
        read -r answered remembered < "$DEVICE_GATE" || true
    fi
    if [ -n "$run" ] && [ "$answered" = "$run" ]; then
        case "$remembered" in
            yes) grey "  the TimeFlip was confirmed to be here earlier in this run"; return 0 ;;
            *)   grey "  no TimeFlip was made available earlier in this run"; return 1 ;;
        esac
    fi

    mkdir -p "$(dirname "$DEVICE_GATE")" 2>/dev/null || true

    # **Everything the run does to the cube, said once, because this is the only time it is asked.** That
    # includes the two things somebody agreeing to "is your device nearby" has plainly not agreed to on the
    # face of it: the PIN is changed, and the cube is wiped. Both are stated in full here rather than asked
    # about again later, so this prompt has to be worth reading -- it is the whole of the consent.
    if action_required \
        "May this run use your TimeFlip? It will be RESET to factory settings." \
        "THIS WIPES THE CUBE. 52-device-reset erases everything stored on the device --" \
        "face colours, task settings, its name and its PIN -- back to factory defaults," \
        "and that cannot be undone. The cube comes back on the vendor PIN 000000, which is" \
        "the first one Facet presents, so pairing it again afterwards is one press of Scan," \
        "but anything you had set on the device itself is gone." \
        "" \
        "The runs also change its PIN. They present 000000 and then the PIN this developer" \
        "build sets, 123456; a cube answering to the default is put on 123456, which is" \
        "written to config.json." \
        "" \
        "Then:" \
        "1. Flip the cube onto any face -- a sleeping cube does not advertise, so it cannot be found." \
        "2. Check Bluetooth is on." \
        "3. Press y and leave everything alone; the rest runs by itself." \
        "" \
        "Asked once for the whole run. Every script that needs the cube from here on takes" \
        "this answer, so leave it where it is until the run finishes." \
        "" \
        "The FIRST time Facet ever scans, macOS asks whether it may use Bluetooth. That" \
        "is once, not once per run or per build: after it is allowed the app just scans." \
        "If the prompt does appear, allow it -- until you do the radio never answers." \
        "" \
        "Answer anything else to skip every script that needs the cube, the reset included." \
        "The rest of the run is unaffected."; then
        [ -n "$run" ] && printf '%s yes\n' "$run" > "$DEVICE_GATE"
        return 0
    fi

    [ -n "$run" ] && printf '%s no\n' "$run" > "$DEVICE_GATE"
    return 1
}

# Pairs a cube from scratch, with the Device tab already on show. Answers 0 once the app says `Paired with`.
#
#     pair_a_cube || { pair_verdict "..."; finish; exit $?; }
#
# **Three scripts needed this and had two copies of it**, which is the point at which it stops being repetition and
# starts being a place for them to drift apart. `51-device-connect` keeps its own, deliberately: that one is the
# script whose subject *is* connecting, and every step of it is a check rather than a means to an end.
#
# **From scratch, forgetting first.** A paired app has no Scan button (`DevicePairingRules.showsScanControls`), so a
# script that inherited an earlier one's pairing would skip whenever that one skipped, and would silently test nothing
# after a reordering. The cost is one scan.
#
# **The caller decides what a failure means**, because it differs: an unusable radio is a skip in every script that
# calls this, and a cube that never answered is a failure in some and a skip in others. So this says what happened in
# the log and answers with which of the two it was:
#
#   0  paired
#   2  the radio cannot be used, which says nothing about the app -- `PAIR_REASON` holds the app's own words
#   1  everything else: nothing answered the scan, no row to press, or the PIN was refused
pair_a_cube() {
    PAIR_REASON=""
    PAIR_STATUS=0

    # **The Scan button has to be on screen, and this is checked rather than assumed.** `press` swallows everything --
    # its output, its exit code, and the case where the element is not in the tree at all -- so pressing a button that
    # is not there does nothing and says nothing. The wait below then times out after a full minute and reports the
    # radio as the culprit, which is a diagnosis pointing away from the fault: on 2026-08-22 `57-cube-pause` reached
    # here without ever having opened the Settings window, sat for 60 seconds, and skipped itself blaming a
    # permission prompt that was not there.
    if [ -z "$(element device-scan)" ] && [ -z "$(element device-forget)" ]; then
        PAIR_REASON="neither Scan nor Forget is on screen -- open the Settings window on the Device tab first"
        PAIR_STATUS=1
        return 1
    fi

    if [ -n "$(element device-forget)" ]; then
        grey "  already paired; forgetting first so this pairs its own cube"
        press device-forget
        sleep 1
    fi

    local since row
    since=$(mark)
    press device-scan
    sleep 0.5

    grey "  waiting for the radio to come up..."
    if ! wait_for "$since" "%Scan started%" 60 >/dev/null; then
        PAIR_REASON=$(dsql "SELECT message FROM debug_log WHERE debug_log_id > $since AND message LIKE 'Scan unavailable:%' ORDER BY debug_log_id DESC LIMIT 1;")
        [ -n "$PAIR_REASON" ] && { PAIR_STATUS=2; return 2; }
        PAIR_REASON="the radio never answered in 60s -- is the macOS Bluetooth permission prompt waiting?"
        PAIR_STATUS=1
        return 1
    fi

    grey "  listening for advertisements..."
    if ! wait_for "$since" "%: peripheral %" 13 >/dev/null; then
        # The scan is stopped on the way out: leaving the radio listening behind a script that has given up is what
        # the timeout exists to prevent, and this path is reached before it fires.
        press device-scan
        PAIR_REASON="the scan ran its full 10 seconds and no TimeFlip answered it -- is the cube awake?"
        PAIR_STATUS=1
        return 1
    fi

    row=$(tree | grep -m1 -o "device-scan-result-[0-9A-Fa-f-]*")
    if [ -z "$row" ]; then
        press device-scan
        PAIR_REASON="the app logged a device but drew no row to press"
        PAIR_STATUS=1
        return 1
    fi

    since=$(mark)
    press "$row"
    grey "  pairing..."
    if ! wait_for "$since" "Paired with %" 60 >/dev/null; then
        PAIR_REASON="the cube was found but would not pair -- it may be on a PIN this app cannot present"
        PAIR_STATUS=1
        return 1
    fi
    return 0
}

# Records what a failed `pair_a_cube` means, so the eight scripts that pair do not each decide it.
#
# **A cube that was promised and then would not pair is a failure, not a skip**, and that distinction is the whole of
# this. `device_required` has already confirmed a TimeFlip is here for this run, so from that point on "no cube could
# be paired" is the app failing to do the thing the script exists to check -- not the environment being unable to
# answer. Reported as a skip it read as green: on 2026-08-22 `55-device-face` tested nothing at all because a busy
# database dropped one write of `recordPairing`, and the run finished `outcome: passed`.
#
# Status 2 stays a skip, and that is the case worth keeping: the radio itself is off or refused, which says nothing
# about this app and is exactly the state an outside contributor without a device is in. See `CONTRIBUTING.md`.
pair_verdict() {
    if [ "${PAIR_STATUS:-1}" = "2" ]; then
        fail "the radio could not be used, so $1 ($PAIR_REASON)"
    else
        fail "a cube was confirmed for this run and then would not pair, so $1 ($PAIR_REASON)"
    fi
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
# **There is no `skip`, deliberately, and calling one is meant to be an error.** A skip is a check reporting that it
# could not answer, and a run full of them reads green while proving nothing: on 2026-08-22 `55-device-face` skipped
# its entire self and the run still stamped `outcome: passed`. So a missing cube, an unusable radio, an unconnected
# Google account and a prompt nobody answered are failures -- they say what is needed, and the run stays red until it
# is there. See `README.md`, under the order.
#
# The counter and its plumbing stay, in `finish`, the stamp and `scripts/check_interactive_checklists.sh`. They are
# now a guard rather than a feature: if anything ever manages to record a skip again, every one of them still refuses
# the run, and the number is where it will show.

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

# **Waits for a writer rather than failing at one.** The app's database is `journal_mode=delete`, so a
# write locks the file against readers outright -- and every check here reads `debug_log` at exactly the
# moment the app is busiest writing it. Without a timeout, sqlite gives up instantly: the read prints
# `Error: in prepare, database is locked (5)` to stderr, returns **empty on stdout**, and the check then
# fails against a haystack of `''` as though the row were missing.
#
# That is not hypothetical and it is not rare. On 2026-08-17 run 28 it failed
# `the accepted answer is 0x02` while the row it wanted was sitting in the table: the login writes
# sixteen rows in 440ms (the PIN rotation, then the Device Information reads), and the check lands in
# the middle of them. Ten seconds is far longer than any burst the app produces, so this waits rather
# than races, and a genuine empty result still means what it says.
sql() { sqlite3 -cmd ".timeout 10000" "$DB" "$1"; }

# The same, against the trace's database. **Every query naming `debug_log` goes through this**, and the split is worth
# saying plainly because it used to be one file: a `sql` call asking for `debug_log` now answers nothing at all rather
# than failing loudly, since sqlite reports "no such table" on stderr and an empty result on stdout -- which reads
# exactly like a row that has not been written yet.
#
# The timeout is the same 10 seconds and for a milder version of the same reason. The app writes this file constantly
# while a run polls it, but nothing else does, so the contention that made the app's own timeout necessary is largely
# what moving the table removed.
dsql() { sqlite3 -cmd ".timeout 10000" "$DEBUG_DB" "$1"; }

# Runs a query a *caller* supplied, against whichever database it is asking about.
#
# **For the three helpers that take a whole query rather than a pattern** -- `ask_and_detect`, `wait_sql` and
# `wait_for_value`. Every other call site names its table when it is written, so it can pick `sql` or `dsql` then;
# these cannot, because the table is in the argument. Deciding from the text keeps the caller writing one query and
# not also having to say where it lives.
#
# A query joining `debug_log` to an app table would be answered wrongly rather than refused, and there is no way to
# answer it at all -- they are separate files. There are none today (checked when the log moved out, 2026-08-22), and
# a check that needs both should wait for the row and then read the table, which is what `wait_sql` already exists to
# do.
anysql() {
    case "$1" in
        *debug_log*) dsql "$1" ;;
        *)           sql "$1" ;;
    esac
}

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
# **Answers 0 rather than nothing when the query cannot run at all**, which is not the same as the `IFNULL` above.
# That handles an empty table; this handles no table, no file, or a locked one -- sqlite3 prints its error to stderr
# and nothing to stdout, and an empty mark then goes straight into the next query as `debug_log_id > AND ...`. On
# 2026-08-22 that turned one missing table into forty "near AND: syntax error" lines and a run that measured every
# check from a baseline it never had.
mark() {
    local id
    id=$(dsql "SELECT IFNULL(MAX(debug_log_id), 0) FROM debug_log;")
    printf '%s' "${id:-0}"
}

# Waits for a debug_log row after `since` whose message matches `pattern` (a SQL LIKE, so % is the
# wildcard). Prints the message it found, empty on timeout.
#
# Polling the table rather than sleeping a fixed time: the app writes the row when the thing actually
# happened, so this is as fast as the app is and still correct on a slow machine.
wait_for() {
    local since="$1" pattern="$2" timeout="${3:-15}"
    # **An apostrophe in the pattern is doubled, because the pattern goes inside a SQL string literal.** `The cube's
    # clock is set` closes the quote at `cube` and the rest becomes syntax, so sqlite3 refuses the query, prints
    # nothing to stdout, and this polls an empty answer for its whole timeout before reporting that the app never
    # wrote a row it wrote immediately. Doubling is SQL's own escape and is what sqlite3 expects.
    #
    # Measured 2026-08-22: `57-cube-pause` failed on "no debug_log row matching 'Setting the cube's clock to %' within
    # 30s" with that exact row sitting in the table, 170ms after the mark. Three of its checks carried an apostrophe
    # and none of them could ever have matched. Escaped here rather than in each script, so the next pattern with one
    # in it simply works.
    #
    # **The error was never hidden, and that is the part worth remembering.** `sql` does not redirect stderr, so
    # `Error: in prepare, near "s": syntax error` went to the terminal and into `logs/screen.txt` -- three hundred
    # times, once per poll. What failed was not the diagnosis being unavailable but the verdict pointing away from it:
    # the FAIL line said the app had written no row. A loud signal beside a confident wrong summary is read as noise.
    pattern=${pattern//\'/\'\'}
    local waited=0 found=""
    while [ "$waited" -lt "$((timeout * 10))" ]; do
        found=$(dsql "SELECT message FROM debug_log WHERE debug_log_id > $since AND message LIKE '$pattern' ORDER BY debug_log_id LIMIT 1;")
        [ -n "$found" ] && { printf '%s' "$found"; return 0; }
        sleep 0.1
        waited=$((waited + 1))
    done
    return 1
}

# Waits for a query to answer `expected`, and answers whatever it last saw. Polled like `wait_for`, and
# for the same reason: the app writes when the thing actually happened, so this is as fast as the app is
# and still correct on a slow machine.
#
#     wait_sql "0" "SELECT COUNT(*) FROM device_event WHERE finalised = 0;"
#
# **For the state behind a log row, which does not land with it.** A debug_log row and the write it
# describes are two separate statements, and the app writes the row *first* in at least one place that
# matters: `DailyLimitWatch` records "Daily limit reached" and then calls `stopTiming()` to close the
# segment. A check that waits for the row and then reads the table once is racing that gap, and on
# 2026-08-17 run 29 it lost -- `the open segment was closed` wanted 0 and got 1, on the third of three
# identical iterations, having passed the first two.
#
# So: wait for a row to know a thing began, and wait on the table to know it finished.
wait_sql() {
    local expected="$1" query="$2" timeout="${3:-10}"
    local waited=0 answer=""
    while [ "$waited" -lt "$((timeout * 10))" ]; do
        answer=$(anysql "$query")
        [ "$answer" = "$expected" ] && { printf '%s' "$answer"; return 0; }
        sleep 0.1
        waited=$((waited + 1))
    done
    printf '%s' "$answer"
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
        [ "$(anysql "$query")" = "$want" ] && return 0
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
        # **Quoted, and passed as its own argument.** An identity reads
        # `Apple Development: apple@tux.com.au (32Q68X4KAP)` -- three words -- so building the flags into one
        # string and letting it word-split hands swift-bundler three arguments it has never heard of. It
        # went unnoticed because it only bites when a rebuild actually happens, which is the run after a
        # source file changes and no other. `scripts/run.sh` had it right; this had not.
        local identity output status
        identity="$(scripts/codesign-identity.sh)"
        if [ -n "$identity" ]; then
            output=$(mint run stackotter/swift-bundler@main bundle Facet --codesign --identity "$identity" 2>&1)
            status=$?
        else
            grey "  no codesigning identity, so this build is ad-hoc: anything reading the Keychain will stall"
            output=$(mint run stackotter/swift-bundler@main bundle Facet 2>&1)
            status=$?
        fi
        if [ "$status" -ne 0 ]; then
            red "  the build failed; running an old binary would prove nothing"
            # **Said out loud.** This used to be discarded, so a failed build reported only that it had
            # failed -- and the reason, which was one line long, had to be reproduced by hand.
            printf '%s\n' "$output" | tail -15 | sed 's/^/    /'
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
#
# **The app is brought to the front first.** A posted key event goes to whoever is frontmost, not to
# whoever the script last addressed -- every other helper here works through accessibility, which does not
# care about that, so this is the one place where being in front matters at all. Without it a Return can
# land in the terminal running the suite, and the symptom is a commit that produced no log row and no
# error: exactly the shape of a rename that silently did nothing on 2026-08-16.
press_return() {
    osascript -e 'tell application "Facet" to activate' >/dev/null 2>&1
    sleep 0.3
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

# Answers the sheet that is up, by the title of one of its buttons.
#
#     press_sheet "Reset Device"      # agrees
#     press_sheet Cancel              # declines
#
# **Scoped to the sheet, and that is not tidiness.** A confirmation names its agreeing button after the
# control that opened it, so `Reset Device` matches two elements -- the sheet's, and the one still behind
# it. `press` searches the whole tree, finds the one underneath first, and presses *that*: the sheet goes
# unanswered and a second one opens on top of it. Measured 2026-08-17, and it read as a reset that
# silently did nothing. See Tests/Methods.md Method 12.
press_sheet() { python3 scripts/ax-press.py --sheet --title "$1" >/dev/null 2>&1; }

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
