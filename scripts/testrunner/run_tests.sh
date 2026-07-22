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

if ! python3 -c "import Quartz" >/dev/null 2>&1; then
  echo "error: python3's Quartz module (pyobjc) is required for cgevent_click steps." >&2
  echo "Install with: pip3 install pyobjc-framework-Quartz" >&2
  exit 1
fi

python3 "$SCRIPT_DIR/supervisor.py" "$@"
