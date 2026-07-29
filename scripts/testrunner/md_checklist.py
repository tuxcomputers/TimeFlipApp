"""Parses a Tests/Bench|Interactive checklist .md into executable Step objects, and
writes results back as plain checkbox ticks -- the same convention a human/Claude run
already uses, so a converted file still reads like a normal checklist.

Each checklist item is a `- [ ]`/`- [x]` line, optionally prefixed with a `Step N:`
number and followed by a fenced ```toml step ... ``` block holding that step's executable
spec (see actions.py for the action vocabulary). A step with no such block is
documentation-only -- e.g. an already-answered "Preconditions" note -- and the runner
skips it rather than guessing.

Run output (pass/fail detail, captured values) goes to the log file, not back into the
.md: a tick is the only per-step record kept in the checklist itself.
"""

import re
import tomllib
from dataclasses import dataclass
from typing import Optional

CHECKBOX_RE = re.compile(r"^(\s*)- \[( |x)\](.*)$")
FENCE_START_RE = re.compile(r"^```toml step\s*$")
FENCE_END_RE = re.compile(r"^```\s*$")
HEADING_RE = re.compile(r"^#+\s")
SECTION_RE = re.compile(r"^##\s+(.*)$")  # level-2 heading = a section (Setup / Scenario X)
NOTE_RE = re.compile(r"^\s*\((?:Automated|AUTOMATED FAILURE): .*\)\s*$")

_ACTOR_RE = re.compile(r"^\*\*\((?:You|Claude)\)\*\*\s*")
_STEP_NUM_RE = re.compile(r"^Step\s+\d+:\s*")
_METHOD_RE = re.compile(r"\s*(?:--\s*)?Methods?:\s", re.IGNORECASE)  # "Method: X" or "Methods: X, Y"
_ASIDE_RE = re.compile(r"\s+(?:--|—)\s")  # " -- "/" — " introduces rationale/an aside


def _clean_section(text):
    """The short section label from a `## ` heading -- "Scenario B" from
    "Scenario B -- quit and relaunch ...", "Setup" from "Setup"."""
    text = text.strip()
    for sep in (" -- ", " — ", " – "):
        if sep in text:
            text = text.split(sep)[0]
            break
    return text.strip()


def _balanced(text):
    """Does this fragment close everything it opens -- parentheses, a `code span`, **bold**, a
    "quoted log message"? Used to reject a cut that would strand an opener mid-phrase."""
    return (text.count("(") == text.count(")") and text.count("`") % 2 == 0
            and text.count("**") % 2 == 0 and text.count('"') % 2 == 0)


