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
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from md_checklist import Checklist  # noqa: E402
from methods import load_methods, methods_path, resolve_uses  # noqa: E402
from actions import (  # noqa: E402
    condition_met,
    print_action_required,
    resolve_missing_vars_from_remembered,
    run_step,
)
from remembered import Remembered  # noqa: E402
from session_setup import (  # noqa: E402
    _latest_debug_log_id,
    confirm_warning,
    device_appears_connected,
    ensure_not_timing_on_production,
    reset_device_for_cleanup,
    restore_production_database,
)

DEFAULT_DB_PATH = os.path.expanduser("~/Library/Application Support/TimeFlip/appdata.sqlite")

# A fixed pause before each step, so the app/device settles between steps (see run_checklist).
STEP_PAUSE_SECONDS = 2.0


def _checklist_id(path):
    """The leading token of the filename, e.g. "01b" from "01b-history-refresh-checklist.md"."""
    return os.path.basename(path).split("-", 1)[0]


def _checklist_name(path):
    """The checklist's spoken name, from its filename -- e.g.
    "01b-history-refresh-checklist.md" -> "01b history refresh checklist"."""
    return os.path.basename(path).removesuffix(".md").replace("-", " ")


def _display_name(path):
    """The checklist's console name: the leading id token as-is, the rest sentence-cased --
    "00-test-setup.md" -> "00 Test setup", "01b-history-refresh-checklist.md" -> "01b History
    refresh checklist"."""
    stem = os.path.basename(path).removesuffix(".md")
    ident, _, rest = stem.partition("-")
    words = rest.replace("-", " ").strip()
    return f"{ident} {words[:1].upper()}{words[1:]}" if words else ident


def _log_path(path):
    """Path shown in a log heading: relative to the `Tests/` dir (folder + filename), not the
    full absolute path -- e.g. "00-test-setup.md", "Bench/01b-history-refresh-checklist.md"."""
    norm = path.replace(os.sep, "/")
    parts = norm.split("/Tests/")
    return parts[-1] if len(parts) > 1 else os.path.basename(path)




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
    """Raised to end the whole run immediately (not just the current checklist) -- used by -sf
    when a step fails, so a mis-run can be investigated before it cascades into later
    steps/checklists. Carries a short reason for the log/console."""


def _result_lines(result):
    """The console lines for a finished step's result.

    A pass echoes only the value it read, or nothing at all when the step just *did* something:
        -> PASS: 2059
        -> PASS
    A failure puts the two halves a reader wants on their own lines:
        -> FAIL:
        Expected: 67
        Result: Yep
    A failure with nothing to compare (a shell command's non-zero exit, an exception) has no
    Expected, so it reports what came back on the one line instead: `-> FAIL: exit=1`."""
    if result.success:
        return [f"-> PASS: {result.value}" if result.value else "-> PASS"]
    if result.expected is None:
        return [f"-> FAIL: {result.detail}"]
    return ["-> FAIL:", f"Expected: {result.expected}", f"Result: {result.actual}"]


def _skip_rest_of_scenario(failed_step, checklist, log_lines, skipped_prose):
    """Skip (don't run, leave unticked) every remaining step in the failed step's scenario. Later
    steps in a scenario assume the earlier ones passed -- step 1 relies on the scenario's
    preconditions, step 25 on steps 1-24 -- so once one fails the rest can't be trusted. They're
    logged as SKIP and left unticked, so a resume restarts the whole scenario from its first step."""
    for s in checklist.steps:
        if s.section == failed_step.section and not s.checked and s.prose not in skipped_prose:
            skipped_prose.add(s.prose)
            log_lines.append(
                f"Step {s.number}: SKIP - {s.description()} "
                f"(scenario '{s.section}' halted by an earlier failure)"
            )


