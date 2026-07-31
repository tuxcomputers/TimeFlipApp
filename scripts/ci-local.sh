#!/usr/bin/env bash
# Run what .github/workflows/tests.yml runs, locally, before opening a PR.
#
# Why this exists: the workflow only fires on push to main or on a pull_request, so a branch with
# no PR gets no CI at all -- the first signal arrives when the PR is opened, which is the worst
# moment to discover a red build.
#
# Why not a container, and why not `act`:
#
# `runs-on: macos-15` is a **virtual machine**, not a container -- macOS cannot run in Docker at
# all, so there is nothing to containerise for the two jobs that actually build and test. The only
# containerisable job is `all-tests-pass` (`ubuntu-latest`), and that is a pure bash aggregator
# reading `needs.*.result`; running it locally would prove nothing about the code. `act` therefore
# has nothing useful to offer here.
#
# The closest true emulation would be a macOS 15 VM (Tart on Apple Silicon) with CI's exact Xcode,
# which is tens of gigabytes and hours of setup. The gap that buys you is reported below instead:
# the script prints the local toolchain against the one CI last used, so a divergence is visible
# rather than assumed away. That is the only difference these steps can't reproduce natively.
#
# By default this runs only the branch tip, matching the workflow's `test-branch-as-is` job --
# the fast answer to "would CI be green on what I have right now".
#
# `--with-merge` adds the workflow's other job, `test-merge-result`, which checks out this branch
# *merged into its base*. That one catches breakage appearing only once the branch meets whatever
# has landed on the base since it was cut. It is off by default because it costs a second full
# build and only tells you something new when the base has actually moved.
#
# The merge, when asked for, happens in a throwaway git worktree, so the working tree, index and
# HEAD are untouched and the script is safe to run with uncommitted changes present.

set -uo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

BASE_BRANCH="${CI_LOCAL_BASE:-main}"
RUN_BRANCH=1
# Off by default: the branch tip is the question being asked most of the time, and the merge job
# costs a second full build.
RUN_MERGE=0
DO_FETCH=1

usage() {
    cat <<'USAGE'
usage: ci-local.sh [--with-merge | --merge-only] [--no-fetch]

  (default)      Just the branch tip, matching CI's "test-branch-as-is" job.
  --with-merge   Also run CI's "test-merge-result" job: this branch merged into
                 its base, in a throwaway worktree. Worth it before opening a PR,
                 or whenever the base has moved.
  --merge-only   Only the merged-into-base job.
  --no-fetch     Don't `git fetch` first. Faster, but the merge preview is then
                 against a possibly stale base and can pass when real CI fails.

  CI_LOCAL_BASE  Base branch to merge against (default: main).
USAGE
}

for arg in "$@"; do
    case "$arg" in
        --with-merge)  RUN_MERGE=1 ;;
        --merge-only)  RUN_BRANCH=0; RUN_MERGE=1 ;;
        --branch-only) RUN_MERGE=0 ;;  # now the default; accepted so old invocations still work
        --no-fetch)    DO_FETCH=0 ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "unknown option: $arg" >&2; usage >&2; exit 2 ;;
    esac
done

bold=$(tput bold 2>/dev/null || true)
red=$(tput setaf 1 2>/dev/null || true)
green=$(tput setaf 2 2>/dev/null || true)
yellow=$(tput setaf 3 2>/dev/null || true)
reset=$(tput sgr0 2>/dev/null || true)

step() { printf "\n%s==> %s%s\n" "$bold" "$1" "$reset"; }
ok()   { printf "%s  PASS%s  %s\n" "$green" "$reset" "$1"; }
bad()  { printf "%s  FAIL%s  %s\n" "$red" "$reset" "$1"; }
warn() { printf "%s  note%s  %s\n" "$yellow" "$reset" "$1"; }

# Every failure is recorded and the run continues, so one `swift test` failure doesn't hide a
# checklist problem you'd then hit on the next attempt. CI reports all three steps too.
FAILURES=()

run_job() {
    local job_name="$1" dir="$2"
    step "$job_name  (in ${dir/#$HOME/~})"

    local label
    for label in build test checklists; do
        case "$label" in
            build)      local cmd=(swift build) ;;
            test)       local cmd=(swift test) ;;
            checklists) local cmd=(./scripts/check_interactive_checklists.sh) ;;
        esac

        printf "  %s ... " "$label"
        local log
        log="$(mktemp)"
        if (cd "$dir" && "${cmd[@]}") >"$log" 2>&1; then
            printf "\r"; ok "$label"
        else
            printf "\r"; bad "$label"
            FAILURES+=("$job_name / $label")
            # Only the tail: a full swift build log buries the actual error.
            sed 's/^/      /' "$log" | tail -25
        fi
        rm -f "$log"
    done
}

