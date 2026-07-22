#!/usr/bin/env python3
"""Runs one or more Tests/Bench|Interactive checklists without Claude in the loop.

Usage (from repo root, normally via scripts/testrunner/run_tests.sh):
    python3 scripts/testrunner/supervisor.py Tests/Bench/04b-lock-and-pause-on-lock-checklist.md
    python3 scripts/testrunner/supervisor.py Tests/Bench/04b-*.md Tests/Interactive/04i-*.md

Each unchecked step with a ```toml step block runs via actions.run_step(); the result
flips its checkbox and appends an "(Automated: ...)"/"(AUTOMATED FAILURE: ...)" note,
same convention a human/Claude run already leaves. A step with no such block is
documentation-only and is skipped, not guessed at. On the first failed step in a
checklist, that checklist stops (later steps assume the state earlier ones left) --
subsequent checklists passed on the command line still run.

Every run writes a full transcript to logs/YYYY-MM-DD_hh.mm.ss.txt regardless of
outcome, and exits non-zero if anything failed or was skipped -- for CI/scripts to
check, and for a developer to attach to an issue.
"""

import argparse
import datetime
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from md_checklist import Checklist  # noqa: E402
from actions import run_step  # noqa: E402
from session_setup import confirm_warning, ensure_known_state  # noqa: E402

DEFAULT_DB_PATH = os.path.expanduser("~/Library/Application Support/TimeFlip/appdata.sqlite")


def run_checklist(path, db_path, log_lines):
    checklist = Checklist(path)
    log_lines.append(f"\n=== {path} ===")

    total = len(checklist.steps)
    already_done = sum(1 for s in checklist.steps if s.checked)
    if 0 < already_done < total:
        print(f"\n{path}: {already_done}/{total} steps already checked -- this checklist is mid-run.")
        choice = input("Continue from the first unchecked step (c), or restart from the top (r)? [c/r] ").strip().lower()
        log_lines.append(f"Mid-run ({already_done}/{total}); user chose: {choice or 'c'}")
        if choice == "r":
            print(
                "Restart requested -- per Tests/CLAUDE.md's Restarting section, clear this file's "
                "checkboxes yourself first (it discards recorded evidence, so it's not done "
                "automatically), then re-run."
            )
            log_lines.append("Restart requested; user must clear checkboxes manually before re-running.")
            return False

    ctx = {"db_path": db_path, "vars": {}}
    all_ok = True
    ran_any = False
    skipped_prose = set()  # prose of steps already SKIPped -- stable across reparses, unlike line numbers
    while True:
        # Re-fetch fresh every iteration: mark() re-parses and shifts every later step's
        # line numbers, so a snapshot list taken before any mutation goes stale mid-loop.
        step = next(
            (s for s in checklist.steps if not s.checked and s.prose not in skipped_prose),
            None,
        )
        if step is None:
            break
        ran_any = True
        actor_tag = "(You) " if step.actor == "you" else ""
        print(f"\n[{os.path.basename(path)}] {actor_tag}{step.prose}")

        if step.spec is None:
            print("  -> SKIP: no automated spec for this step (documentation-only or not yet converted).")
            log_lines.append(f"SKIP (no spec): {step.prose}")
            all_ok = False
            skipped_prose.add(step.prose)
            continue

        result = run_step(step.spec, ctx)
        status = "PASS" if result.success else "FAIL"
        print(f"  -> {status}: {result.detail}")
        log_lines.append(f"{status}: {step.prose} :: {result.detail}")

        checklist.mark(step, result.success, result.detail)
        checklist.save()

        if not result.success:
            all_ok = False
            print(f"\n!!! Stopping {path} -- later steps assume this one succeeded.")
            log_lines.append(f"STOPPED {path} after failed step above.")
            break

    if not ran_any:
        print(f"\n{path}: already fully checked, nothing to run.")
        log_lines.append("Already fully checked; nothing run.")

    return all_ok


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("checklists", nargs="+", help="Checklist .md file paths, in the order they should run.")
    parser.add_argument("--db-path", default=DEFAULT_DB_PATH, help="Path to appdata.sqlite (default: the real app data location).")
    parser.add_argument(
        "--yes",
        action="store_true",
        help="Skip the interactive confirmation prompt (still prints the warning) -- for CI/non-interactive runs only.",
    )
    args = parser.parse_args()

    timestamp = datetime.datetime.now().strftime("%Y-%m-%d_%H.%M.%S")
    repo_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    log_dir = os.path.join(repo_root, "logs")
    os.makedirs(log_dir, exist_ok=True)
    log_path = os.path.join(log_dir, f"{timestamp}.txt")

    log_lines = [f"TimeFlip device-test run started {timestamp}", f"Checklists: {', '.join(args.checklists)}"]

    if args.yes:
        from session_setup import WARNING_TEMPLATE, RESET_WARNING
        includes_reset = any("02b" in os.path.basename(p) or "02i" in os.path.basename(p) for p in args.checklists)
        print(WARNING_TEMPLATE.format(reset_warning=RESET_WARNING if includes_reset else ""))
        print("(--yes passed: skipping confirmation prompt)")
        confirmed = True
    else:
        confirmed = confirm_warning(args.checklists)
    if not confirmed:
        print("Aborted -- confirmation not given.")
        sys.exit(1)
    log_lines.append("Developer confirmed the device-manipulation warning.")

    if not ensure_known_state(args.db_path, repo_root):
        print("Aborted -- could not establish a known device/database state.")
        log_lines.append("ABORTED: could not establish known device/database state.")
        with open(log_path, "w") as f:
            f.write("\n".join(log_lines) + "\n")
        sys.exit(1)
    log_lines.append("Known device/database state established.")

    overall_ok = True
    for path in args.checklists:
        ok = run_checklist(path, args.db_path, log_lines)
        overall_ok = overall_ok and ok

    log_lines.append(f"\nOverall result: {'PASS' if overall_ok else 'FAIL'}")
    with open(log_path, "w") as f:
        f.write("\n".join(log_lines) + "\n")

    print(f"\n{'=' * 60}")
    print(f"Overall result: {'PASS' if overall_ok else 'FAIL'}")
    print(f"Log written to {log_path}")
    sys.exit(0 if overall_ok else 1)


if __name__ == "__main__":
    main()
