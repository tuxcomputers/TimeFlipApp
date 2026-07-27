"""`logs/00-remembered.json` -- a per-run record of the values the runner captures.

The tree is **run -> test -> scenario -> {capture: value}**:

```json
{
  "2026-07-26_10.30.00": {
    "07b-battery-low-indicator-checklist.md": {
      "Scenario A": { "threshold_original": "{\"percent\":5}" },
      "Scenario C": { "battery_level_c": 14 }
    }
  }
}
```

- The top key is the run's log-file stamp (the same `YYYY-MM-DD_hh.mm.ss` the `.txt` transcript
  uses), so a JSON entry ties back to its log. Runs accumulate: each new run adds its own key.
- Under it, one node per **test** (the checklist filename), then one per **scenario** (the `##`
  section), then that scenario's captured `capture = ` values by name.

This is written so a **resume** can recover a value a *previous* scenario captured. When the run is
resumed from a later scenario, the skipped earlier scenarios never re-run, so their `$vars` aren't
in the live context -- `lookup()` walks this tree (newest run first) to supply them (see
`Remembered.lookup`). The file is rewritten after every capture, so an interrupted run still leaves
a complete-so-far record.
"""
import json
import os


class Remembered:
    def __init__(self, path, run_key):
        self.path = path
        self.run_key = run_key
        self._doc = self._load()

    def _load(self):
        """Prior runs' entries, so we add this run's key rather than clobber the file."""
        if os.path.exists(self.path):
            try:
                with open(self.path) as f:
                    doc = json.load(f)
                if isinstance(doc, dict):
                    return doc
            except (json.JSONDecodeError, OSError):
                pass
        return {}

    def record(self, test, section, capture_name, value):
        """Store one captured value under run -> test -> scenario -> {capture: value}, then flush.
        A later capture of the same name in the same scenario overwrites (last write wins)."""
        if not capture_name:
            return
        run = self._doc.setdefault(self.run_key, {})
        run.setdefault(test, {}).setdefault(section, {})[capture_name] = value
        self.flush()

    def lookup(self, test, capture_name):
        """Resume helper: return `capture_name`'s value for `test`, searching runs newest-first
        and, within a run, that test's scenarios -- so a value a previous scenario recorded (this
        run or the interrupted prior run) is found when a later scenario needs it. The current run
        is newest, but on a scenario resume it won't hold a skipped scenario's capture, so the
        search falls through to the interrupted prior run that did. Returns None if nothing has
        recorded it."""
        for stamp in sorted(self._doc, reverse=True):
            test_node = self._doc[stamp].get(test)
            if not isinstance(test_node, dict):
                continue
            for section_values in test_node.values():
                if isinstance(section_values, dict) and capture_name in section_values:
                    return section_values[capture_name]
        return None

    def flush(self, *_):
        tmp = self.path + ".tmp"
        try:
            with open(tmp, "w") as f:
                json.dump(self._doc, f, indent=2)
                f.write("\n")
            os.replace(tmp, self.path)
        except OSError:
            # A device test must not die because the side-record couldn't be written.
            pass