@dataclass
class Step:
    checkbox_line: int
    checked: bool
    actor: str
    prose: str  # first-line text after the checkbox (used for the run print and dedup)
    spec: Optional[dict]
    section: str  # cleaned `## ` heading this step falls under ("Setup", "Scenario A", ...)
    number: int  # 1-based ordinal within `section`
    full_text: str  # prose joined across wrapped continuation lines (excludes the toml block)

    def description(self, maxlen=None):
        """A human instruction for prompts/logs: the step's FIRST line in the .md, with the actor
        label and `Step N:` prefix stripped and any `Method:` reference cut off. Deliberately the
        first line only, not `full_text`: by convention that line is the short imperative sentence
        ("Quit the app.") and the wrapped lines after it are rationale/caveats, which belong in the
        file for a reader but would bury the instruction in a one-line console/log entry. Full
        length by default -- pass `maxlen` to cap it with an ellipsis."""
        t = _ACTOR_RE.sub("", self.prose.strip())
        t = _STEP_NUM_RE.sub("", t)
        # Cut at the first Method reference or " -- "/" — " aside -- both introduce rationale
        # rather than instruction -- but only where the cut is *balanced*, since one inside a
        # parenthetical/code span/quoted message would strand its opener ("...(before the
        # debounce elapses"). A trailing parenthetical is kept: on a first line it qualifies the
        # instruction ("(`finalised=0`)", "(call it C)") rather than recording a run's result.
        cuts = sorted(m.start() for m in _METHOD_RE.finditer(t))
        cuts += sorted(m.start() for m in _ASIDE_RE.finditer(t))
        cut = next((c for c in sorted(cuts) if _balanced(t[:c])), None)
        if cut is not None:
            t = t[:cut]
        t = " ".join(t.split())
        # Cutting just before a "([Method ...])" / "[Method ...]" reference can strand the
        # link/paren opener that introduced it (e.g. "...reconnects ([" or "...open. ["); drop
        # a trailing run of "(" / "[" and the punctuation leading into it. No-op when the text
        # doesn't end in a stray opener.
        t = re.sub(r"[\s.,;:]*[([]+$", "", t)
        # The first line is a whole sentence, so its full stop is kept (only stray trailing
        # whitespace goes) -- unlike the old full_text form, which was cut mid-sentence.
        t = t.rstrip()
        if maxlen is not None and len(t) > maxlen:
            t = t[: maxlen - 1].rstrip() + "…"
        return t


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
        section = ""
        section_step_no = 0
        while i < n:
            sec = SECTION_RE.match(lines[i])
            if sec:
                section = _clean_section(sec.group(1))
                section_step_no = 0
                i += 1
                continue
            m = CHECKBOX_RE.match(lines[i])
            if not m:
                i += 1
                continue
            indent, mark, rest = m.groups()
            checked = mark == "x"
            actor = "you" if "**(You)**" in rest else "claude"
            checkbox_line = i
            section_step_no += 1

            body_parts = [rest.strip()]
            j = i + 1
            fence_start = None
            fence_end = None
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
                    body_parts.append(line.strip())
                j += 1

            spec = None
            if fence_start is not None:
                toml_text = "\n".join(lines[fence_start + 1 : fence_end])
                try:
                    spec = tomllib.loads(toml_text)
                except Exception as e:
                    raise ValueError(f"{self.path}: bad TOML step block near line {fence_start + 1}: {e}") from e
                end_of_item = fence_end
            else:
                end_of_item = j - 1

            steps.append(
                Step(
                    checkbox_line=checkbox_line,
                    checked=checked,
                    actor=actor,
                    prose=rest.strip(),
                    spec=spec,
                    section=section,
                    number=section_step_no,
                    full_text=" ".join(body_parts).strip(),
                )
            )
            i = end_of_item + 1
        return steps

    def mark(self, step: Step, success: bool):
        """Flip the checkbox only -- the tick is the sole per-step record kept in the
        .md; pass/fail detail and captured values are logged instead (see supervisor).
        Re-parses so every other step's line numbers stay correct."""
        line = self.lines[step.checkbox_line]
        m = CHECKBOX_RE.match(line)
        indent, _, rest = m.groups()
        new_mark = "x" if success else " "
        self.lines[step.checkbox_line] = f"{indent}- [{new_mark}]{rest}"
        self.steps = self._parse()

    def clear_from(self, checkbox_line):
        """Uncheck every checkbox at or after line `checkbox_line` (dropping any legacy
        auto-notes from there on), leaving earlier boxes exactly as they are. Used by a
        resume that restarts only the current scenario onward while keeping already-completed
        scenarios ticked. Call save() afterward to persist."""
        new_lines = []
        for idx, line in enumerate(self.lines):
            if idx >= checkbox_line:
                if NOTE_RE.match(line):
                    continue
                m = CHECKBOX_RE.match(line)
                if m:
                    indent, _, rest = m.groups()
                    line = f"{indent}- [ ]{rest}"
            new_lines.append(line)
        self.lines = new_lines
        self.steps = self._parse()

    def clear_checkboxes(self):
        """Reset every checkbox back to unchecked and drop any legacy auto-generated
        (Automated: ...)/(AUTOMATED FAILURE: ...) notes a previous run may have left --
        used for a deliberate rerun-from-scratch. Call save() afterward to persist."""
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
