"""Parses a Tests/Bench|Interactive checklist .md into executable Step objects, and
writes results back as normal checkbox ticks + an auto-generated confirmation note --
the same convention a human/Claude run already uses, so a converted file still reads
like a normal checklist.

Each checklist item is a `- [ ]`/`- [x]` line, optionally followed by a fenced
```toml step ... ``` block holding that step's executable spec (see actions.py for the
action vocabulary). A step with no such block is documentation-only -- e.g. an
already-answered "Preconditions" note -- and the runner skips it rather than guessing.
"""

import re
import tomllib
from dataclasses import dataclass
from typing import Optional

CHECKBOX_RE = re.compile(r"^(\s*)- \[( |x)\](.*)$")
FENCE_START_RE = re.compile(r"^```toml step\s*$")
FENCE_END_RE = re.compile(r"^```\s*$")
HEADING_RE = re.compile(r"^#+\s")
NOTE_RE = re.compile(r"^\s*\((?:Automated|AUTOMATED FAILURE): .*\)\s*$")


@dataclass
class Step:
    checkbox_line: int
    checked: bool
    actor: str
    prose: str
    spec: Optional[dict]
    note_insert_line: int
    note_indent: str


class Checklist:
    def __init__(self, path):
        self.path = path
        with open(path, "r") as f:
            self.lines = f.read().splitlines()
        self.steps = self._parse()

    def _parse(self):
        steps = []
        lines = self.lines
        n = len(lines)
        i = 0
        while i < n:
            m = CHECKBOX_RE.match(lines[i])
            if not m:
                i += 1
                continue
            indent, mark, rest = m.groups()
            checked = mark == "x"
            actor = "you" if "**(You)**" in rest else "claude"
            checkbox_line = i

            j = i + 1
            fence_start = None
            fence_end = None
            last_body_line = i
            while j < n:
                line = lines[j]
                if CHECKBOX_RE.match(line) or HEADING_RE.match(line):
                    break
                if FENCE_START_RE.match(line.strip()):
                    fence_start = j
                    k = j + 1
                    while k < n and not FENCE_END_RE.match(lines[k].strip()):
                        k += 1
                    fence_end = k
                    j = fence_end + 1
                    break
                if line.strip() != "":
                    last_body_line = j
                j += 1

            spec = None
            if fence_start is not None:
                toml_text = "\n".join(lines[fence_start + 1 : fence_end])
                try:
                    spec = tomllib.loads(toml_text)
                except Exception as e:
                    raise ValueError(f"{self.path}: bad TOML step block near line {fence_start + 1}: {e}") from e
                note_insert_line = fence_start
                end_of_item = fence_end
            else:
                note_insert_line = last_body_line + 1
                end_of_item = last_body_line

            steps.append(
                Step(
                    checkbox_line=checkbox_line,
                    checked=checked,
                    actor=actor,
                    prose=rest.strip(),
                    spec=spec,
                    note_insert_line=note_insert_line,
                    note_indent=indent + "      ",
                )
            )
            i = end_of_item + 1
        return steps

    def mark(self, step: Step, success: bool, note: str):
        """Flip the checkbox and insert an auto-generated confirmation/failure note,
        then re-parse (simplest way to keep every other step's line numbers correct)."""
        line = self.lines[step.checkbox_line]
        m = CHECKBOX_RE.match(line)
        indent, _, rest = m.groups()
        new_mark = "x" if success else " "
        self.lines[step.checkbox_line] = f"{indent}- [{new_mark}]{rest}"

        prefix = "Automated" if success else "AUTOMATED FAILURE"
        note_line = f"{step.note_indent}({prefix}: {note})"
        self.lines.insert(step.note_insert_line, note_line)
        self.steps = self._parse()

    def clear_checkboxes(self):
        """Reset every checkbox back to unchecked and drop any auto-generated
        (Automated: ...)/(AUTOMATED FAILURE: ...) notes from a previous run -- used for
        a deliberate rerun-from-scratch, so the next run's notes don't pile up alongside
        stale ones. Call save() afterward to persist."""
        new_lines = []
        for line in self.lines:
            if NOTE_RE.match(line):
                continue
            m = CHECKBOX_RE.match(line)
            if m:
                indent, _, rest = m.groups()
                line = f"{indent}- [ ]{rest}"
            new_lines.append(line)
        self.lines = new_lines
        self.steps = self._parse()

    def save(self):
        with open(self.path, "w") as f:
            f.write("\n".join(self.lines) + "\n")
