#!/usr/bin/env bash
# Checks the two things that make a checklist's ticks mean something, over every
# Tests/Bench/*-checklist.md and Tests/Interactive/*-checklist.md. Bench is reported first, then
# Interactive, mirroring the run order. See Tests/CLAUDE.md for the conventions this enforces.
#
#   1. No unchecked (`- [ ]`) item is left anywhere.
#   2. With `--branch <name>`: every file's `### Last run` heading names <name>.
#
# The second exists because the first can be satisfied without running anything: a tick survives in
# the file until someone clears it, so a branch that changes behaviour and never re-runs the suite
# inherits a full set of ticks recording a *previous* branch's run. The Last run heading is the only
# thing that says which branch the evidence belongs to, so requiring it to name this one is what
# stops the tick check from passing on stale evidence.
#
# `--branch` with an empty value skips check 2 entirely, which is what a push to main wants: the
# heading names the feature branch that ran the suite, and it goes on saying so after the merge.
set -euo pipefail

BRANCH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --branch) BRANCH="${2-}"; shift 2 ;;
    --branch=*) BRANCH="${1#*=}"; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

shopt -s nullglob
# Bench first, then Interactive -- the order the suites are meant to be run in.
files=(Tests/Bench/*-checklist.md Tests/Interactive/*-checklist.md)

if [ ${#files[@]} -eq 0 ]; then
  echo "No test checklists found; skipping."
  exit 0
fi

unchecked_failed=0
for f in "${files[@]}"; do
  matches=$(grep -n '^\s*-\s*\[ \]' "$f" || true)
  if [ -n "$matches" ]; then
    echo "Unchecked items in $f:"
    echo "$matches"
    echo ""
    unchecked_failed=1
  fi
done

if [ "$unchecked_failed" -ne 0 ]; then
  echo "One or more test checklists have unchecked items."
  echo "Complete the checklist(s) and commit the fully-ticked version before merging."
  echo ""
else
  echo "All test checklists are fully checked."
fi

branch_failed=0
if [ -n "$BRANCH" ]; then
  echo ""
  echo "Checking every checklist was last run on '$BRANCH':"
  for f in "${files[@]}"; do
    # Only the top of the file, matching where checklist_header.py both looks for the heading and
    # inserts it -- so the two agree on what counts as having one.
    heading=$(head -12 "$f" | grep -m1 -E "^### Last run - " || true)
    if [ -z "$heading" ]; then
      echo "  $f: no 'Last run' heading -- never run"
      branch_failed=1
      continue
    fi
    recorded=$(printf '%s\n' "$heading" \
      | sed -E "s/^### Last run - .* on the branch '(.*)'[[:space:]]*$/\1/")
    if [ "$recorded" = "$heading" ]; then
      echo "  $f: malformed 'Last run' heading: $heading"
      branch_failed=1
    elif [ "$recorded" != "$BRANCH" ]; then
      echo "  $f: last run on '$recorded'"
      branch_failed=1
    fi
  done

  if [ "$branch_failed" -ne 0 ]; then
    echo ""
    echo "One or more test checklists were last run on another branch (or never)."
    echo "Their ticks are a previous branch's evidence, not this one's: run them on '$BRANCH'"
    echo "and commit the updated headings before merging."
  else
    echo "  all clear -- every checklist was last run on '$BRANCH'."
  fi
fi

if [ "$unchecked_failed" -ne 0 ] || [ "$branch_failed" -ne 0 ]; then
  exit 1
fi