if [ "$DO_FETCH" -eq 1 ] && [ "$RUN_MERGE" -eq 1 ]; then
    step "Fetching $BASE_BRANCH"
    if git fetch origin "$BASE_BRANCH" --quiet 2>/dev/null; then
        ok "origin/$BASE_BRANCH up to date"
    else
        warn "fetch failed (offline, or no access) -- merge preview may be against a stale base"
    fi
fi

if [ "$RUN_BRANCH" -eq 1 ]; then
    run_job "Test (branch as-is, unmerged)" "$REPO_ROOT"
fi

if [ "$RUN_MERGE" -eq 1 ]; then
    CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
    if [ "$CURRENT_BRANCH" = "$BASE_BRANCH" ]; then
        step "Test (after merge into base branch)"
        warn "already on $BASE_BRANCH -- nothing to merge, the job above already covers it"
    else
        WORKTREE="$(mktemp -d)/ci-local-merge"
        # Always clean up: a leaked worktree makes later `git worktree` commands complain, and the
        # temp copy of the repo is not small.
        cleanup() {
            git worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
            rm -rf "$(dirname "$WORKTREE")" 2>/dev/null || true
        }
        trap cleanup EXIT

        BASE_REF="origin/$BASE_BRANCH"
        git rev-parse --verify --quiet "$BASE_REF" >/dev/null || BASE_REF="$BASE_BRANCH"

        step "Preparing merge preview: $CURRENT_BRANCH into $BASE_REF"
        if ! git worktree add --quiet --detach "$WORKTREE" "$BASE_REF" 2>/dev/null; then
            bad "could not create the worktree"
            FAILURES+=("merge preview / worktree")
        else
            # --no-commit would leave the merge staged but unbuilt; commit it in the throwaway
            # worktree so the tree on disk is exactly what CI would compile.
            if (cd "$WORKTREE" && git merge --quiet --no-edit "$CURRENT_BRANCH") 2>/dev/null; then
                ok "merged cleanly"
                run_job "Test (after merge into base branch)" "$WORKTREE"
            else
                bad "merge conflict -- real CI would fail to even build this PR"
                (cd "$WORKTREE" && git diff --name-only --diff-filter=U | sed 's/^/      /')
                FAILURES+=("merge preview / conflict")
            fi
        fi
    fi
fi

# The one thing running natively cannot reproduce: CI resolves `xcode-version: latest-stable` on a
# macos-15 image, which is not necessarily what is installed here. Read from the most recent run
# rather than hardcoded, so it stays true as the runner image moves. Best-effort and non-fatal:
# offline, unauthenticated or no-runs-yet all just skip it.
report_toolchain() {
    local local_xcode ci_xcode
    local_xcode="$(xcodebuild -version 2>/dev/null | head -1 | awk '{print $2}')"
    echo "  local:  Xcode ${local_xcode:-unknown}, $(swift --version 2>/dev/null | sed -n 's/.*Apple Swift version \([^ ]*\).*/Swift \1/p' | head -1)"

    command -v gh >/dev/null 2>&1 || { echo "  ci:     (gh not installed -- cannot compare)"; return; }
    local run_id
    run_id="$(gh run list --workflow=tests.yml --status=success --limit 1 --json databaseId \
        --jq '.[0].databaseId' 2>/dev/null)"
    [ -n "$run_id" ] || { echo "  ci:     (no successful run to compare against)"; return; }

    ci_xcode="$(gh run view "$run_id" --log 2>/dev/null \
        | grep -m1 -o 'Xcode is set to [0-9.]*' | awk '{print $5}')"
    [ -n "$ci_xcode" ] || { echo "  ci:     (could not read Xcode version from run $run_id)"; return; }

    if [ "$ci_xcode" = "$local_xcode" ]; then
        echo "  ci:     Xcode $ci_xcode -- matches"
    else
        warn "toolchain differs: CI used Xcode $ci_xcode, this machine has ${local_xcode:-unknown}"
        echo "          A newer local Swift can accept code an older one rejects, so a green run"
        echo "          here is not proof CI will be green."
    fi
}

step "Summary"
if [ ${#FAILURES[@]} -eq 0 ]; then
    ok "everything CI checks passes locally"
    echo
    report_toolchain
    exit 0
fi

for failure in "${FAILURES[@]}"; do
    bad "$failure"
done
echo
report_toolchain
echo
echo "  ${#FAILURES[@]} failing step(s). Real CI would be red."
exit 1
