#!/bin/bash
# Runs the scripted checks, in order, and writes everything to logs/screen.txt as well as the terminal.
#
#   Tests/Scripted/run.sh                  everything, in order, against a brand new test database
#   Tests/Scripted/run.sh --keep           against the test database as it stands, rows and all
#   Tests/Scripted/run.sh 04               just the scripts whose name contains "04"
#   Tests/Scripted/run.sh categories       substring matching works on the name too
#   Tests/Scripted/run.sh --keep-running   leave the app up at the end (for looking at what failed)
#
# **A clean database by default.** These scripts create categories and time entries and delete nothing,
# so run after run the test database fills with them and every list gets longer. Starting from the DDL
# each time means a run says what the app does from nothing, rather than what it does on top of whatever
# the last fortnight left -- and a check that only passes because of a row an earlier run happened to
# make is a check that will fail for somebody else.
#
# `--keep` is for the opposite need: looking at what a failed run left, or keeping a Google account
# connected between runs. **A clean database has no Google account in it**, so 10-google-calendar skips
# unless you sign in again or pass `--keep`. The refresh token is in the Keychain and survives, but the
# account the app reads is in the database and does not.
#
# **The order matters.** Each script leaves the app in a state the next one can start from, and the
# early ones check the things the later ones depend on -- there is no point testing the Report tab's
# totals if recording a time entry is broken, and the failure would be reported in the wrong place.
# So a failing script stops the run.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

mkdir -p logs
# Everything this run prints goes to logs/screen.txt as well, freshly overwritten each time, so there is
# one file to read afterwards (or to watch with `tail -f` while it runs).
#
# **Colour on the terminal, plain text in the file.** The colours are escape sequences, and a file full of
# them opens in an editor as `ESC[0;32m    PASS` -- the thing the colour was meant to make readable, made
# worse. So the copy going to the file has them stripped on the way through, live, rather than the file
# being cleaned up at the end: the point of it is being watchable while a run happens, and a run that is
# interrupted is exactly when somebody wants to read it.
#
# perl rather than sed because it is what portably understands `\e`; both ship with macOS.
exec > >(tee >(perl -pe 's/\e\[[0-9;]*m//g' > logs/screen.txt)) 2>&1

KEEP_RUNNING=0
KEEP_DATABASE=0
FILTER=""
for arg in "$@"; do
    case "$arg" in
        --keep-running) KEEP_RUNNING=1 ;;
        --keep) KEEP_DATABASE=1 ;;
        *) FILTER="$arg" ;;
    esac
done

scripts=()
for script in Tests/Scripted/[0-9][0-9]-*.sh; do
    [ -e "$script" ] || continue
    if [ -n "$FILTER" ]; then
        case "$script" in *"$FILTER"*) ;; *) continue ;; esac
    fi
    scripts+=("$script")
done

if [ ${#scripts[@]} -eq 0 ]; then
    echo "No scripts matched${FILTER:+ '$FILTER'}."
    exit 2
fi

echo "Facet scripted checks -- $(date '+%Y-%m-%d %H:%M:%S')"
echo "$(git rev-parse --abbrev-ref HEAD) at $(git rev-parse --short HEAD)"

# The app holds the database open, so it goes first whichever way this run is going: rebuilding under a
# running app would leave it writing to a file nothing points at any more.
if pgrep -x Facet >/dev/null; then
    echo "Quitting the running app first."
    python3 scripts/status-item-click.py >/dev/null 2>&1
    sleep 0.5
    python3 scripts/ax-press.py quit-app >/dev/null 2>&1
    sleep 1.5
    pgrep -x Facet >/dev/null && pkill -x Facet
    sleep 0.5
fi

if [ "$KEEP_DATABASE" -eq 1 ]; then
    echo "Keeping the test database as it stands (--keep)."
else
    # **Before the rebuild, because afterwards there is nothing left to read.** A Google account is
    # connected once, by hand, through a browser; losing it to every clean run would mean either doing
    # that again each time or leaving the sync untested. 00-setup puts it back once the new database
    # exists. Silent when there is nothing to capture, which is the normal case.
    Tests/Scripted/00-setup.sh --capture || true

    echo "Rebuilding test.sqlite from the DDL, so this run starts from nothing."
    if ! scripts/switch-database.sh test -clean; then
        echo "Could not rebuild the test database; refusing to run against whatever is there instead."
        exit 2
    fi
    if [ ! -f "$HOME/.config/facet/scripted-seed.json" ]; then
        echo "Note: a new database has no Google account, so 10-google-calendar will skip."
        echo "      Connect one on the App tab once; it is captured and reseeded from then on."
    fi
fi

echo "${#scripts[@]} script(s) to run"

# The durable record, alongside screen.txt. See Tests/Scripted/testlog.sh for what it holds and why one
# overwritten text file is not enough to work out why something failed.
DB="$HOME/Library/Application Support/Facet/appdata.sqlite"
source Tests/Scripted/testlog.sh
TESTLOG_RUN_ID=$(testlog_run_start "$((1 - KEEP_DATABASE))" "$FILTER" "run.sh $*")
export TESTLOG_RUN_ID
echo "Recording this run as run_id $TESTLOG_RUN_ID in logs/testlog.sqlite"

ran=0
failed=""
for script in "${scripts[@]}"; do
    if bash "$script"; then
        ran=$((ran + 1))
    else
        failed="$script"
        break
    fi
done

testlog_run_finish "$TESTLOG_RUN_ID" "$([ -z "$failed" ] && echo passed || echo failed)" "$ran"

# The committed half of the record. Written either way, because a stamp that only appeared on success
# would let a failing branch keep an older passing one -- which is the staleness it exists to catch.
testlog_stamp "$TESTLOG_RUN_ID" "Tests/Scripted/last-run.md"

echo ""
echo "=============================================================================="
if [ -n "$failed" ]; then
    printf '\033[0;31m%s\033[0m\n' "STOPPED at $failed after $ran script(s) passed."
    echo "The rest were not run: each one starts from the state the last one left."
else
    printf '\033[0;32m%s\033[0m\n' "ALL $ran SCRIPT(S) PASSED."
fi
echo "This output is also in logs/screen.txt"
echo "=============================================================================="

if [ "$KEEP_RUNNING" -eq 0 ]; then
    # Left running only when asked, so a failed run can be looked at. Otherwise the app goes away:
    # a status item left behind is a second instance's worth of confusion next time.
    pgrep -x Facet >/dev/null && {
        python3 scripts/status-item-click.py >/dev/null 2>&1
        sleep 0.5
        python3 scripts/ax-press.py quit-app >/dev/null 2>&1
        sleep 1
        pgrep -x Facet >/dev/null && pkill -x Facet
    }
fi

# The plain-text copy is written by a process of its own, so give it a moment to drain before this shell
# exits and the pipe goes with it. Without this the last few lines can be missing from the file -- and
# the last few lines are the summary.
sleep 0.5

[ -z "$failed" ]
