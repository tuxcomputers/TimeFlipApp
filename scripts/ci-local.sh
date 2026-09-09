#!/usr/bin/env bash
# Run what .github/workflows/tests.yml runs, locally, before opening a PR.
#
# Why this exists: the workflow only fires on push to main or on a pull_request, so a branch with
# no PR gets no CI at all -- the first signal arrives when the PR is opened, which is the worst
# moment to discover a red build.
#
# What can be reproduced exactly, and what only approximated:
#
# **The two macOS jobs cannot be containerised.** `runs-on: macos-15` is a virtual machine and macOS
# does not run in Docker, so those two are run natively and are an approximation of CI rather than a
# copy of it. The closest true emulation would be a macOS 15 VM (Tart on Apple Silicon) carrying
# CI's exact Xcode, which is tens of gigabytes and hours of setup. What that would buy is reported
# below instead: the script prints the local toolchain against the one CI last used, so a divergence
# is visible rather than assumed away.
#
# **The Linux job can be, and is.** `test-linux` was added on 2026-09-09 and is a real container --
# `swift:6.2-noble` plus four dev packages is the whole of its environment -- so running it under
# podman or docker here is the thing itself rather than a stand-in. That matters more than it sounds:
# the risk in that job is everything a bare container does *not* have, and a machine that already has
# BlueZ, a system bus and its own compiler cannot test for their absence. With no runtime installed
# the script falls back to running its commands natively and says plainly that this is the weaker
# check.
#
# This paragraph used to say the only containerisable job was `all-tests-pass`, a bash aggregator
# whose local run would prove nothing, and concluded `act` had nothing to offer. That was true until
# there was a Linux build-and-test job.
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
# On by default, because it is the job most likely to be broken by a change nobody tested: it is the
# newest, and the only one whose environment is built from scratch on every run.
RUN_LINUX=1

usage() {
    cat <<'USAGE'
usage: ci-local.sh [--with-merge | --merge-only] [--no-fetch] [--no-linux]

  (default)      Just the branch tip, matching CI's "test-branch-as-is" job.
  --with-merge   Also run CI's "test-merge-result" job: this branch merged into
                 its base, in a throwaway worktree. Worth it before opening a PR,
                 or whenever the base has moved.
  --merge-only   Only the merged-into-base job.
  --no-fetch     Don't `git fetch` first. Faster, but the merge preview is then
                 against a possibly stale base and can pass when real CI fails.
  --no-linux     Skip CI's "test-linux" job. It runs in a `swift:6.2-noble`
                 container when podman or docker is installed, which is the only
                 exact reproduction of any CI job available here, and falls back
                 to running its commands natively when neither is.

  CI_LOCAL_BASE  Base branch to merge against (default: main).
USAGE
}

for arg in "$@"; do
    case "$arg" in
        --with-merge)  RUN_MERGE=1 ;;
        --merge-only)  RUN_BRANCH=0; RUN_MERGE=1 ;;
        --branch-only) RUN_MERGE=0 ;;  # now the default; accepted so old invocations still work
        --no-fetch)    DO_FETCH=0 ;;
        --no-linux)    RUN_LINUX=0 ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "unknown option: $arg" >&2; usage >&2; exit 2 ;;
    esac
done

# Stands in for CI's `github.head_ref`, so the checklist check gets the same "which branch is this
# PR for" answer locally. Read from the real repo, not the merge worktree, which is detached and
# would answer "HEAD". Empty on main or in a detached HEAD, exactly as head_ref is empty on a push
# to main, which skips the Last-run half of the check rather than failing it.
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
PR_BRANCH="$CURRENT_BRANCH"
if [ "$PR_BRANCH" = "HEAD" ] || [ "$PR_BRANCH" = "$BASE_BRANCH" ]; then
    PR_BRANCH=""
fi

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
            checklists) local cmd=(./scripts/check_interactive_checklists.sh --branch "$PR_BRANCH") ;;
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

