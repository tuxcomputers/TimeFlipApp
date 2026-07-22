#!/bin/bash
# Runs device-test checklists without Claude in the loop. See scripts/testrunner/README.md.
#
# Usage:
#   scripts/testrunner/run_tests.sh Tests/Bench/04b-lock-and-pause-on-lock-checklist.md
#   scripts/testrunner/run_tests.sh Tests/Bench/04b-*.md Tests/Interactive/04i-*.md
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
