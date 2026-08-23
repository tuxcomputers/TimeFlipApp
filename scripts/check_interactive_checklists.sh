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
# **Every check a script says it has must have run.** This replaced the skip gate, which guarded the same thing
# by a route the suite no longer takes: nothing has produced a skip since the helpers stopped offering one, so
# `0 skipped` appeared on every run of every branch and the stamp no longer carries the line.
#
# What took its place catches the silent version. Each script declares `EXPECTED_CHECKS`, the number of checks it
# runs when everything passes, and the stamp records that beside what actually ran. A script that takes a branch
# nobody meant it to take -- an early exit, a conditional that skips a section, a helper that returns before its
# checks -- runs fewer, and reports nothing at all about the ones that never happened: every check that did run
# passed, the run says `passed`, and the totals add up. The two columns disagreeing is the only trace of it.
#
# **It is stronger than the ticks were.** The old heading carried a date and a branch, so a run from
# before the last five commits looked exactly like one from after them. A commit hash makes that
# detectable: this checks that the run's commit is in the branch's history *and* that nothing under
# `Sources/`, `Tests/Scripted/` or `database/` has changed since. Editing a README does not force a re-run;
# changing the app does.
#
# **A contributor with no device cannot clear this, and is not meant to.** The suite needs a cube in range
# and a person to turn it, so a fork's pull request will land here red however good the change is. That is
# the honest state of it rather than a gate to route around: the change genuinely has not been checked
# against hardware. What clears it is somebody who has a device running the suite against that branch and
# committing the stamp -- so the message says so, because a red check whose advice you cannot follow reads
# as a dead end rather than as a step somebody else takes.
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