# **CI's Linux job, and this is the one that can be reproduced rather than approximated.**
# `swift build`, a private bus, then `swift test` less the two adapter-bound tests, in the container
# the workflow names.
#
# It starts a private bus with no BlueZ on it and skips only the two adapter-bound tests, exactly as
# the workflow does. Five of the seven `SystemBusTests` pass on a bare bus, settled on 2026-09-09 and
# without a container: `dbus_bus_get(DBUS_BUS_SYSTEM)` reads `DBUS_SYSTEM_BUS_ADDRESS`, so a private
# `dbus-daemon` reproduces a runner's bus on any machine that has one.
# Keep this in step with `.github/workflows/tests.yml`: the two commands are meant to be the same.
run_linux_job() {
    local dir="$1"
    step "Test (Linux, the portable half)"

    local runtime="" candidate
    for candidate in podman docker; do
        if command -v "$candidate" >/dev/null 2>&1; then runtime="$candidate"; break; fi
    done

    if [ -n "$runtime" ]; then
        printf "  container (%s, swift:6.2-noble) ... " "$runtime"
        local log; log="$(mktemp)"
        # **`--scratch-path` outside the mount, and it is not tidiness.** The container is root and
        # carries a different patch release, so letting it build into the host's `.build` would leave
        # root-owned 6.2.4 artifacts for this machine's 6.2.0 to trip over afterwards.
        if "$runtime" run --rm -v "$dir:/w" -w /w swift:6.2-noble bash -c '
                set -e
                apt-get update -qq
                apt-get install -y -qq --no-install-recommends                     pkg-config dbus libsqlite3-dev libdbus-1-dev libgtk-3-dev                     libayatana-appindicator3-dev >/dev/null
                swift --version
                swift build --scratch-path /tmp/ci-build
                BUSCONF=/tmp/facet-bus.conf; printf "%s\n" "<busconfig><type>system</type><listen>unix:tmpdir=/tmp</listen>" "<policy context=\"default\"><allow user=\"*\"/><allow own=\"*\"/>" "<allow send_destination=\"*\"/><allow receive_sender=\"*\"/></policy></busconfig>" > $BUSCONF; dbus-daemon --config-file=$BUSCONF --print-address --fork > /tmp/facet-bus.addr; export DBUS_SYSTEM_BUS_ADDRESS=$(cat /tmp/facet-bus.addr)
                swift test --scratch-path /tmp/ci-build --skip theNestedObjectTreeIsWalkedToItsLeaves --skip aSignalArrivesAndItsValuesAreTyped
            ' >"$log" 2>&1; then
            printf "\r"; ok "container ($runtime, swift:6.2-noble)"
            grep -E "Swift version|Executed [0-9]+ tests|Test run with" "$log" \
                | sed 's/^/      /' | tail -4
        else
            printf "\r"; bad "container ($runtime, swift:6.2-noble)"
            FAILURES+=("Test (Linux) / container")
            sed 's/^/      /' "$log" | tail -25
        fi
        rm -f "$log"
        return
    fi

    if [ "$(uname -s)" != "Linux" ]; then
        warn "no podman or docker, and this is not Linux -- CI's Linux job cannot be run here at all"
        echo "          Install either one and this becomes the only CI job you can reproduce exactly."
        return
    fi

    warn "no podman or docker: running the job's commands natively instead"
    echo "          Weaker than it looks. This machine has BlueZ, a system bus, its own compiler and"
    echo "          whatever else is installed, and that is most of what the job's first run risks."
    local label log
    for label in build test; do
        local cmd
        case "$label" in
            build) cmd=(swift build) ;;
            # The workflow's two skips, against whatever bus this machine has rather than a
            # private one: the point of the native path is the build and the suite.
            test)  cmd=(swift test --skip theNestedObjectTreeIsWalkedToItsLeaves --skip aSignalArrivesAndItsValuesAreTyped) ;;
        esac
        printf "  %s ... " "$label"
        log="$(mktemp)"
        if (cd "$dir" && "${cmd[@]}") >"$log" 2>&1; then
            printf "\r"; ok "$label (native, not the container)"
        else
            printf "\r"; bad "$label (native, not the container)"
            FAILURES+=("Test (Linux, native) / $label")
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

# Once, against the branch tip: the job builds its environment from scratch, so running it a second
# time against the merge preview costs a full container build to re-answer the same question.
if [ "$RUN_LINUX" -eq 1 ]; then
    run_linux_job "$REPO_ROOT"
fi

if [ "$RUN_MERGE" -eq 1 ]; then
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