def _handle_failure(path, step, checklist, log_lines, skipped_prose, reason, stop_on_failure):
    """Unified failure path. The step is logged as failed and left unticked, then the REST of its
    scenario is skipped (see _skip_rest_of_scenario) and the run carries on with the NEXT scenario.
    Exception: -sf halts the whole run immediately, raising _RunHalted so a mis-run can be
    investigated before end-of-run cleanup."""
    checklist.mark(step, False)
    checklist.save()
    skipped_prose.add(step.prose)
    note = _note_id(path, step)
    log_lines.append(f"FAILURE LOGGED: {note} -- {reason}")
    if stop_on_failure:
        raise _RunHalted(f"{note}: {reason}")
    _skip_rest_of_scenario(step, checklist, log_lines, skipped_prose)


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


def prompt_ts(options_text):
    """Loop-until-valid t/s question for the mid-run restart decision: `t` = restart from the
    top, `s` = restart from the current scenario. `options_text` is the two labelled `[t]`/`[s]`
    lines (printed once); then it loops on `>>> t/s:` until a valid answer."""
    print(options_text)
    while True:
        answer = input(">>> t/s: ").strip().lower()
        if answer == "t":
            return "t"
        if answer == "s":
            return "s"
        print("Not recognized -- please answer 't' or 's'.")


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
    """Names where a mid-run batch is up to -- the checklist, the section+step, and the full
    step text -- instead of dumping every requested checklist and its counts."""
    last, nxt = _resume_point(checklist_paths)
    if nxt is None:
        return
    np, ns = nxt
    name = _checklist_name(np)
    pos = f"{ns.section} Step {ns.number}"
    desc = ns.description()
    if last is None:
        # Nothing ticked yet -- a fresh batch, not an interrupted one.
        print(f"\nStarting '{name}' from the top: '{pos}' which is '{desc}'")
        log_lines.append(f"Resume; fresh start at {name} / {pos}: {desc}")
    else:
        print(f"\nThe test run did not complete, '{name}' the test is up to '{pos}' which is '{desc}'")
        log_lines.append(f"Resume; did not complete: {name} / {pos}: {desc}")


def _clear_from_current_scenario(checklist_paths, log_lines):
    """Restart the CURRENT scenario: keep every completed scenario (and every earlier checklist)
    ticked, but clear the current scenario's steps and everything after them, so the run re-enters
    at that scenario's Step 1. A scenario is the atomic resume unit -- its steps assume state its
    preconditions + earlier steps established, so you re-run the whole scenario, never a mid-point."""
    _, nxt = _resume_point(checklist_paths)
    if nxt is None:
        return
    np, ns = nxt
    idx = checklist_paths.index(np)
    # In the checklist we're up to: clear from the first step of the current scenario onward.
    c = Checklist(np)
    first = next((s for s in c.steps if s.section == ns.section), None)
    if first is not None:
        c.clear_from(first.checkbox_line)
        c.save()
    # Every later checklist hasn't run under a clean resume, but clear defensively so a stray tick
    # can't make one look already-done.
    for p in checklist_paths[idx + 1:]:
        later = Checklist(p)
        later.clear_checkboxes()
        later.save()
    log_lines.append(
        f"Resume: restart from scenario '{ns.section}' in {_checklist_name(np)} "
        "(earlier scenarios kept ticked)"
    )


