#!/usr/bin/env bash
# Fails if any Tests/Bench/*-checklist.md or Tests/Interactive/*-checklist.md file has an unchecked
# (- [ ]) item. Bench is reported first, then Interactive, mirroring the run order. See
# Tests/CLAUDE.md for the checklist convention this enforces.
set -euo pipefail

shopt -s nullglob
# Bench first, then Interactive -- the order the suites are meant to be run in.
files=(Tests/Bench/*-checklist.md Tests/Interactive/*-checklist.md)

if [ ${#files[@]} -eq 0 ]; then
  echo "No test checklists found; skipping."
  exit 0
fi

failed=0
for f in "${files[@]}"; do
  matches=$(grep -n '^\s*-\s*\[ \]' "$f" || true)
  if [ -n "$matches" ]; then
    echo "Unchecked items in $f:"
    echo "$matches"
    echo ""
    failed=1
  fi
done

if [ "$failed" -ne 0 ]; then
  echo "One or more test checklists have unchecked items."
  echo "Complete the checklist(s) and commit the fully-ticked version before merging."
  exit 1
fi

echo "All test checklists are fully checked."
