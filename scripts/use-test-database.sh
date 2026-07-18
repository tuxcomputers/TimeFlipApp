#!/usr/bin/env bash
# Repoints the appdata.sqlite symlink at test.sqlite instead of production.sqlite, so an
# interactive testing session (see Tests/Bench/README.md) never touches real data. Only
# meaningful under Developer Mode -- AppDataStore only creates the symlink at all when
# DeveloperMode.isEnabled is true (see AppDataStore.ensureDatabaseSymlink).
set -euo pipefail

DB_DIR="$HOME/Library/Application Support/TimeFlip"
APPDATA="$DB_DIR/appdata.sqlite"
PRODUCTION="$DB_DIR/production.sqlite"
TEST_DB="$DB_DIR/test.sqlite"

if [ ! -e "$APPDATA" ] && [ ! -L "$APPDATA" ]; then
  echo "error: $APPDATA does not exist yet -- launch the app at least once first," \
    "so it can create the symlink and production.sqlite." >&2
  exit 1
fi

if [ -e "$APPDATA" ] && [ ! -L "$APPDATA" ]; then
  echo "error: $APPDATA exists but is not a symlink -- refusing to touch it." \
    "Launch the app once with Developer Mode on so it can migrate this into" \
    "production.sqlite + a symlink, then re-run this script." >&2
  exit 1
fi

if pgrep -x TimeFlipApp > /dev/null 2>&1; then
  echo "warning: TimeFlipApp is currently running -- it already has the old database file open" \
    "and won't see this change until you quit and relaunch it." >&2
fi

if [ ! -e "$TEST_DB" ]; then
  echo "Creating $TEST_DB..."
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  # Same DDL files, same filename-sorted order AppDataStore.runDatabaseDDL() runs at every launch.
  for sql_file in "$SCRIPT_DIR"/database/*.sql; do
    sqlite3 "$TEST_DB" < "$sql_file"
  done
  sqlite3 "$TEST_DB" "UPDATE setting SET setting_value = '{\"type\":\"test\"}' WHERE setting_name = 'db_type';"
else
  echo "$TEST_DB already exists -- reusing it as-is (not re-seeded/reset)."
fi

rm -f "$APPDATA"
ln -s "$(basename "$TEST_DB")" "$APPDATA"

echo "appdata.sqlite now points at test.sqlite. Quit and relaunch the app to pick this up."