def resolve_rerun_state(checklist_paths, log_lines, auto_yes):
    """Whole-batch, up-front check: if every requested checklist is already fully ticked,
    offer to clear them all and run again; otherwise (any checklist partially or entirely
    unticked) show where we left off and what's next, and offer to resume -- clearing the
    whole batch and starting over if the developer declines. Returns one of: None (nothing
    to run), "fresh" (run from a clean, freshly-wiped test DB), or "resume" (a `s` restart of
    the current scenario -- the existing test DB must be preserved so earlier scenarios' state
    survives)."""
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
            return None
        for p, _, _ in infos:
            c = Checklist(p)
            c.clear_checkboxes()
            c.save()
        return "fresh"

    _print_resume_location(checklist_paths, log_lines)
    # A completely fresh batch (nothing ticked anywhere) has nothing to restart -- "top" and
    # "current scenario" both just mean "run from the first step". Skip the prompt entirely;
    # only ask when there's genuine partial progress to either keep or discard.
    if all(done == 0 for _, done, _ in infos):
        return "fresh"
    if auto_yes:
        print("(--yes passed: restarting from the top)")
        choice = "t"
    else:
        _, nxt = _resume_point(checklist_paths)
        where = f"{_checklist_id(nxt[0])} {nxt[1].section}" if nxt else "the current scenario"
        choice = prompt_ts(
            "\n[t] Restart from the top and run all tests"
            f"\n[s] Restart from test {where}"
        )
    log_lines.append(f"Requested checklists mid-run; restart choice: {choice!r}")
    if choice == "t":
        for p, _, _ in infos:
            c = Checklist(p)
            c.clear_checkboxes()
            c.save()
        return "fresh"
    # "s" -- restart the current scenario, keep everything before it AND keep the test DB, so the
    # state those earlier scenarios established isn't wiped out from under the resumed scenario.
    _clear_from_current_scenario(checklist_paths, log_lines)
    return "resume"


