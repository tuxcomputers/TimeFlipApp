#!/bin/bash
# Runs device-test checklists without Claude in the loop. See scripts/testrunner/README.md.
#
# Usage:
#   scripts/testrunner/run_tests.sh                          # everything: Bench sorted, then Interactive sorted
#   scripts/testrunner/run_tests.sh -f Bench                 # only that folder, sorted
#   scripts/testrunner/run_tests.sh -s 01                    # both folders, filenames containing "01" (01b then 01i)
#   scripts/testrunner/run_tests.sh -s reset                 # substring match works by name too
#   scripts/testrunner/run_tests.sh -f Bench -s reset         # combine both
#   scripts/testrunner/run_tests.sh Tests/Bench/04b-lock-and-pause-on-lock-checklist.md   # explicit paths, exact order
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# Mirror everything this run prints to the terminal into logs/screen.txt as well -- the raw stream
# (build output, prompts, ACTION NEEDED nudges, the supervisor's own output), freshly overwritten
# each run. Complements the timestamped structured transcript the supervisor writes separately.
# `tee` truncates the file, so it always holds just the latest run. (supervisor runs with `-u`
# below so this streams live rather than block-buffering into the pipe.)
mkdir -p logs
exec > >(tee logs/screen.txt) 2>&1

if ! python3 -c "import Quartz" >/dev/null 2>&1; then
  echo "error: python3's Quartz module (pyobjc) is required for cgevent_click steps." >&2
  echo "Install with: pip3 install pyobjc-framework-Quartz" >&2
  exit 1
fi

# Always rebuild the app before running so the checklists never execute against a stale binary.
# (A day-old build once passed a feature but lacked a newly-added debug-log marker a step waited
# on, failing a check whose behaviour actually worked.) `bundle` builds the .app without launching
# it -- the runner launches it itself later. It's incremental, so near-instant when nothing
# changed. Built via mint (matching scripts/run.sh) since swift-bundler isn't assumed on PATH.
# Abort the whole run if the build fails: running an old binary is worse than not running.
APP_BINARY=".build/bundler/apps/TimeFlip/TimeFlip.app/Contents/MacOS/TimeFlip"
echo "Rebuilding the app (swift-bundler bundle TimeFlip) so the run uses a current binary..."
if ! mint run stackotter/swift-bundler@main bundle TimeFlip; then
  echo "error: app build failed -- fix the build before running the device tests." >&2
  exit 1
fi
if [ ! -x "$APP_BINARY" ]; then
  echo "error: build succeeded but $APP_BINARY is missing -- check the bundle output path." >&2
  exit 1
fi
echo "Built binary the run will launch:"
ls -l "$APP_BINARY" | awk '{print "  "$5" bytes, built "$6" "$7" "$8"  ->  '"$APP_BINARY"'"}'

python3 -u "$SCRIPT_DIR/supervisor.py" "$@"
