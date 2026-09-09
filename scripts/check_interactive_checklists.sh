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
# accepted and thrown away. `Tests/Scripted/last-run-mac.md` is what gives it something to attach to again:
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

# **One stamp per platform, because a run only says what works on the machine that made it.** The Mac
# writes `last-run-mac.md` and the Linux box will write `last-run-linux.md` beside it, and each is read
# by the same rules: right branch, commit in this history, nothing under `Sources/` changed since.
#
# **Only the Mac one can fail this script today**, and that is deliberate rather than an oversight. There
# is no Linux app to drive yet -- the UI is item 11 of `docs/linux-port.md` and the suite item 12 -- so a
# Linux stamp cannot exist, and demanding one would paint every branch red on a check nobody could clear.
# The Linux half is read and reported all the same, so the day it starts passing is visible before it is
# enforced. **`LINUX_IS_ADVISORY=0` is the whole of turning it on**, and it belongs in the same change
# that lands the first real Linux run.
#
# Both are overridable so this script can be exercised against stamps that are not the real ones. Nothing
# in CI sets either: writing a stamp by hand is the thing this exists to catch.
MAC_STAMP="${SCRIPTED_STAMP:-Tests/Scripted/last-run-mac.md}"
LINUX_STAMP="${SCRIPTED_STAMP_LINUX:-Tests/Scripted/last-run-linux.md}"
LINUX_IS_ADVISORY="${LINUX_IS_ADVISORY:-1}"

# Reads one `    key:   value` line out of the stamp named by `$STAMP`, which the caller sets.
stamp_field() {
  sed -n "s/^ *$1: *//p" "$STAMP" | head -1
}

