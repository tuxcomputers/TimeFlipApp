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


class _TeeLog(list):
    """A log that streams to disk as it grows: every append/extend also writes the line to
    the log file and flushes it. So the log on disk stays complete even if the run is
    killed, hangs on a prompt, or crashes mid-way -- not only when it reaches a clean exit
    (the old behaviour, which wrote the whole buffered log in one go at the end and lost
    everything on an interruption). Still a plain list, so `"\\n".join(...)` etc. work."""

    def __init__(self, path):
        super().__init__()
        self._f = open(path, "w", buffering=1)  # line-buffered

    def append(self, line):
        super().append(line)
        self._f.write(line + "\n")
        self._f.flush()

    def extend(self, lines):
        for line in lines:
            self.append(line)


class _RunHalted(Exception):
    """Raised to end the whole run immediately (not just the current checklist) -- used by the
    per-step confirmation gate when the developer answers 'n', or when a step fails while that
    gate is on, so a mis-run can be investigated before it cascades into later steps/checklists.
    Carries a short reason for the log/console."""


def _confirm_step(path, step, detail, log_lines):
    """Primary per-step question, phrased so Y = good/continue: shows the step's result and asks
    the developer to confirm it did what it should. Returns True if confirmed, False otherwise
    (the caller then runs _failure_continue_or_halt)."""
    note = _note_id(path, step)
    print(f"  result: {detail}")
    if prompt_yn(f"  Confirm this step is correct [{note}]?"):
        log_lines.append(f"CONFIRMED: {note}")
        return True
    return False


def _failure_continue_or_halt(path, step, checklist, log_lines, skipped_prose, reason):
    """Follow-up after a No / an outright failure, in confirm-steps mode. The failure is always
    logged and the step left unticked (and skipped so it isn't re-selected); then asks whether to
    keep going. The developer's answer is logged too. Yes continues to the next step; No raises
    _RunHalted to stop the whole run for investigation."""
    checklist.mark(step, False)
    checklist.save()
    skipped_prose.add(step.prose)
    note = _note_id(path, step)
    log_lines.append(f"FAILURE LOGGED: {note} -- {reason}")
    cont = prompt_yn("  Failure is logged, did you want to continue the tests?")
    log_lines.append(f"Continue after failure [{note}]? -> {'y' if cont else 'n'}")
    if not cont:
        raise _RunHalted(f"{note}: {reason}")


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


