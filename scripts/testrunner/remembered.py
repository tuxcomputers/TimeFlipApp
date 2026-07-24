"""`logs/00-remembered.json` -- a per-run record of the values the runner reads and changes.

Keyed by the run's log-file stamp (the same `YYYY-MM-DD_hh.mm.ss` the `.txt` transcript uses),
so a JSON entry ties back to its log. Under each run key sit two arrays:

- `changed`  -- settings the run mutates and must put back, each `{key, original, current}`.
                `original` is the value captured before the run touched it; `current` is re-read
                live from the DB on every write, so it tracks the setting as the script
                progresses (change it, restore it, and `current` follows).
- `recorded` -- values the run reads for verification, each `{key, value}`.

A capture lands in `changed` only when its step is marked `remember = "changed"` (with
`restores = "<setting_name>"` naming the row whose live value is `current`); every other
`capture =` lands in `recorded`. The file is rewritten after each capture and after each
mutating `sql_exec` -- like the streaming `.txt` log, an interrupted run still leaves a
complete-so-far file. Runs accumulate: each new run adds its own top-level key, older keys stay.
"""
import json
import os
import sqlite3


class Remembered:
    def __init__(self, path, run_key):
        self.path = path
        self.run_key = run_key
        self.changed = []
        self.recorded = []
        self._doc = self._load()

    def _load(self):
        """Prior runs' entries, so we append this run's key rather than clobber the file."""
        if os.path.exists(self.path):
            try:
                with open(self.path) as f:
                    return json.load(f)
            except (json.JSONDecodeError, OSError):
                pass
        return {}

    def record_capture(self, spec, value, db_path):
        """Route one captured value into the right bucket, then flush."""
        if spec.get("remember") == "changed":
            key = spec.get("restores") or spec.get("capture")
            if key and not any(e["key"] == key for e in self.changed):
                self.changed.append({"key": key, "original": value, "current": value})
        elif "capture" in spec:
            self.recorded.append({"key": spec["capture"], "value": value})
        self.flush(db_path)

    def _refresh_current(self, db_path):
        """Re-read each changed setting's live value so `current` tracks the run."""
        for entry in self.changed:
            val = self._read_setting(db_path, entry["key"])
            if val is not None:
                entry["current"] = val

    @staticmethod
    def _read_setting(db_path, name):
        try:
            conn = sqlite3.connect(db_path)
            try:
                row = conn.execute(
                    "SELECT setting_value FROM setting WHERE setting_name = ?", (name,)
                ).fetchone()
            finally:
                conn.close()
            return row[0] if row else None
        except sqlite3.Error:
            return None

    def flush(self, db_path=None):
        if db_path:
            self._refresh_current(db_path)
        self._doc[self.run_key] = {"changed": self.changed, "recorded": self.recorded}
        tmp = self.path + ".tmp"
        try:
            with open(tmp, "w") as f:
                json.dump(self._doc, f, indent=2)
                f.write("\n")
            os.replace(tmp, self.path)
        except OSError:
            # A device test must not die because the side-record couldn't be written.
            pass
