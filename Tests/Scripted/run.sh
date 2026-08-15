#!/bin/bash
# Runs the scripted checks, in order, and writes everything to logs/screen.txt as well as the terminal.
#
#   Tests/Scripted/run.sh                  everything, in order
#   Tests/Scripted/run.sh 04               just the scripts whose name contains "04"
#   Tests/Scripted/run.sh categories       substring matching works on the name too
#   Tests/Scripted/run.sh --keep-running   leave the app up at the end (for looking at what failed)
#
# **The order matters.** Each script leaves the app in a state the next one can start from, and the
# early ones check the things the later ones depend on -- there is no point testing the Report tab's
# totals if recording a time entry is broken, and the failure would be reported in the wrong place.
# So a failing script stops the run.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

mkdir -p logs
# Everything this run prints goes to logs/screen.txt as well, freshly overwritten each time, so there
# is one file to read afterwards (or to watch with `tail -f` while it runs).
exec > >(tee logs/screen.txt) 2>&1

KEEP_RUNNING=0
FILTER=""
for arg in "$@"; do
    case "$arg" in
        --keep-running) KEEP_RUNNING=1 ;;
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
echo "${#scripts[@]} script(s) to run"

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

[ -z "$failed" ]
