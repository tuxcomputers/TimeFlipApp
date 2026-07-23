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
_METHOD_RE = re.compile(r"\s*(?:--\s*)?Method:\s", re.IGNORECASE)
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


def _strip_trailing_paren(text):
    """Drop a single trailing parenthetical (an evidence note like "(Confirmed: ...)" or
    "(event_number=13, ...)"), leaving mid-sentence parens intact."""
    text = text.rstrip()
    if not text.endswith(")"):
        return text
    depth = 0
    for k in range(len(text) - 1, -1, -1):
        if text[k] == ")":
            depth += 1
        elif text[k] == "(":
            depth -= 1
            if depth == 0:
                return text[:k].rstrip()
    return text


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
        """A human instruction for prompts: actor label and `Step N:` prefix stripped, cut at
        `Method:` (or the trailing evidence note when there's no Method), wrapped lines
        collapsed onto one line. Full length by default -- pass `maxlen` to cap it with an
        ellipsis (callers generally don't; the terminal can take the whole line)."""
        t = _ACTOR_RE.sub("", self.full_text.strip())
        t = _STEP_NUM_RE.sub("", t)
        # Drop a trailing evidence parenthetical first (so a " -- " inside that note can't be
        # mistaken for an aside), then cut at the first Method note or " -- "/" — " aside --
        # both introduce rationale rather than instruction.
        t = _strip_trailing_paren(t)
        cuts = [m.start() for m in (_METHOD_RE.search(t), _ASIDE_RE.search(t)) if m]
        if cuts:
            t = t[: min(cuts)]
        t = " ".join(t.split()).rstrip(" .")
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
