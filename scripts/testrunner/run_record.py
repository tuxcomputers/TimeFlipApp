"""`logs/testruns.sqlite` -- the runner's own database of what each run did.

Three tables, all keyed by `run_id` (the run's log-file stem, e.g. `2026-07-31_13.01.08`, the
same stamp `logs/<run_id>.txt` uses):

- `run` -- one row per run: when it started and finished, and how it ended.
- `step_value` -- one row per step that ran, with whatever it read. The console prints a bare
  `-> PASS`, so this is where the value goes.
- `captured_value` -- the `capture =` values a resume needs to recover, previously
  `logs/00-remembered.json`.

**Why its own database file rather than tables in the app's.** Three reasons, in order of how
much they'd hurt:

- `scripts/use-test-database.sh` deletes and reseeds `test.sqlite` at the start of every run
  (its default "fresh" mode). Tables living there would lose the previous run's values, which
  is the opposite of what a record kept for analysis is for -- the interesting queries
  ("is this step's timing drifting?", and every `captured_value` lookup a resume makes) are
  exactly the ones that need more than one run.
- `debug_log` is what the checklists **assert against** (`method-24.d`/`24.e`, every
  `wait_for_sql`). A runner writing rows into it would be adding to its own evidence, and would
  shift the `MAX(debug_log_id)` baselines those assertions scope themselves to.
- The app owns and migrates its schema (`database_version`). The runner adding tables to it
  makes the runner a party to those migrations for no benefit.

Recording is strictly best-effort: a step's result is the device test, and a failure to write
the side-record must never turn a passing step red. Every method here swallows its own errors
and reports through `disabled_reason` instead.

`captured_value` is the one part that is **not** merely a record -- a resume reads it back to
supply a `$var` whose scenario was skipped (see remembered.py). If it is unavailable the run
still works; a resumed scenario just can't recover an earlier one's captures, which is the same
position a missing `00-remembered.json` left it in.

See ER-diagram.md for the schema as a diagram, and README.md § Recorded step values for the
queries worth knowing.
"""

import datetime
import json
import os
import sqlite3

SCHEMA = """
CREATE TABLE IF NOT EXISTS run (
    run_id      TEXT PRIMARY KEY,
    started_at  TEXT NOT NULL,
    finished_at TEXT,
    -- PASS, FAIL, HALTED, or IMPORTED for a run carried over from 00-remembered.json. NULL
    -- while in progress, which is also how a killed run stays visible as never having ended.
    outcome     TEXT,
    -- What the run was *asked* to cover, newline-separated. Without it a run that halted early
    -- is indistinguishable from one that was never asked to go further.
    checklists  TEXT,
    -- Whether the end-of-run factory reset and re-pair completed. A run can pass every step and
    -- still leave the cube carrying test activity, and that is worth knowing later.
    cleanup     TEXT,
    -- Why a HALTED run stopped, in the runner's own words.
    halt_reason TEXT
);

CREATE TABLE IF NOT EXISTS step_value (
    step_value_id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id        TEXT    NOT NULL REFERENCES run (run_id),
    recorded_at   TEXT    NOT NULL,
    checklist     TEXT    NOT NULL,
    section       TEXT,
    step_number   INTEGER,
    description   TEXT    NOT NULL,
    -- PASS, FAIL or SKIP. A SKIP is recorded rather than left out, so "this step did not run"
    -- is distinguishable from "the run never got this far", which an absent row can't say.
    status        TEXT    NOT NULL,
    value         TEXT,
    -- On a FAIL, what the step should have read. Without it a row shows what came back but not
    -- what would have counted as right, which is half the failure.
    expected      TEXT,
    -- Why a SKIP was skipped, or a failure's raw detail when there was nothing to compare.
    note          TEXT,
    -- 'script' or 'human'. A human y/n answer and a machine-checked assertion are both PASS,
    -- and they are not equally strong evidence.
    verified_by   TEXT    NOT NULL DEFAULT 'script'
);

CREATE TABLE IF NOT EXISTS captured_value (
    captured_value_id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id       TEXT NOT NULL REFERENCES run (run_id),
    recorded_at  TEXT NOT NULL,
    checklist    TEXT NOT NULL,
    section      TEXT NOT NULL DEFAULT '',
    capture_name TEXT NOT NULL,
    value        TEXT,
    -- Last write wins within a scenario, matching the dict-assignment the JSON file did.
    -- `section` is '' rather than NULL for a step outside a scenario, because SQLite treats
    -- NULLs as distinct and the constraint would silently stop deduplicating.
    UNIQUE (run_id, checklist, section, capture_name)
);

-- The two access patterns the documented queries use: everything from one run, and one step's
-- history across runs.
CREATE INDEX IF NOT EXISTS idx_step_value_run ON step_value (run_id);
CREATE INDEX IF NOT EXISTS idx_step_value_step ON step_value (checklist, section, step_number);
-- The lookup a resume makes, on every unresolved $var of every step.
CREATE INDEX IF NOT EXISTS idx_captured_value_lookup
    ON captured_value (checklist, capture_name);
"""


