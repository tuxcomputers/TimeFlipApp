#!/usr/bin/env bash
# Checks the scripted suite is runnable, on a machine that cannot run it.
#
# **CI has no screen, no Keychain and no Google account**, so it cannot run `Tests/Scripted/run.sh` and
# must not pretend to. What it can do is make sure the suite is not broken in the ways that only show up
# when somebody tries: a script that will not parse, one that is not executable, one that never reports a
# verdict. All three are silent until the moment the suite is needed.
#
# **And that somebody actually ran them on this branch**, which is the other half and the one that makes
# the first half mean anything.
#
# The suite used to be Markdown checklists with tick boxes, and this script checked that none were left
# unticked and that each named the branch it was last run on. A tick survives in a file until somebody
# clears it, so a branch that changed behaviour and never re-ran inherited a full set of ticks recording
# somebody else's run -- the branch heading was what caught that.
#
# The scripted suite has no ticks to inherit, so for a while there was nothing to check and `--branch` was
# accepted and thrown away. `Tests/Scripted/last-run.md` is what gives it something to attach to again:
# `run.sh` writes it from the recorded run, and it names the branch, the commit, and whether anything
# failed.
#
# **It is stronger than the ticks were.** The old heading carried a date and a branch, so a run from
# before the last five commits looked exactly like one from after them. A commit hash makes that
# detectable: this checks that the run's commit is in the branch's history *and* that nothing under
# `Sources/`, `Tests/Scripted/` or `database/` has changed since. Editing a README does not force a re-run;
# changing the app does.
#
# **Only on a pull request.** `--branch` is empty on a push to main, and after a merge the stamp goes on
# naming the feature branch that ran it -- so enforcing the branch, ancestry and staleness checks there
# would fail every push for ever. What is still enforced on main is that a stamp exists and reports a run
# that passed.
set -euo pipefail

BRANCH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --branch) BRANCH="${2:-}"; shift 2 || shift ;;
    --branch=*) BRANCH="${1#--branch=}"; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# Overridable so this script can be exercised against a stamp that is not the real one. Nothing in CI
# sets it: writing a stamp by hand is the thing this exists to catch.
STAMP="${SCRIPTED_STAMP:-Tests/Scripted/last-run.md}"

# Reads one `    key:   value` line out of the stamp.
stamp_field() {
  sed -n "s/^ *$1: *//p" "$STAMP" | head -1
}

check_the_suite_was_run() {
  echo ""
  echo "Checking the suite was run on this branch:"

  if [ ! -f "$STAMP" ]; then
    echo "  no $STAMP"
    echo ""
    echo "Nothing records that these checks were ever run. Run Tests/Scripted/run.sh and commit the"
    echo "stamp it writes."
    return 1
  fi

  local ran_branch ran_commit tree outcome failed_checks problems=""
  ran_branch=$(stamp_field branch)
  ran_commit=$(stamp_field commit)
  tree=$(stamp_field tree)
  outcome=$(stamp_field outcome)
  # `checks:   248 passed, 0 failed, 3 skipped`
  failed_checks=$(sed -n 's/^ *checks: *[0-9]* passed, \([0-9]*\) failed.*/\1/p' "$STAMP" | head -1)

  echo "  ran on '$ran_branch' at ${ran_commit:0:12} -- $outcome, ${failed_checks:-?} check(s) failed"

  [ "$outcome" = "passed" ] || problems="$problems
  - the recorded run did not pass (outcome: ${outcome:-unknown})"
  [ "${failed_checks:-1}" = "0" ] || problems="$problems
  - the recorded run had ${failed_checks:-an unknown number of} failing check(s)"
  # A run against a dirty tree is not evidence about the commit it names.
  [ "$tree" = "clean" ] || problems="$problems
  - the working tree was $tree when it ran, so it is not evidence about that commit"

  if [ -z "$BRANCH" ]; then
    echo "  (no branch given, so the branch and staleness checks are skipped -- this is a push to main)"
  else
    [ "$ran_branch" = "$BRANCH" ] || problems="$problems
  - it was run on '$ran_branch', not on this pull request's '$BRANCH'"

    if [ -z "$ran_commit" ] || ! git cat-file -e "$ran_commit^{commit}" 2>/dev/null; then
      # A shallow checkout cannot see the commit. Worth saying rather than failing: it is a checkout
      # setting, not a testing problem, and the workflow asks for full history precisely for this.
      echo "  (commit ${ran_commit:0:12} is not in this checkout, so staleness cannot be checked --"
      echo "   the workflow needs actions/checkout with fetch-depth: 0)"
    else
      git merge-base --is-ancestor "$ran_commit" HEAD 2>/dev/null || problems="$problems
  - ${ran_commit:0:12} is not in this branch's history, so that run was of different code"

      # The stamp itself lives under Tests/Scripted and changes on every run, so it cannot count as a
      # change needing another run.
      if ! git diff --quiet "$ran_commit" HEAD -- Sources Tests/Scripted database ":!$STAMP" 2>/dev/null; then
        problems="$problems
  - the app or the checks have changed since that run:
$(git diff --name-only "$ran_commit" HEAD -- Sources Tests/Scripted database ":!$STAMP" 2>/dev/null | sed 's/^/      /' | head -20)"
      fi
    fi
  fi

  if [ -n "$problems" ]; then
    echo ""
    echo "The scripted suite has not been run on this branch as it stands:$problems"
    echo ""
    echo "Run Tests/Scripted/run.sh and commit the stamp it writes."
    return 1
  fi

  echo "  the suite was run on this branch, and passed"
  return 0
}

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

check_the_suite_was_run || exit 1
