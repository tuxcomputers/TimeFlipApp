#!/usr/bin/env bash
# Checks the scripted suite is runnable, on a machine that cannot run it.
#
# **CI has no screen, no Keychain and no Google account**, so it cannot run `Tests/Scripted/run.sh` and
# must not pretend to. What it can do is make sure the suite is not broken in the ways that only show up
# when somebody tries: a script that will not parse, one that is not executable, one that never reports a
# verdict. All three are silent until the moment the suite is needed.
#
# What this replaced, and why. The suite used to be Markdown checklists with tick boxes, and this script
# checked that none were left unticked and that each named the branch it was last run on -- because a tick
# survives in a file until somebody clears it, so a branch that changed behaviour and never re-ran
# inherited a full set of ticks recording somebody else's run. The scripted suite has no ticks to inherit:
# it either runs and passes or it does not, and the evidence is the run itself (`logs/screen.txt`) rather
# than a file in the repository. So the staleness check has nothing to attach to, and `--branch` is
# accepted and ignored rather than removed, since the workflows pass it.
set -euo pipefail

while [ $# -gt 0 ]; do
  case "$1" in
    --branch) shift 2 || shift ;;
    --branch=*) shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

shopt -s nullglob
scripts=(Tests/Scripted/[0-9][0-9]-*.sh)

if [ ${#scripts[@]} -eq 0 ]; then
  echo "No scripted checks found; skipping."
  exit 0
fi

echo "Checking ${#scripts[@]} scripted check(s) are runnable:"
failed=0

for f in Tests/Scripted/lib.sh Tests/Scripted/run.sh "${scripts[@]}"; do
  problems=""

  # A syntax error is invisible until the script is reached, which on a suite that stops at the first
  # failure can be several minutes in.
  bash -n "$f" 2>/dev/null || problems="$problems does-not-parse"

  # run.sh invokes each one with `bash`, so this is about somebody running one on its own.
  [ -x "$f" ] || problems="$problems not-executable"

  case "$f" in
    Tests/Scripted/[0-9][0-9]-*.sh)
      # Without `finish` a script cannot fail: it ends on the exit status of whatever ran last, so a
      # failed check would be reported and the suite would carry on regardless.
      grep -q '^finish$' "$f" || problems="$problems no-finish"
      # Without this it would happily write to whichever database the app is pointed at, and these
      # scripts create categories and time entries that nothing undoes.
      grep -q 'require_test_database' "$f" || problems="$problems no-database-guard"
      ;;
  esac

  if [ -n "$problems" ]; then
    echo "  $f:$problems"
    failed=1
  else
    echo "  $f ok"
  fi
done

if [ "$failed" -ne 0 ]; then
  echo ""
  echo "One or more scripted checks are not runnable. See Tests/Scripted/README.md."
  exit 1
fi

echo ""
echo "All scripted checks are runnable."
echo "CI cannot run them: they drive a real window and read a real database."
echo "Run Tests/Scripted/run.sh before merging, and keep logs/screen.txt from that run."