# Columns added after the first version of this file shipped. `CREATE TABLE IF NOT EXISTS` does
# nothing to a table that already exists, so an existing testruns.sqlite would silently keep the
# old shape and every insert naming a new column would fail. Applied on open, cheapest possible
# migration: SQLite has no ADD COLUMN IF NOT EXISTS, so compare against PRAGMA table_info first.
# Only ever additive -- nothing here rewrites or drops anything a previous run recorded.
ADDED_COLUMNS = {
    "run": [("checklists", "TEXT"), ("cleanup", "TEXT"), ("halt_reason", "TEXT")],
    "step_value": [("expected", "TEXT"), ("note", "TEXT"),
                   ("verified_by", "TEXT NOT NULL DEFAULT 'script'")],
}


def _now():
    """Local time with its UTC offset. `database/CLAUDE.md` requires local time plus a
    recoverable zone but reaches that via a `timezone` FK table -- a whole table to resolve one
    column is not worth it here, and the offset satisfies the same requirement inline. Without
    it, runs either side of a DST change compare wrongly, which for a history kept to spot drift
    over months is the one thing it must not do."""
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def apply_added_columns(connection):
    """Bring an existing database up to the current SCHEMA. Additive only; see ADDED_COLUMNS."""
    for table, columns in ADDED_COLUMNS.items():
        existing = {row[1] for row in connection.execute(f"PRAGMA table_info({table})")}
        for name, decl in columns:
            if name not in existing:
                connection.execute(f"ALTER TABLE {table} ADD COLUMN {name} {decl}")
    connection.commit()


