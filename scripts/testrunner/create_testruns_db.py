#!/usr/bin/env python3
"""Create (or upgrade) logs/testruns.sqlite from run_record.SCHEMA, without running any tests.

A normal run creates the database itself, so this exists for the case where you want it to open
in a client before there is anything to look at -- pointing DBeaver at a path that doesn't exist
yet gets you an error rather than an empty schema.

Safe to re-run: every statement in SCHEMA is CREATE ... IF NOT EXISTS, so this adds anything
missing and touches nothing that is already there. It is also how you pick up a schema change
without waiting for the next run.

    python3 scripts/testrunner/create_testruns_db.py [--path PATH]

DBeaver: New Database Connection -> SQLite -> Path = the printed absolute path. No driver
settings to change, and nothing else needs to be running.
"""

import argparse
import os
import sqlite3
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from run_record import SCHEMA, apply_added_columns  # noqa: E402


def default_path():
    repo_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    return os.path.join(repo_root, "logs", "testruns.sqlite")


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--path", default=default_path(),
                        help="where to create it (default: logs/testruns.sqlite)")
    args = parser.parse_args()

    existed = os.path.exists(args.path)
    os.makedirs(os.path.dirname(args.path), exist_ok=True)
    connection = sqlite3.connect(args.path)
    connection.execute("PRAGMA foreign_keys = ON")
    connection.executescript(SCHEMA)
    # CREATE TABLE IF NOT EXISTS does nothing to a table that already exists, so an older file
    # needs its newer columns added explicitly. This is what makes re-running this an upgrade.
    apply_added_columns(connection)
    connection.commit()

    print(f"{'Updated' if existed else 'Created'} {args.path}")
    for (name, kind) in connection.execute(
        "SELECT name, type FROM sqlite_master WHERE type IN ('table','index') "
        "AND name NOT LIKE 'sqlite_%' ORDER BY type DESC, name"
    ):
        if kind == "table":
            columns = [r[1] for r in connection.execute(f"PRAGMA table_info({name})")]
            rows = connection.execute(f"SELECT COUNT(*) FROM {name}").fetchone()[0]
            print(f"  table {name:15} {rows:>5} row(s)  ({', '.join(columns)})")
        else:
            print(f"  index {name}")
    connection.close()
    print("\nDBeaver: New Database Connection -> SQLite -> Path = the path above.")


if __name__ == "__main__":
    main()
