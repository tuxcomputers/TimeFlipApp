#!/usr/bin/env python3
"""Maintains the two per-branch headings a checklist carries: `Last run` and `Bugs found and fixed`.

Both rules are in `Tests/CLAUDE.md`; this is the machinery, so a run does them rather than relying
on whoever is running it to remember. Two operations, deliberately separate because they happen at
different moments:

    sweep  --branch <b> <file>...   Clear the bug history of every listed file whose recorded
                                    branch is not <b>. Run once, over exactly the files this run
                                    will run.
    stamp  --branch <b> <file>      Set that file's `Last run` heading to now, on <b>. Run as the
                                    file is started, so a checklist that never runs keeps whatever
                                    the previous branch left.

The asymmetry matters. Bug entries belong to the branch that found them, so arriving on a new branch
retires them; but a checklist this run does not reach must keep both its heading and its bugs
untouched, which is why `stamp` is per file and never part of the sweep.

Only the files it is given are ever touched. There is no discovery here on purpose: the supervisor
already knows what it is going to run (`-f`/`-s`/explicit paths all narrow it), and a helper that
went looking for `Tests/**/*-checklist.md` itself would clear the history of files nobody asked for.
"""

import argparse
import datetime
import os
import re
import subprocess
import sys

# `### Last run - 2026-08-09 21:55 on the branch 'feature/manualMode'`, and the older date-only form
# it replaced, which is still what every file written before this carries.
LAST_RUN_RE = re.compile(
    r"^### Last run - (?P<when>\d{4}-\d{2}-\d{2}(?: \d{2}:\d{2})?) on the branch '(?P<branch>[^']*)'\s*$"
)
BUGS_HEADING_RE = re.compile(r"^### Bugs found and fixed\b")
# One line per bug, dated, per Tests/CLAUDE.md. Matching the date prefix rather than "everything
# until the next heading" is what keeps the removal from eating the checklist item that follows it:
# a bug section is written directly under the step that exposed it, often with no blank line between.
BUG_ENTRY_RE = re.compile(r"^\d{4}-\d{2}-\d{2} - ")


def current_branch(repo_root):
    """The branch the working tree is on, or None in a detached HEAD."""
    out = subprocess.run(
        ["git", "rev-parse", "--abbrev-ref", "HEAD"],
        cwd=repo_root, capture_output=True, text=True, check=False,
    )
    name = out.stdout.strip()
    if out.returncode != 0 or not name or name == "HEAD":
        return None
    return name


def _read(path):
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read().split("\n")


def _write(path, lines):
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines))


def recorded_branch(lines):
    """The branch named in the file's `Last run` heading, or None if it has never been run."""
    for line in lines[:12]:
        found = LAST_RUN_RE.match(line)
        if found:
            return found.group("branch")
    return None


def clear_bugs(lines):
    """Drop every `Bugs found and fixed` heading and the dated entries under it.

    Returns the surviving lines and how many entries went. A file can carry several sections, one
    per step that exposed something, so this is not a single-region edit.
    """
    kept = []
    removed = 0
    index = 0
    while index < len(lines):
        if BUGS_HEADING_RE.match(lines[index]):
            index += 1
            while index < len(lines) and BUG_ENTRY_RE.match(lines[index]):
                removed += 1
                index += 1
            # A blank line that only existed to separate the section from what follows would
            # otherwise double up with the one above it.
            if index < len(lines) and lines[index] == "" and kept and kept[-1] == "":
                index += 1
            continue
        kept.append(lines[index])
        index += 1
    return kept, removed


def stamp_last_run(lines, branch, when):
    """Set the `Last run` heading to `when` on `branch`, inserting it if the file has none.

    It belongs directly under the title, before any intro prose, so a file being stamped for the
    first time gets it there rather than wherever the first blank line happens to be.
    """
    heading = f"### Last run - {when} on the branch '{branch}'"
    for index, line in enumerate(lines[:12]):
        if LAST_RUN_RE.match(line):
            lines[index] = heading
            return lines, "updated"
    title = next((i for i, line in enumerate(lines) if line.startswith("# ")), None)
    if title is None:
        raise ValueError("no `# ` title to place the Last run heading under")
    lines[title + 1:title + 1] = ["", heading]
    # Whatever followed the title now follows the heading. That is usually the blank line the title
    # already had, and where it isn't -- a file whose prose starts immediately under the title --
    # the heading would otherwise run straight into the first paragraph.
    if title + 3 >= len(lines) or lines[title + 3] != "":
        lines.insert(title + 3, "")
    return lines, "inserted"


def stamp_file(path, branch, when=None):
    """Stamp one checklist's `Last run`. The supervisor's entry point, called as a file starts."""
    when = when or datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    lines, how = stamp_last_run(_read(path), branch, when)
    _write(path, lines)
    return when, how


def _sweep(args, repo_root):
    branch = args.branch or current_branch(repo_root)
    if not branch:
        print("checklist_header: cannot determine the branch (detached HEAD?); nothing swept.")
        return 0
    print(f"Checklist bug history: keeping entries from '{branch}', retiring the rest.")
    for path in args.files:
        name = os.path.relpath(path, repo_root)
        if not os.path.exists(path):
            print(f"  {name}: missing, skipped")
            continue
        lines = _read(path)
        was = recorded_branch(lines)
        if was is None:
            print(f"  {name}: never run, nothing to clear")
            continue
        if was == branch:
            print(f"  {name}: already on '{branch}', bug history kept")
            continue
        kept, removed = clear_bugs(lines)
        if removed:
            _write(path, kept)
        print(f"  {name}: last run on '{was}', cleared {removed} bug entr"
              f"{'y' if removed == 1 else 'ies'}")
    return 0


def _stamp(args, repo_root):
    branch = args.branch or current_branch(repo_root)
    if not branch:
        print("checklist_header: cannot determine the branch (detached HEAD?); not stamped.")
        return 0
    when = args.when or datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    lines = _read(args.file)
    lines, how = stamp_last_run(lines, branch, when)
    _write(args.file, lines)
    print(f"{os.path.relpath(args.file, repo_root)}: Last run {how} -- {when} on '{branch}'")
    return 0


def main():
    repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    parser = argparse.ArgumentParser(description=__doc__.split("\n", maxsplit=1)[0])
    sub = parser.add_subparsers(dest="command", required=True)

    sweep = sub.add_parser("sweep", help="clear bug history on files last run on another branch")
    sweep.add_argument("files", nargs="+")
    sweep.add_argument("--branch", default=None)

    stamp = sub.add_parser("stamp", help="set one file's Last run heading to now")
    stamp.add_argument("file")
    stamp.add_argument("--branch", default=None)
    stamp.add_argument("--when", default=None, help="override the timestamp, for tests")

    args = parser.parse_args()
    if args.command == "sweep":
        return _sweep(args, repo_root)
    return _stamp(args, repo_root)


if __name__ == "__main__":
    sys.exit(main())