class RunRecord:
    """Everything one run writes. Never raises: see the module docstring."""

    def __init__(self, path, run_id):
        self.path = path
        self.run_id = run_id
        self.disabled_reason = None
        self.connection = None
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            self.connection = sqlite3.connect(path)
            # Off by default in SQLite, so the REFERENCES clauses above would otherwise be inert
            # documentation rather than enforced.
            self.connection.execute("PRAGMA foreign_keys = ON")
            self.connection.executescript(SCHEMA)
            apply_added_columns(self.connection)
            # The parent row must exist before any child insert can satisfy its foreign key.
            self.connection.execute(
                "INSERT OR IGNORE INTO run (run_id, started_at) VALUES (?, ?)",
                (run_id, _now()),
            )
            self.connection.commit()
        except (OSError, sqlite3.Error) as e:  # noqa: BLE001 -- recording is never fatal
            self.disabled_reason = str(e)
            self.connection = None

    # -- steps -------------------------------------------------------------------------------

    def record_step(self, checklist, section, step_number, description, status, value=None,
                    expected=None, note=None, verified_by="script"):
        """One step that ran, was skipped, or failed. `value` is whatever it read (None if it
        only did something), `expected` what it should have read, `note` the skip reason or a
        failure's raw detail, `verified_by` 'script' or 'human'.

        Committed per row rather than batched at the end: a run that is killed mid-way (or halts
        on a failure, which this runner does deliberately) is exactly when the values matter, so
        they must already be on disk.
        """
        self._write(
            "INSERT INTO step_value (run_id, recorded_at, checklist, section, step_number, "
            "description, status, value, expected, note, verified_by) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (self.run_id, _now(), checklist, section, step_number, description, status,
             None if value is None or value == "" else str(value),
             None if expected is None else str(expected),
             None if note is None else str(note), verified_by),
        )

    # -- captures ----------------------------------------------------------------------------

    def record_capture(self, checklist, section, capture_name, value):
        """One `capture =` value, replacing any earlier one of the same name in that scenario."""
        self._write(
            "INSERT INTO captured_value (run_id, recorded_at, checklist, section, capture_name, "
            "value) VALUES (?, ?, ?, ?, ?, ?) "
            "ON CONFLICT (run_id, checklist, section, capture_name) "
            "DO UPDATE SET value = excluded.value, recorded_at = excluded.recorded_at",
            (self.run_id, _now(), checklist, section or "", capture_name,
             None if value is None else str(value)),
        )

    def lookup_capture(self, checklist, capture_name):
        """The value `capture_name` last held for `checklist`, newest run first.

        Ordering reproduces what the JSON tree did exactly: runs newest-first (`run_id` is a
        sortable timestamp, so lexicographic order is chronological), and within a run the
        *earliest-recorded* scenario wins, which is what iterating the old dict's insertion order
        gave. Returns None if nothing ever recorded it -- the caller then leaves the `$var`
        unresolved, as before.
        """
        if self.connection is None:
            return None
        try:
            row = self.connection.execute(
                "SELECT value FROM captured_value WHERE checklist = ? AND capture_name = ? "
                "ORDER BY run_id DESC, captured_value_id ASC LIMIT 1",
                (checklist, capture_name),
            ).fetchone()
            return row[0] if row else None
        except sqlite3.Error:  # noqa: BLE001 -- a lookup failure just means "not remembered"
            return None

    def import_legacy_remembered(self, json_path):
        """One-time carry-over of `logs/00-remembered.json`, the file captures used to live in.

        Without this, the first run after the switch can't resume an interrupted *previous* run:
        its captures would only exist in a file nothing reads any more. Imported under their
        original run stamps so `lookup_capture`'s newest-first ordering still ranks them
        correctly against rows written since. Idempotent -- `INSERT OR IGNORE` means re-importing
        never overwrites a value a real run has recorded.
        """
        if self.connection is None or not os.path.exists(json_path):
            return 0
        try:
            with open(json_path) as f:
                doc = json.load(f)
            if not isinstance(doc, dict):
                return 0
            imported = 0
            for run_id, tests in doc.items():
                if not isinstance(tests, dict):
                    continue
                self.connection.execute(
                    "INSERT OR IGNORE INTO run (run_id, started_at, outcome) VALUES (?, ?, ?)",
                    (run_id, _now(), "IMPORTED"),
                )
                for checklist, sections in tests.items():
                    if not isinstance(sections, dict):
                        continue
                    for section, captures in sections.items():
                        if not isinstance(captures, dict):
                            continue
                        for name, value in captures.items():
                            cursor = self.connection.execute(
                                "INSERT OR IGNORE INTO captured_value (run_id, recorded_at, "
                                "checklist, section, capture_name, value) VALUES (?,?,?,?,?,?)",
                                (run_id, _now(), checklist, section or "", name,
                                 None if value is None else str(value)),
                            )
                            # rowcount is 0 for a row IGNOREd as already present, so a re-import
                            # reports 0 rather than re-announcing rows it didn't write.
                            imported += cursor.rowcount
            self.connection.commit()
            return imported
        except (OSError, ValueError, sqlite3.Error) as e:  # noqa: BLE001 -- never fatal
            self.disabled_reason = str(e)
            return 0

    # -- run lifecycle -----------------------------------------------------------------------

    def record_checklists(self, paths):
        """What the run was asked to cover, before it covers any of it."""
        self._write("UPDATE run SET checklists = ? WHERE run_id = ?",
                    ("\n".join(paths), self.run_id))

    def record_cleanup(self, result):
        """Whether the end-of-run factory reset and re-pair completed."""
        self._write("UPDATE run SET cleanup = ? WHERE run_id = ?", (result, self.run_id))

    def finish_run(self, outcome, halt_reason=None):
        """How the run ended: PASS, FAIL, or HALTED. Without this a run row stays open, which is
        itself the honest record of a run that was killed rather than finished."""
        self._write("UPDATE run SET finished_at = ?, outcome = ?, halt_reason = ? WHERE run_id = ?",
                    (_now(), outcome, halt_reason, self.run_id))

    def value_count(self):
        """How many step readings this run recorded -- for the closing summary, so a run says
        where the values went instead of leaving the developer to guess."""
        if self.connection is None:
            return 0
        try:
            return self.connection.execute(
                "SELECT COUNT(*) FROM step_value WHERE run_id = ? AND value IS NOT NULL",
                (self.run_id,),
            ).fetchone()[0]
        except sqlite3.Error:  # noqa: BLE001 -- recording is never fatal
            return 0

    def close(self):
        if self.connection is not None:
            try:
                self.connection.close()
            except sqlite3.Error:  # noqa: BLE001 -- recording is never fatal
                pass
            self.connection = None

    def _write(self, sql, params):
        if self.connection is None:
            return
        try:
            self.connection.execute(sql, params)
            self.connection.commit()
        except sqlite3.Error as e:  # noqa: BLE001 -- recording is never fatal
            self.disabled_reason = str(e)