def run_checklist(path, db_path, log_lines, auto_yes=False, confirm_steps=False):
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
                # A Setup step with no toml describes the switch-to-test procedure that the
                # shared Tests/00-test-setup.md already performed once at the start of the run
                # (see 01b/05b/06b/07b, whose Setup narrates it) -- so record it done rather
                # than skip. Re-running it here would rebuild test.sqlite and wipe the history
                # 00-test-setup just synced.
                print("  -> OK (setup already done by 00-test-setup.md): ticking.")
                log_lines.append(f"OK (setup via 00-test-setup.md): {step.prose}")
                if confirm_steps and not _confirm_step(path, step, "setup established by session_setup", log_lines):
                    all_ok = False
                    _failure_continue_or_halt(path, step, checklist, log_lines, skipped_prose, "setup step not confirmed")
                    continue
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
            # screenshot / visual confirmation). Ask -- never silently skip. The question is
            # phrased so Y = passed/continue.
            print("  -> NEEDS YOU: verify this step against the app/device.")
            passed = prompt_yn("  Did this check pass?")
            if passed:
                checklist.mark(step, True)
                checklist.save()
                log_lines.append(f"PASS (human-verified): {step.prose}")
                continue
            log_lines.append(f"FAIL (human-verified): {step.prose}")
            all_ok = False
            if confirm_steps:
                _failure_continue_or_halt(path, step, checklist, log_lines, skipped_prose, "human-verified step did not pass")
                continue
            checklist.mark(step, False)
            checklist.save()
            print(f"\n!!! Stopping {path} -- later steps assume this one succeeded.")
            log_lines.append(f"STOPPED {path} after failed step above.")
            break

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

        if result.success:
            # In confirm-steps mode the developer still gets the final say on whether the
            # (auto-passing) result is actually right; a No drops to the log-and-continue gate.
            if confirm_steps and not _confirm_step(path, step, result.detail, log_lines):
                all_ok = False
                _failure_continue_or_halt(path, step, checklist, log_lines, skipped_prose, f"result not confirmed: {result.detail}")
                continue
            checklist.mark(step, True)
            checklist.save()
            continue

        # Failed step.
        all_ok = False
        if confirm_steps:
            _failure_continue_or_halt(path, step, checklist, log_lines, skipped_prose, f"step failed: {result.detail}")
            continue
        checklist.mark(step, False)
        checklist.save()
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
    parser.add_argument(
        "--no-confirm-steps",
        dest="confirm_steps",
        action="store_false",
        help="Don't pause after each step. By default (interactive runs) the runner shows every "
        "step's result and waits for a y/n that it did what it should; answering 'n' -- or any step "
        "failing -- ends the whole run so a mis-run can be investigated before it cascades. --yes "
        "implies this flag (no human to confirm).",
    )
    args = parser.parse_args()
    # No human to answer per-step prompts under --yes, so confirmation is off there.
    confirm_steps = args.confirm_steps and not args.yes

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

    # Streams to disk on every append (see _TeeLog), so an interrupted/hung/killed run
    # still leaves a complete-so-far log rather than nothing.
    log_lines = _TeeLog(log_path)
    log_lines.append(f"TimeFlip device-test run started {timestamp}")
    log_lines.append("Checklists:")
    log_lines.extend(f"  {p}" for p in checklist_paths)

    # First thing, before we ask the developer anything: if we're still on production and
    # the device is mid-timing a real activity, bail immediately rather than after they've
    # answered the rerun/resume and confirmation prompts. This run switches to test and
    # factory-resets the device at the end, which would interrupt that real timing event.
    if not ensure_not_timing_on_production(args.db_path):
        print("\nAborted -- pause the device, then re-run.")
        log_lines.append("ABORTED: on production and device is mid-timing; developer must pause first.")
        sys.exit(1)

    if not resolve_rerun_state(checklist_paths, log_lines, args.yes):
        print("\nNothing to run.")
        log_lines.append("Nothing to run.")
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

    # Query the appdata.sqlite symlink from here on. The shared setup below repoints it (that's
    # the one place the test database is built), and every step runs sequentially, so following
    # the symlink is correct -- no concrete path needs pinning.
    db_path = args.db_path
    setup_path = os.path.join(repo_root, "Tests", "00-test-setup.md")

    overall_ok = True
    try:
        # Always run the shared setup first, fresh, whatever subset was requested (Bench,
        # Interactive, a single file) -- it switches to the test database once and confirms the
        # device is connected. Its boxes are cleared so it re-runs every time; a failure here
        # aborts before any feature checklist.
        setup = Checklist(setup_path)
        setup.clear_checkboxes()
        setup.save()
        log_lines.append("\n--- Test setup (00-test-setup.md), always run first ---")
        if not run_checklist(setup_path, db_path, log_lines, args.yes, confirm_steps):
            print("\nAborted -- test setup failed; not running any checklists.")
            log_lines.append("ABORTED: test setup failed.")
            sys.exit(1)

        for path in checklist_paths:
            ok = run_checklist(path, db_path, log_lines, args.yes, confirm_steps)
            overall_ok = overall_ok and ok
    except _RunHalted as halt:
        banner = "!" * 70
        print(f"\n{banner}")
        print(f"RUN HALTED for investigation: {halt}")
        print("End-of-run cleanup (device factory reset / production restore) was SKIPPED so you")
        print("can inspect the current state. You are most likely still on the TEST database --")
        print("quit the app and run scripts/use-production-database.sh when you're done.")
        print(banner)
        log_lines.append(f"\nRUN HALTED: {halt} (end-of-run cleanup skipped)")
        sys.exit(2)

    cleanup_ok = reset_device_for_cleanup(db_path)
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

    print(f"\n{'=' * 60}")
    print(f"Overall result: {'PASS' if overall_ok else 'FAIL'}")
    print(f"Log written to {log_path}")
    sys.exit(0 if overall_ok else 1)


if __name__ == "__main__":
    main()