def run_checklist(path, db_path, log_lines, auto_yes=False, remembered=None,
                  initial_vars=None, stop_on_failure=False, methods=None):
    checklist = Checklist(path)
    methods = methods if methods is not None else {}
    log_lines.append(f"\n=== {_log_path(path)} ===")

    # `test` names this checklist for the remembered-values tree (run -> test -> scenario ->
    # values); `section` is set per step below. Together they let a capture be recorded under its
    # scenario, and a resumed later scenario look a previous scenario's value back up.
    ctx = {"db_path": db_path, "vars": dict(initial_vars or {}), "remembered": remembered,
           "test": os.path.basename(path)}
    all_ok = True
    ran_any = False
    last_section = None  # so each section's name is logged once, as a sub-heading above its steps
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
        # A fixed beat before every step (even after a step that already waited on the DB), so the
        # app/device has a moment to settle before the next one runs.
        time.sleep(STEP_PAUSE_SECONDS)
        ran_any = True
        # Log the section name once, as a sub-heading, when it changes -- so step lines below can
        # stay short ("Step N: ...") and still be unambiguous.
        if step.section != last_section:
            log_lines.append(f"\n{step.section}")
            last_section = step.section
        actor_tag = "(You) " if step.actor == "you" else ""
        # Console header: "(01b History refresh checklist) Scenario A - Step 3: <instruction>".
        # The instruction is the step's FIRST line in the .md (see Step.description) -- the short
        # imperative sentence -- not the rationale/detail that follows it on the wrapped lines.
        # The log uses the shorter "Step N: STATUS ..." form (section is the sub-heading above).
        desc = step.description()
        print(f"\n({_display_name(path)}) {actor_tag}{step.section} - Step {step.number}: {desc}")

        # Which scenario this step is in (for recording captures under it), and -- for a resume
        # that skipped earlier scenarios -- fill any $var this step needs that an earlier scenario
        # captured, from logs/00-remembered.json. Both no-op for a spec-less (human) step.
        ctx["section"] = step.section
        # Expand any `use = "method-N"` against Tests/Methods.md first, so a shared body's own
        # `$vars` are in the spec before the remembered-value fill and the run see it.
        spec = resolve_uses(step.spec, methods)
        resolve_missing_vars_from_remembered(spec, ctx)

        if spec is None:
            if auto_yes:
                # --yes/non-interactive: there's no human to ask, and this step needs one
                # (no toml to automate it) -- record it as a skip rather than block on input.
                print("-> SKIP: needs human verification; --yes/non-interactive can't ask.")
                log_lines.append(f"Step {step.number}: SKIP - {desc} (needs human; --yes)")
                all_ok = False
                skipped_prose.add(step.prose)
                continue
            # No toml to automate this, so a human has to look (e.g. a screenshot / visual
            # confirmation). Ask -- never silently skip. The question is phrased so Y =
            # passed/continue. (The switch-to-test setup is done by Tests/00-test-setup.md, so
            # there are no auto-ticked Setup steps here any more.)
            print_action_required("Verify the step above against the app/device, then answer below.")
            passed = prompt_yn(f"{_note_id(path, step)}: Did this check pass?")
            if passed:
                checklist.mark(step, True)
                checklist.save()
                log_lines.append(f"Step {step.number}: PASS - {desc} (human-verified)")
                continue
            log_lines.append(f"Step {step.number}: FAIL - {desc} (human-verified)")
            all_ok = False
            _handle_failure(path, step, checklist, log_lines, skipped_prose,
                            "human-verified step did not pass", stop_on_failure)
            continue

        # Optional `when` guard: a step only applies under some condition on a captured var
        # (e.g. "flip to build history" only `when $start_event_id < 10`). If the guard isn't
        # met the step isn't needed -- tick it and move on without running or asking.
        cond = spec.get("when")
        if cond is not None and not condition_met(cond, ctx):
            print(f"-> SKIP: not needed (when {cond})")
            log_lines.append(f"Step {step.number}: SKIP - {desc} (when {cond} not met)")
            checklist.mark(step, True)
            checklist.save()
            continue

        # `current_log_id` is refreshed to the live MAX(debug_log_id) of the CURRENT db right
        # before every step. A step scopes detection on `debug_log_id > $current_log_id` to mean
        # "a row THIS step produced"; re-reading it each step means a later step can't match a
        # stale row from earlier in the run. Crucially it is RE-READ, not carried: a mid-run
        # switch to a fresh file (whose ids restart at 1) resets it to that file's small max,
        # rather than keeping the old file's large id (e.g. prod's ~34k, which the tiny test
        # sequence would take ages to exceed). It's same-step only; a wait that must reach back
        # across several steps captures its own named baseline instead (e.g. `before_reset_id`).
        # A just-created db may not have the table yet -> treat as 0 (matches everything, safe).
        try:
            ctx["vars"]["current_log_id"] = _latest_debug_log_id(os.path.realpath(ctx["db_path"]))
        except Exception:  # noqa: BLE001 -- a transient read must not crash the run
            ctx["vars"]["current_log_id"] = 0
        result = run_step(spec, ctx)
        # A pass shows only what it *read* -- "-> PASS: 2059", or a bare "-> PASS" for a step that
        # just does something (click, quit, sleep). A fail splits the comparison over its own
        # "Expected:"/"Result:" lines, falling back to the raw detail when nothing was asserted
        # (a shell command's non-zero exit, an exception).
        print("\n".join(_result_lines(result)))
        # The log mirrors that: a pass that got what it expected needs no detail (the tick + PASS
        # is enough), a fail records the comparison. (Captured values aren't logged here; they're
        # recorded in logs/00-remembered.json.)
        if result.success:
            log_lines.append(f"Step {step.number}: PASS - {desc}")
        else:
            log_lines.append(f"Step {step.number}: FAIL - {desc}")
            if result.expected is not None:
                log_lines.append(f"  - Expected: {result.expected}")
                log_lines.append(f"  - Result: {result.actual}")
            else:
                log_lines.append(f"  - Result: {result.detail}")

        if result.success:
            checklist.mark(step, True)
            checklist.save()
            continue

        # Failed step: log it, skip the rest of its scenario, carry on with the next scenario
        # (or halt, under -sf).
        all_ok = False
        _handle_failure(path, step, checklist, log_lines, skipped_prose,
                        f"step failed: {result.detail}", stop_on_failure)
        continue

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
        "-sf", "--stop-on-failure",
        action="store_true",
        help="Stop the whole run on the first failed step. The default instead skips the rest of "
        "that step's scenario (later steps in a scenario assume the earlier ones passed) and "
        "carries on with the next scenario. With -sf the run halts for investigation and "
        "end-of-run cleanup is skipped so the state can be inspected.",
    )
    args = parser.parse_args()
    stop_on_failure = args.stop_on_failure

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
    log_lines.extend(f"  {_log_path(p)}" for p in checklist_paths)

    # Side-record of values read (recorded) and settings changed (changed, with live current)
    # this run, keyed by the same timestamp as the .txt log. Populated live as steps capture.
    remembered = Remembered(os.path.join(log_dir, "00-remembered.json"), timestamp)

    # The shared step bodies every checklist's `use = "method-N"` refers to. Loaded once, up front,
    # so a typo in Methods.md fails the run here rather than mid-way through a device test.
    try:
        methods = load_methods(methods_path(repo_root))
    except (OSError, ValueError) as e:
        print(f"error: {e}")
        log_lines.append(f"ABORTED: {e}")
        sys.exit(1)
    log_lines.append(f"Shared methods loaded: {', '.join(sorted(methods))}")

    # First thing, before we ask the developer anything: if we're still on production and
    # the device is mid-timing a real activity, bail immediately rather than after they've
    # answered the rerun/resume and confirmation prompts. This run switches to test and
    # factory-resets the device at the end, which would interrupt that real timing event.
    if not ensure_not_timing_on_production(args.db_path):
        print("\nAborted -- pause the device, then re-run.")
        log_lines.append("ABORTED: on production and device is mid-timing; developer must pause first.")
        sys.exit(1)

    run_mode = resolve_rerun_state(checklist_paths, log_lines, args.yes)
    if run_mode is None:
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
        # Always run the shared setup first, whatever subset was requested (Bench, Interactive, a
        # single file) -- it switches to the test database and confirms the device is connected.
        # Its boxes are cleared so it re-runs every time; a failure here aborts before any feature
        # checklist. On a "resume" it runs in keep mode (see below) so it doesn't wipe the test DB.
        setup = Checklist(setup_path)
        setup.clear_checkboxes()
        setup.save()
        log_lines.append("\n--- Test setup (00-test-setup.md), always run first ---")
        # The setup builds up >=10 device events only when a history-refresh checklist (01b/01i)
        # is in this run -- other features (LED, battery, ...) don't need the history, so they
        # aren't forced to flip. The setup reads this via a `when` guard on that build step.
        needs_history = "y" if any(
            os.path.basename(p).startswith(("01b", "01i")) for p in checklist_paths
        ) else "n"
        # On a "resume" (`s`), keep the existing test DB and skip the production-history recording:
        # earlier scenarios' state must survive, and we're already on test. On a fresh run, wipe and
        # rebuild it. `db_mode` is passed straight to use-test-database.sh; `resume` gates the
        # production round-trip prompt in Step 1.
        resume = "y" if run_mode == "resume" else "n"
        db_mode = "keep" if run_mode == "resume" else "fresh"
        if not run_checklist(setup_path, db_path, log_lines, args.yes, remembered,
                             initial_vars={"needs_history": needs_history,
                                           "resume": resume, "db_mode": db_mode},
                             methods=methods):
            print("\nAborted -- test setup failed; not running any checklists.")
            log_lines.append("ABORTED: test setup failed.")
            sys.exit(1)

        for path in checklist_paths:
            # Every feature checklist needs a live, connected device. If it isn't (e.g. a failed
            # re-pair in 02b left it forgotten), stop rather than churn through the remaining
            # checklists' device-independent steps against a device that isn't there.
            if not device_appears_connected(db_path):
                msg = (f"device not connected before {_log_path(path)} -- aborting the remaining "
                       "checklists (they all need a live device)")
                print(f"\n!!! {msg}")
                log_lines.append(f"ABORTED: {msg}")
                overall_ok = False
                break
            ok = run_checklist(path, db_path, log_lines, args.yes, remembered,
                               stop_on_failure=stop_on_failure, methods=methods)
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
