#!/usr/bin/env bash
# Repoints the appdata.sqlite symlink at test.sqlite instead of production.sqlite, so an
# interactive testing session (see Tests/CLAUDE.md) never touches real data. Only
# meaningful under Developer Mode -- AppDataStore only creates the symlink at all when
# DeveloperMode.isEnabled is true (see AppDataStore.ensureDatabaseSymlink).
set -euo pipefail

DB_DIR="$HOME/Library/Application Support/TimeFlip"
APPDATA="$DB_DIR/appdata.sqlite"
PRODUCTION="$DB_DIR/production.sqlite"
TEST_DB="$DB_DIR/test.sqlite"

# Optional first arg "keep" preserves an existing test.sqlite instead of wiping it -- used when
# resuming a mid-run test batch, so state earlier scenarios built survives. Anything else (or no
# arg) starts fresh, the default for a normal run.
MODE="${1:-fresh}"


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

# A fresh testing session starts from an empty test database. Delete any existing test.sqlite
# (and its WAL/SHM sidecars) and recreate + seed it from scratch, so no state ever carries over
# between sessions. This only ever touches test.sqlite -- production.sqlite is never affected.
# In "keep" mode (resuming a mid-run batch) an existing test.sqlite is left untouched so the
# accumulated state survives; only the symlink below is (re)pointed at it.
if [ "$MODE" = "keep" ] && [ -e "$TEST_DB" ]; then
  echo "Keeping existing $TEST_DB (resume -- accumulated test state preserved)."
else
  if [ -e "$TEST_DB" ]; then
    echo "Deleting existing $TEST_DB (a fresh one is created for every testing session)..."
    rm -f "$TEST_DB" "$TEST_DB-wal" "$TEST_DB-shm"
  fi
  echo "Creating $TEST_DB..."
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  # Same DDL files, same filename-sorted order AppDataStore.runDatabaseDDL() runs at every launch,
  # with foreign keys enforced during seeding to match the app's own connection. The files hold no
  # live ALTER TABLE (see database/CLAUDE.md: migrations are commented out and run by hand), so
  # every statement here applies cleanly to an empty database. A live one would fail this script
  # under `set -e`, which is the right outcome: it breaks that rule.
  for sql_file in "$SCRIPT_DIR"/database/*.sql; do
    { echo "PRAGMA foreign_keys = ON;"; cat "$sql_file"; } | sqlite3 "$TEST_DB"
  done
  sqlite3 "$TEST_DB" "UPDATE setting SET setting_value = '{\"type\":\"test\"}' WHERE setting_name = 'db_type';"

  # Carry the pairing across from production. Which device this Mac is paired to (`paired_device`)
  # and whether it is paired at all (`paired`) are per-database rows, so a freshly seeded
  # test.sqlite reads as never-paired and the app would have to pair from scratch -- against a
  # device whose PIN is no longer the factory default, because the earlier production pairing
  # rotated it. Copying these two rows lets the app simply connect, using the password it already
  # has (a dev build's config.json PIN, otherwise the Keychain), neither of which lives in the
  # database. Pairing itself is 02b's subject, not setup's.
  #
  # The stored `uuid` does not have to be current: the app finds the device by scanning for its
  # name or service and connects to that (see TimeFlipBLEDevice.scanAndConnect), which is why
  # production keeps working with a peripheral id from an earlier pairing.
  if [ -e "$PRODUCTION" ]; then
    for setting_name in paired paired_device; do
      # quote() returns the value as a ready-escaped SQL literal, quotes included, so a device name
      # containing an apostrophe cannot break the UPDATE below.
      literal="$(sqlite3 -readonly "$PRODUCTION" \
        "SELECT quote(setting_value) FROM setting WHERE setting_name = '$setting_name';")"
      if [ -n "$literal" ]; then
        sqlite3 "$TEST_DB" \
          "UPDATE setting SET setting_value = $literal WHERE setting_name = '$setting_name';"
      fi
    done
    echo "Copied the pairing (paired, paired_device) from production.sqlite, so the app connects" \
      "to the already-paired device instead of pairing again."
  fi
fi

rm -f "$APPDATA"
ln -s "$(basename "$TEST_DB")" "$APPDATA"

echo "appdata.sqlite now points at test.sqlite. Quit and relaunch the app to pick this up."
