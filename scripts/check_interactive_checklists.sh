#!/usr/bin/env bash
# Fails if any Tests/Interactive/*-checklist.md file has an unchecked (- [ ]) item. See
# Tests/Interactive/README.md for the checklist convention this enforces.
set -euo pipefail

shopt -s nullglob
files=(Tests/Interactive/*-checklist.md)

if [ ${#files[@]} -eq 0 ]; then
  echo "No interactive test checklists found; skipping."
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
  echo "One or more interactive test checklists have unchecked items."
  echo "Complete the checklist(s) and commit the fully-ticked version before merging."
  exit 1
fi

echo "All interactive test checklists are fully checked."
