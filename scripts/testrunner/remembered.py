"""The `capture =` values a resume needs, in `logs/testruns.sqlite`'s `captured_value` table.

These used to live in `logs/00-remembered.json`, as a tree **run -> test -> scenario ->
{capture: value}**. They are rows now, in the same database the runner already writes each
step's reading to (`run_record.py`), because they are the same kind of thing -- a per-run record
keyed by run stamp, checklist and scenario -- and keeping one store instead of two means one
schema, one place to query, and no chance of the two disagreeing about what a run captured.

The reason these exist at all is **resume**. When a run is resumed from a later scenario, the
skipped earlier scenarios never re-run, so their `$vars` aren't in the live context. `lookup()`
recovers them, searching newest run first, so a value the interrupted prior run captured is
still found (see `RunRecord.lookup_capture` for the exact ordering, which reproduces what the
JSON tree did).

This class is a thin adapter kept for the call sites in `actions.py`
(`_remember_capture`/`resolve_missing_vars_from_remembered`), which know it as `ctx["remembered"]`
and use only `record`/`lookup`/`flush`.
"""


class Remembered:
    def __init__(self, run_record):
        self._run_record = run_record

    def record(self, test, section, capture_name, value):
        """Store one captured value under this run, checklist and scenario. A later capture of
        the same name in the same scenario overwrites (last write wins)."""
        if not capture_name:
            return
        self._run_record.record_capture(test, section, capture_name, value)

    def lookup(self, test, capture_name):
        """Resume helper: `capture_name`'s value for `test`, or None if nothing recorded it."""
        return self._run_record.lookup_capture(test, capture_name)

    def flush(self, *_):
        """No-op. Every write is already committed by `RunRecord` as it happens -- the JSON file
        this replaced needed an explicit rewrite, a database doesn't. Kept so any caller still
        holding the old contract doesn't break."""