# `$1` names the platform, `$2` is the stamp to read, `$3` is how many scripted checks exist on disk so
# the stamp can be asked whether it covered them. `$STAMP` is local to this call and is what
# `stamp_field` reads.
check_the_suite_was_run() {
  local platform="$1" STAMP="$2" on_disk="${3:-0}"
  echo ""
  echo "Checking the suite was run on this branch, on the $platform:"

  if [ ! -f "$STAMP" ]; then
    echo "  no $STAMP"
    echo ""
    echo "Nothing records that these checks were ever run on the $platform. Run Tests/Scripted/run.sh"
    echo "there and commit the stamp it writes."
    return 1
  fi

  local ran_branch ran_commit tree outcome failed_checks scripts_ran short_scripts ran_filter count_trouble problems=""
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


  # `scripts:  15 of 24 run, 0 with failures`. The second figure is how many the run listed, which since
  # `00-setup` began writing a row per script up front is every script there is; the first is how far it got.
  scripts_ran=$(sed -n 's/^ *scripts: *\([0-9]*\) of .*/\1/p' "$STAMP" | head -1)
  # `short:    0 ran fewer checks than they declare`. The figure the run decided its own outcome on, checked
  # here as well because a stamp is a file somebody can edit and the two have to agree.
  short_scripts=$(sed -n 's/^ *short: *\([0-9]*\) .*/\1/p' "$STAMP" | head -1)
  # `filter:   12-daily`, present only when the run was a partial one.
  ran_filter=$(stamp_field filter)

  echo "  ran on '$ran_branch' at ${ran_commit:0:12} -- $outcome, ${failed_checks:-?} failed, ${short_scripts:-?} short"
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
  # The table is `| script | expected | passed | failed | time |`, so the fields are $2, $3, $4, $5, $6 -- the
  # leading pipe makes $1 empty. Only the first three are read here, and `time` was added on the end for that
  # reason: a column appended to the right cannot move the ones this counts on. The `**` test drops the bold
  # totals row, and the header is skipped by name.
  #
  # **`[|]` rather than `\|`, and it is not a style choice.** macOS awk does not split on an escaped pipe in `FS`:
  # it splits on the runs of spaces around it instead and hands back the bar itself as a field, so `$3` comes out
  # as `|` and every row compares equal. The gate then passes everything, silently. A bracket expression is what
  # every awk agrees on. The skip gate this replaced had the same bug and nobody saw it, because it only ran when
  # a skip existed and none ever did.
  #
  # **Measured across three implementations on 2026-09-09**, once this check moved into `all-tests-pass` and so
  # onto Linux. On the same stamp row, `[|]` gives `NF=7` and the right fields everywhere; `\|` mis-splits under
  # **busybox awk** exactly as it does under macOS awk -- `NF=12`, `$3` coming back as `|` -- and happens to be
  # harmless under **mawk**, which is what Debian and Ubuntu point `awk` at. So the bug reproduces in a second
  # implementation and the fix is load-bearing rather than a macOS quirk, and mawk being forgiving is luck rather
  # than a reason to relax it.
  #
  # Both parser functions below were then driven against a doctored stamp under mawk and both bit: a row edited
  # from `9 | 9` to `9 | 8` was reported as declaring 9 and running 8, and one edited to `0 | 0` was reported as
  # declaring no checks at all, with the real stamp reporting neither. **What is still unestablished is the awk on
  # the GitHub runner**, which is where this now actually runs; `gawk` is not installed on the Linux box, so that
  # dialect is reasoned about rather than tested.
  #
  # Per script rather than as one number: "the run is 3 checks short" sends somebody to the table anyway, and the
  # table is what says which script and by how much.
  count_trouble=$(awk -F' *[|] *' '
      /^\| / && $2 !~ /\*\*/ && $2 != "script" && $3 + 0 != $4 + 0 {
          printf "\n      %s: declares %s check(s), ran %s", $2, $3, $4
      }' "$STAMP")
  [ -z "$count_trouble" ] || problems="$problems
  - a script did not run the number of checks it declares, so some never ran at all:$count_trouble"

  # **The run's own count of the same thing, and it has to agree with the table.** `run.sh` decides `outcome`
  # from this figure, so a stamp claiming `passed` with a non-zero `short` is one where the two halves disagree
  # -- which means it was edited, since nothing writes that combination.
  [ "${short_scripts:-1}" = "0" ] || problems="$problems
  - the run recorded ${short_scripts:-an unknown number of} script(s) short of their declared checks"

  # **Zero declared is refused here too**, not only on disk above. The two look at different things: that loop
  # reads the scripts in this checkout, and this reads what the run actually recorded, which may name a script
  # that has since been renamed or deleted. A row of `0 | 0` passes the comparison above by arithmetic while
  # meaning the script tested nothing at all, so it is called out rather than left to add up.
  zero_declared=$(awk -F' *[|] *' '
      /^\| / && $2 !~ /\*\*/ && $2 != "script" && $3 + 0 == 0 {
          printf "\n      %s", $2
      }' "$STAMP")
  [ -z "$zero_declared" ] || problems="$problems
  - a script declares no checks at all, so nothing it did was measured against anything:$zero_declared"
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
      #
      # **`Package.swift` is watched because the manifest decides what gets built**, so a commit that changes
      # only it alters the app while leaving every watched source untouched -- a target's file list, an
      # exclusion, a dependency, or the whole `#if os(Linux)` graph. That is the same class of change the rest
      # of this list exists to catch, arriving by a path it would otherwise not look at. It is watched whole
      # rather than only outside the `os(Linux)` branch: a pathspec is textual and cannot tell the branches
      # apart, and a gate that has to parse what it guards is one that fails open when the parsing is wrong.
      # The cost is a manifest edit that cannot affect macOS at all still asking for a run with the cube.
      watched=(Sources Tests/Scripted database Package.swift ":!$STAMP" ":!Tests/Scripted/*.md")
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

for f in Tests/Scripted/platform.sh Tests/Scripted/lib.sh Tests/Scripted/run.sh "${scripts[@]}"; do
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
      # **A number, and not zero.** The stamp gate below compares what a script declares against what it ran,
      # and both being zero compares equal -- so a script with no declaration that runs nothing is the one
      # shape that satisfies every other check here while testing absolutely nothing. Requiring the
      # declaration on disk closes that at the source, before a stamp is read at all.
      grep -qE '^EXPECTED_CHECKS=[1-9][0-9]*$' "$f" || problems="$problems no-expected-checks"
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

# **The Mac decides the exit status; the Linux half only speaks.** See the LINUX_IS_ADVISORY comment at
# the top for why, and for the one variable that changes it.
gate=0
check_the_suite_was_run "Mac" "$MAC_STAMP" "${#scripts[@]}" || gate=1

if check_the_suite_was_run "Linux box" "$LINUX_STAMP" "${#scripts[@]}"; then
  :
elif [ "$LINUX_IS_ADVISORY" = "1" ]; then
  echo ""
  echo "  ^ reported, not enforced. There is no Linux app to drive yet (linux-port.md items 11 and 12),"
  echo "    so this cannot be cleared. Set LINUX_IS_ADVISORY=0 in this script once it can."
else
  gate=1
fi

exit "$gate"
