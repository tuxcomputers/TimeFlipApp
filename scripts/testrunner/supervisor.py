#!/usr/bin/env python3
"""Runs one or more Tests/Bench|Interactive checklists without Claude in the loop.

Usage (from repo root, normally via scripts/testrunner/run_tests.sh):
    python3 scripts/testrunner/supervisor.py
        No arguments: auto-discovers every *-checklist.md in Tests/Bench (sorted), then
        every one in Tests/Interactive (sorted) -- the whole Bench-then-Interactive run.

    python3 scripts/testrunner/supervisor.py -f Bench
        Only auto-discover checklists from that one folder (Bench or Interactive).

    python3 scripts/testrunner/supervisor.py -s 01
        Auto-discover across both folders (Bench then Interactive), keeping only
        filenames containing this substring -- e.g. "-s 01b" runs just 01b; "-s 05"
        runs 05b then 05i; "-s reset" matches by name instead of number.

    python3 scripts/testrunner/supervisor.py -f Bench -s reset
        Combine both: one folder, filtered by substring.

    python3 scripts/testrunner/supervisor.py Tests/Bench/04b-lock-and-pause-on-lock-checklist.md
        Explicit file paths still work, run in the exact order given, bypassing
        auto-discovery entirely.

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
from actions import run_step, capture_names  # noqa: E402
from session_setup import (  # noqa: E402
    confirm_warning,
    ensure_known_state,
    ensure_not_timing_on_production,
    reset_device_for_cleanup,
    restore_production_database,
)

DEFAULT_DB_PATH = os.path.expanduser("~/Library/Application Support/TimeFlip/appdata.sqlite")


def _checklist_id(path):
    """The leading token of the filename, e.g. "01b" from "01b-history-refresh-checklist.md"."""
    return os.path.basename(path).split("-", 1)[0]


def _file_label(path):
    """Human label for a checklist, e.g. "Bench test 01" / "Interactive test 01"."""
    suite = "Interactive" if os.sep + "Interactive" + os.sep in path else "Bench"
    digits = "".join(c for c in _checklist_id(path) if c.isdigit())
    return f"{suite} test {digits}" if digits else f"{suite} {os.path.basename(path)}"


def _section_code(section):
    """Compact section code for a NOTE id: "Setup" -> "Setup", "Scenario A" -> "ScA",
    anything else -> spaces stripped, capped."""
    s = (section or "").strip()
    if s.lower().startswith("scenario "):
        return "Sc" + s[len("scenario "):].strip()
    if s.lower() == "setup":
        return "Setup"
    return "".join(s.split())[:8] or "Sec"


def _note_id(path, step):
    """Broad-to-narrow step id for a logged NOTE line, e.g. "T01b-ScA-St4" /
    "T02i-Setup-St3". (A scenario precondition, recorded by hand rather than by an
    automated step, uses "-Pre" in place of "-St<n>".)"""
    return f"T{_checklist_id(path)}-{_section_code(step.section)}-St{step.number}"


def discover_checklists(repo_root, folder=None, search=None):
    """Auto-discovery for when no explicit file paths are given: Bench (sorted) then
    Interactive (sorted), optionally narrowed to one folder and/or filtered by a
    substring checked against the filename -- not just the .md extension, so "-s 01b"
    or "-s reset" both work the same way (name-based or number-based)."""
    folder_dirs = {
        "Bench": os.path.join(repo_root, "Tests", "Bench"),
        "Interactive": os.path.join(repo_root, "Tests", "Interactive"),
    }
    dirs = [folder_dirs[folder]] if folder else [folder_dirs["Bench"], folder_dirs["Interactive"]]

    paths = []
    for d in dirs:
        names = sorted(f for f in os.listdir(d) if f.endswith("-checklist.md"))
        if search:
            names = [n for n in names if search in n]
        paths.extend(os.path.join(d, n) for n in names)
    return paths


def prompt_yn(prompt):
    """Same loop-until-valid-y-or-n shape as actions.act_ask_user (input lowercased
    before comparison, so any case works), for the two whole-run rerun/resume
    questions asked before any checklist starts."""
    while True:
        answer = input(f"{prompt} [y/n]: ").strip().lower()
        if answer == "y":
            return True
        if answer == "n":
            return False
        print(f"Not recognized: {answer!r} -- please answer 'y' or 'n'.")


def summarize_progress(checklist_paths):
    """Checked/total step counts for each path, without mutating anything -- the basis
    for the up-front rerun/resume decision."""
    infos = []
    for p in checklist_paths:
        checklist = Checklist(p)
        total = len(checklist.steps)
        done = sum(1 for s in checklist.steps if s.checked)
        infos.append((p, done, total))
    return infos


def _resume_point(checklist_paths):
    """Across the ordered batch, find the step to resume at: `next` = the first unchecked
    runnable step (falling back to the first unchecked step of any kind), and `last` = the
    last checked step before it. Each is a (path, Step) pair, or None. Returns (last, next);
    next is None only if every step is already checked."""
    flat = [(p, s) for p in checklist_paths for s in Checklist(p).steps]
    next_i = next((i for i, (_, s) in enumerate(flat) if not s.checked and s.spec is not None), None)
    if next_i is None:
        next_i = next((i for i, (_, s) in enumerate(flat) if not s.checked), None)
    if next_i is None:
        return None, None
    last = next(((flat[i]) for i in range(next_i - 1, -1, -1) if flat[i][1].checked), None)
    return last, flat[next_i]


def _print_resume_location(checklist_paths, log_lines):
    """Concise 'where we left off + what's next' for a mid-run batch -- replaces dumping
    every requested checklist and its counts."""
    last, nxt = _resume_point(checklist_paths)
    if nxt is None:
        return
    if last is not None:
        lp, ls = last
        loc = f"{_file_label(lp)} · {ls.section} · Step {ls.number}"
        print(f"\nResuming — last completed:\n  {loc}")
        log_lines.append(f"Resume; last completed: {loc}")
    else:
        print("\nResuming — nothing completed yet, starting from the top.")
        log_lines.append("Resume; nothing completed yet.")
    np, ns = nxt
    desc = ns.description()
    print(f"\nNext step: {desc}")
    log_lines.append(f"Next step: {_file_label(np)} · {ns.section} · Step {ns.number}: {desc}")


def resolve_rerun_state(checklist_paths, log_lines, auto_yes):
    """Whole-batch, up-front check: if every requested checklist is already fully ticked,
    offer to clear them all and run again; otherwise (any checklist partially or entirely
    unticked) show where we left off and what's next, and offer to resume -- clearing the
    whole batch and starting over if the developer declines. Returns False if there's
    nothing to run."""
    infos = summarize_progress(checklist_paths)
    all_complete = all(done == total for _, done, total in infos)
    n = len(infos)

    if all_complete:
        print(f"\nAll {n} requested checklist{'s' if n != 1 else ''} are already fully completed.")
        if auto_yes:
            print("(--yes passed: clearing results and running again)")
            clear_again = True
        else:
            clear_again = prompt_yn("Clear their results and run again?")
        log_lines.append(f"All requested checklists already complete; clear-and-rerun: {clear_again}")
        if not clear_again:
            return False
        for p, _, _ in infos:
            c = Checklist(p)
            c.clear_checkboxes()
            c.save()
        return True

    _print_resume_location(checklist_paths, log_lines)
    if auto_yes:
        print("(--yes passed: resuming from where things left off)")
        resume = True
    else:
        resume = prompt_yn("Continue from here? ('n' restarts the whole batch from the top)")
    log_lines.append(f"Requested checklists mid-run; resume: {resume}")
    if not resume:
        for p, _, _ in infos:
            c = Checklist(p)
            c.clear_checkboxes()
            c.save()
    return True


def run_checklist(path, db_path, log_lines, auto_yes=False):
    checklist = Checklist(path)
    log_lines.append(f"\n=== {path} ===")

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
            if step.section == "Setup":
                # A Setup step with no toml is the quit/switch-to-test/relaunch procedure
                # that session_setup.ensure_known_state() already performed once, before any
                # checklist ran (see 01b/05b/06b/07b) -- so record it done rather than skip.
                # Re-running it here would rebuild test.sqlite and wipe the synced history
                # the scenarios depend on.
                print("  -> OK (setup already established by session_setup): ticking.")
                log_lines.append(f"OK (setup via session_setup): {step.prose}")
                checklist.mark(step, True)
                checklist.save()
                continue
            if auto_yes:
                # --yes/non-interactive: there's no human to ask, and this step needs one
                # (no toml to automate it) -- record it as a skip rather than block on input.
                print("  -> SKIP: needs human verification; --yes/non-interactive can't ask.")
                log_lines.append(f"SKIP (needs human; --yes): {step.prose}")
                all_ok = False
                skipped_prose.add(step.prose)
                continue
            # No toml to automate this and it isn't Setup, so a human has to look (e.g. a
            # screenshot / visual confirmation). Ask -- never silently skip.
            print("  -> NEEDS YOU: verify this step against the app/device.")
            passed = prompt_yn("  Did this check pass?")
            checklist.mark(step, passed)
            checklist.save()
            log_lines.append(f"{'PASS' if passed else 'FAIL'} (human-verified): {step.prose}")
            if not passed:
                all_ok = False
                print(f"\n!!! Stopping {path} -- later steps assume this one succeeded.")
                log_lines.append(f"STOPPED {path} after failed step above.")
                break
            continue

        result = run_step(step.spec, ctx)
        status = "PASS" if result.success else "FAIL"
        print(f"  -> {status}: {result.detail}")
        log_lines.append(f"{status}: {step.prose} :: {result.detail}")

        # Any values this step captured go to the log as a NOTE line keyed by the step's
        # broad-to-narrow id -- not back into the .md (a tick is its only in-file record).
        if result.success:
            captured = [(name, ctx["vars"].get(name)) for name in capture_names(step.spec)]
            captured = [(name, value) for name, value in captured if value is not None]
            if captured:
                pairs = ", ".join(f"{name}={value}" for name, value in captured)
                log_lines.append(f"*****NOTE****** {_note_id(path, step)}: {pairs}")

        checklist.mark(step, result.success)
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
    parser.add_argument(
        "checklists",
        nargs="*",
        help="Explicit checklist .md file paths, run in the exact order given. If omitted, "
        "checklists are auto-discovered instead (see -f/-s) -- Bench folder sorted, then "
        "Interactive folder sorted.",
    )
    parser.add_argument(
        "-f", "--folder",
        type=str.title,
        choices=["Bench", "Interactive"],
        help="Auto-discovery only: restrict to this one folder (case-insensitive).",
    )
    parser.add_argument(
        "-s", "--search",
        help="Auto-discovery only: keep only filenames containing this substring, e.g. "
        "'01b' (one checklist), '05' (05b then 05i), or 'reset' (matches by name).",
    )
    parser.add_argument("--db-path", default=DEFAULT_DB_PATH, help="Path to appdata.sqlite (default: the real app data location).")
    parser.add_argument(
        "--yes",
        action="store_true",
        help="Skip the interactive confirmation prompt (still prints the warning) -- for CI/non-interactive runs only.",
    )
    args = parser.parse_args()

    timestamp = datetime.datetime.now().strftime("%Y-%m-%d_%H.%M.%S")
    repo_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

    if args.checklists:
        if args.folder or args.search:
            print("error: explicit checklist paths and -f/-s auto-discovery are mutually exclusive.")
            sys.exit(1)
        checklist_paths = args.checklists
    else:
        checklist_paths = discover_checklists(repo_root, folder=args.folder, search=args.search)
        if not checklist_paths:
            print("No checklists matched -f/-s -- nothing to run.")
            sys.exit(1)
        print(f"Auto-discovered {len(checklist_paths)} checklist(s) to run (Bench then Interactive).")

    log_dir = os.path.join(repo_root, "logs")
    os.makedirs(log_dir, exist_ok=True)
    log_path = os.path.join(log_dir, f"{timestamp}.txt")

    log_lines = [f"TimeFlip device-test run started {timestamp}", "Checklists:"]
    log_lines.extend(f"  {p}" for p in checklist_paths)

    # First thing, before we ask the developer anything: if we're still on production and
    # the device is mid-timing a real activity, bail immediately rather than after they've
    # answered the rerun/resume and confirmation prompts. This run switches to test and
    # factory-resets the device at the end, which would interrupt that real timing event.
    if not ensure_not_timing_on_production(args.db_path):
        print("\nAborted -- pause the device, then re-run.")
        log_lines.append("ABORTED: on production and device is mid-timing; developer must pause first.")
        with open(log_path, "w") as f:
            f.write("\n".join(log_lines) + "\n")
        sys.exit(1)

    if not resolve_rerun_state(checklist_paths, log_lines, args.yes):
        print("\nNothing to run.")
        log_lines.append("Nothing to run.")
        with open(log_path, "w") as f:
            f.write("\n".join(log_lines) + "\n")
        sys.exit(0)

    if args.yes:
        from session_setup import WARNING_TEMPLATE, RESET_WARNING
        includes_reset = any("02b" in os.path.basename(p) or "02i" in os.path.basename(p) for p in checklist_paths)
        print(WARNING_TEMPLATE.format(reset_warning=RESET_WARNING if includes_reset else ""))
        print("(--yes passed: skipping confirmation prompt)")
        confirmed = True
    else:
        confirmed = confirm_warning(checklist_paths)
    if not confirmed:
        print("Aborted -- confirmation not given.")
        sys.exit(1)
    log_lines.append("Developer confirmed the device-manipulation warning.")

    resolved_db_path = ensure_known_state(args.db_path, repo_root)
    if not resolved_db_path:
        print("Aborted -- could not establish a known device/database state.")
        log_lines.append("ABORTED: could not establish known device/database state.")
        with open(log_path, "w") as f:
            f.write("\n".join(log_lines) + "\n")
        sys.exit(1)
    log_lines.append(f"Known device/database state established (db file: {resolved_db_path}).")

    # Every checklist/cleanup query below targets this resolved, concrete file directly
    # -- not args.db_path (the appdata.sqlite symlink, which the app itself keeps using)
    # -- so nothing here can be affected by a later, unrelated change to the symlink.
    overall_ok = True
    for path in checklist_paths:
        ok = run_checklist(path, resolved_db_path, log_lines, args.yes)
        overall_ok = overall_ok and ok

    cleanup_ok = reset_device_for_cleanup(resolved_db_path)
    log_lines.append(f"\nEnd-of-run device cleanup: {'OK' if cleanup_ok else 'FAILED -- reset/pair the device manually'}")
    if not cleanup_ok:
        print(
            "\n!!! Cleanup reset did not complete -- the device may still carry this "
            "session's test activity. Reset/pair it manually before trusting production "
            "history once you switch back."
        )

    if args.yes:
        print("(--yes passed: switching back to the production database)")
        restore_now = True
    else:
        restore_now = prompt_yn(
            "\nSwitch back to the production database now? Say 'n' if you're about to run "
            "more tests -- switching back and forth every run is wasted effort."
        )
    log_lines.append(f"Switch back to production database requested: {restore_now}")

    if restore_now:
        db_restore_ok = restore_production_database(args.db_path, repo_root)
        log_lines.append(f"End-of-run database restore: {'OK' if db_restore_ok else 'FAILED -- run scripts/use-production-database.sh manually'}")
        if not db_restore_ok:
            print(
                "\n!!! Could not switch back to the production database automatically -- quit "
                "the app and run scripts/use-production-database.sh yourself, then relaunch, "
                "before trusting production history."
            )
    else:
        print(
            "\nStaying on the test database. Run scripts/use-production-database.sh (quit the "
            "app first) whenever you're ready to switch back."
        )
        log_lines.append("Developer chose to stay on the test database for now.")

    log_lines.append(f"\nOverall result: {'PASS' if overall_ok else 'FAIL'}")
    with open(log_path, "w") as f:
        f.write("\n".join(log_lines) + "\n")

    print(f"\n{'=' * 60}")
    print(f"Overall result: {'PASS' if overall_ok else 'FAIL'}")
    print(f"Log written to {log_path}")
    sys.exit(0 if overall_ok else 1)


if __name__ == "__main__":
    main()