# `$1` is how many scripted checks exist on disk, so the stamp can be asked whether it covered them.
check_the_suite_was_run() {
  local on_disk="${1:-0}"
  echo ""
  echo "Checking the suite was run on this branch:"

  if [ ! -f "$STAMP" ]; then
    echo "  no $STAMP"
    echo ""
    echo "Nothing records that these checks were ever run. Run Tests/Scripted/run.sh and commit the"
    echo "stamp it writes."
    return 1
  fi

  local ran_branch ran_commit tree outcome failed_checks scripts_ran ran_filter count_trouble problems=""
  ran_branch=$(stamp_field branch)
  ran_commit=$(stamp_field commit)
  tree=$(stamp_field tree)
  outcome=$(stamp_field outcome)
  # `checks:` opens a block, and the count comes off its `failed` line:
  #
  #     checks:   264 in total
  #               263 passed
  #                 0 failed
  #
  # **It was one line until 2026-08-16** (`checks: 248 passed, 0 failed, 3 skipped`) and this parser
  # was not changed with it, so it silently matched nothing: `failed_checks` came back empty, which
  # reads as "an unknown number" and fails the branch however well the run went. Failing closed was
  # right, but it would have rejected a clean run 16 and sent somebody looking in the wrong place.
  # Anchored to the `checks:` line so a stray `N failed` anywhere else in the file cannot answer for it.
  failed_checks=$(awk '/^ *checks:/ { inblock = 1 }
                       inblock && /^ *[0-9]+ failed *$/ { print $1; exit }' "$STAMP")


  # `scripts:  15 run, 0 with failures`
  scripts_ran=$(sed -n 's/^ *scripts: *\([0-9]*\) run.*/\1/p' "$STAMP" | head -1)
  # `filter:   12-daily`, present only when the run was a partial one.
  ran_filter=$(stamp_field filter)

  echo "  ran on '$ran_branch' at ${ran_commit:0:12} -- $outcome, ${failed_checks:-?} failed"
  echo "  it ran ${scripts_ran:-?} of the $on_disk scripted check(s) here"

  # **Every script, not merely a passing run.** Nothing compared these until 2026-08-16, and the gap was real:
  # `run.sh --filter` runs a subset and writes a stamp that looks exactly like a full run -- passed, nothing failed,
  # clean tree, right branch, right commit -- so one script could stand as evidence for the suite. The only other
  # thing that catches a script going unrun is the staleness check below, and it only does so by accident: adding a
  # file changes `Tests/Scripted/`, which forces a re-run. It would not notice an existing script being skipped.
  if [ -z "$scripts_ran" ]; then
    problems="$problems
  - the stamp does not say how many scripts ran"
  elif [ "$scripts_ran" -lt "$on_disk" ]; then
    problems="$problems
  - it ran $scripts_ran of the $on_disk scripted check(s) here, so some were never run${ran_filter:+ (filter: $ran_filter)}"
  fi

  [ "$outcome" = "passed" ] || problems="$problems
  - the recorded run did not pass (outcome: ${outcome:-unknown})"
  [ "${failed_checks:-1}" = "0" ] || problems="$problems
  - the recorded run had ${failed_checks:-an unknown number of} failing check(s)"
  # **Every check a script says it has must have run**, read off the per-script table.
  #
  # The table is `| script | expected | passed | failed |`, so the fields are $2, $3, $4, $5 -- the leading pipe
  # makes $1 empty. The `**` test drops the bold totals row, and the header is skipped by name.
  #
  # **`[|]` rather than `\|`, and it is not a style choice.** macOS awk does not split on an escaped pipe in `FS`:
  # it splits on the runs of spaces around it instead and hands back the bar itself as a field, so `$3` comes out
  # as `|` and every row compares equal. The gate then passes everything, silently. A bracket expression is what
  # both awks agree on. The skip gate this replaced had the same bug and nobody saw it, because it only ran when
  # a skip existed and none ever did.
  #
  # Per script rather than as one number: "the run is 3 checks short" sends somebody to the table anyway, and the
  # table is what says which script and by how much.
  count_trouble=$(awk -F' *[|] *' '
      /^\| / && $2 !~ /\*\*/ && $2 != "script" && $3 + 0 != $4 + 0 {
          printf "\n      %s: declares %s check(s), ran %s", $2, $3, $4
      }' "$STAMP")
  [ -z "$count_trouble" ] || problems="$problems
  - a script did not run the number of checks it declares, so some never ran at all:$count_trouble"
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

      # **Prose under Tests/Scripted does not count as a change needing another run**, and two files there are
      # prose. The stamp is one, and it changes on every run by definition. `README.md` is the other: no check
      # reads a Markdown file -- every `.md` in the scripts is a citation inside a comment -- so a paragraph
      # cannot alter what a check does, and demanding twenty minutes with a cube to correct a sentence is how a
      # gate teaches people to work around it. This is what the section above means by "editing a README does
      # not force a re-run"; that was true of every README except the one describing this suite, until now.
      # `$STAMP` stays named separately because `SCRIPTED_STAMP` can point it somewhere else for testing.
      watched=(Sources Tests/Scripted database ":!$STAMP" ":!Tests/Scripted/*.md")
      if ! git diff --quiet "$ran_commit" HEAD -- "${watched[@]}" 2>/dev/null; then
        problems="$problems
  - the app or the checks have changed since that run:
$(git diff --name-only "$ran_commit" HEAD -- "${watched[@]}" 2>/dev/null | sed 's/^/      /' | head -20)"
      fi
    fi
  fi

  if [ -n "$problems" ]; then
    echo ""
    echo "The scripted suite has not been run on this branch as it stands:$problems"
    echo ""
    echo "Run Tests/Scripted/run.sh and commit the stamp it writes."
    echo ""
    echo "If you do not have a TimeFlip, you cannot clear this and are not expected to."
    echo "Open the pull request anyway and say so in it: somebody with a device in range runs the"
    echo "suite against your branch and commits the stamp, and this goes green. See CONTRIBUTING.md."
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

check_the_suite_was_run "${#scripts[@]}" || exit 1
