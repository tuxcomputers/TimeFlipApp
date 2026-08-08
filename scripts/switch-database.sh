#!/usr/bin/env bash
# Switches which database the next app launch uses, by repointing the appdata.sqlite symlink:
#
#   scripts/switch-database.sh              swap to whichever database is not in use right now
#   scripts/switch-database.sh test         switch to a brand new (rebuilt) test.sqlite
#   scripts/switch-database.sh test -keep   switch to test.sqlite, preserved as it is
#   scripts/switch-database.sh prod         switch back to production.sqlite (no-op if already there)
#   scripts/switch-database.sh -keep        swap, as above, without rebuilding what it lands on
#
# test.sqlite is what an interactive testing session (see Tests/CLAUDE.md) runs against, so it
# never touches real data; production.sqlite is the real one. Only meaningful under Developer
# Mode -- AppDataStore only creates the symlink at all when DeveloperMode.isEnabled is true (see
# AppDataStore.ensureDatabaseSymlink).
#
# With no target the current symlink decides: on production it switches to test, on test it
# switches back to production. Naming a target instead is idempotent for `prod` (already there ->
# exit, production.sqlite is real data and is never rebuilt) but deliberately NOT for `test`:
# `test` means "start a fresh session", so it rebuilds test.sqlite from the DDL even if that is
# already the database in use. `-keep` is what suppresses that rebuild, for resuming a mid-run
# test batch where state earlier scenarios built has to survive.
set -euo pipefail

usage() {
  local me
  me="$(basename "$0")"
  echo "usage: $me [test|prod] [-keep]" >&2
  echo "  (no target)  swap to whichever database is not currently in use" >&2
  echo "  test         switch to test.sqlite, rebuilt from scratch" >&2
  echo "  prod         switch to production.sqlite (does nothing if already there)" >&2
  echo "  -keep        don't rebuild the database being switched to" >&2
}

TARGET=""
KEEP=""   # empty until set: an unpassed -keep falls back to the per-target default below
while [ "$#" -gt 0 ]; do
  case "$1" in
    test|prod)
      if [ -n "$TARGET" ] && [ "$TARGET" != "$1" ]; then
        echo "error: two different targets given ('$TARGET' then '$1') -- pick one." >&2
        usage
        exit 2
      fi
      TARGET="$1"
      ;;
    -keep|--keep) KEEP=1 ;;
    *) echo "error: unknown argument '$1' -- expected 'test', 'prod' or '-keep'." >&2; usage; exit 2 ;;
  esac
  shift
done

DB_DIR="$HOME/Library/Application Support/TimeFlip"
APPDATA="$DB_DIR/appdata.sqlite"
PRODUCTION="$DB_DIR/production.sqlite"
TEST_DB="$DB_DIR/test.sqlite"

if [ -e "$APPDATA" ] && [ ! -L "$APPDATA" ]; then
  echo "error: $APPDATA exists but is not a symlink -- refusing to touch it." \
    "Launch the app once with Developer Mode on so it can migrate this into" \
    "production.sqlite + a symlink, then re-run this script." >&2
  exit 1
fi

# Which database is in use right now, read off the symlink itself -- that is what the next launch
# opens, so it is the thing being switched. Empty when there is no symlink yet, or when it points
# at a file this script doesn't manage; both are only fatal when the target has to be inferred.
CURRENT=""
if [ -L "$APPDATA" ]; then
  linked="$(basename "$(readlink "$APPDATA")")"
  if [ "$linked" = "$(basename "$PRODUCTION")" ]; then
    CURRENT="prod"
  elif [ "$linked" = "$(basename "$TEST_DB")" ]; then
    CURRENT="test"
  fi
fi

if [ -z "$TARGET" ]; then
  if [ -z "$CURRENT" ]; then
    echo "error: can't tell which database is in use (no appdata.sqlite symlink, or it points" \
      "somewhere unexpected), so there is no 'other' one to swap to. Name the target explicitly:" \
      "'test' or 'prod'." >&2
    usage
    exit 1
  fi
  if [ "$CURRENT" = "prod" ]; then TARGET="test"; else TARGET="prod"; fi
  echo "Currently on $CURRENT; switching to $TARGET."
fi

# production.sqlite holds real data: this script only ever relinks to it, so -keep is its
# permanent setting rather than an option. For test, -keep is what turns the rebuild off.
if [ "$TARGET" = "prod" ]; then
  KEEP=1
elif [ -z "$KEEP" ]; then
  KEEP=0
fi

if [ "$TARGET" = "prod" ] && [ "$CURRENT" = "prod" ]; then
  echo "Already on production.sqlite -- nothing to do."
  exit 0
fi

if [ "$TARGET" = "prod" ] && [ ! -e "$PRODUCTION" ]; then
  echo "error: $PRODUCTION does not exist -- this would point appdata.sqlite at a database" \
    "that's never been created. Launch the app once while appdata.sqlite points at" \
    "production.sqlite (the default) so it can be created, then re-run this script." >&2
  exit 1
fi

if [ "$TARGET" = "test" ] && [ ! -e "$APPDATA" ] && [ ! -L "$APPDATA" ]; then
  echo "error: $APPDATA does not exist yet -- launch the app at least once first," \
    "so it can create the symlink and production.sqlite." >&2
  exit 1
fi

if pgrep -x TimeFlipApp > /dev/null 2>&1; then
  echo "warning: TimeFlipApp is currently running -- it already has the old database file open" \
    "and won't see this change until you quit and relaunch it." >&2
fi

if [ "$TARGET" = "prod" ]; then
  TARGET_DB="$PRODUCTION"
else
  TARGET_DB="$TEST_DB"
  # A fresh testing session starts from an empty test database. Delete any existing test.sqlite
  # (and its WAL/SHM sidecars) and recreate + seed it from scratch, so no state ever carries over
  # between sessions. This only ever touches test.sqlite -- production.sqlite is never affected.
  # Under `-keep` (resuming a mid-run batch) an existing test.sqlite is left untouched so the
  # accumulated state survives; only the symlink below is (re)pointed at it.
  if [ "$KEEP" = "1" ] && [ -e "$TEST_DB" ]; then
    echo "Keeping existing $TEST_DB (accumulated test state preserved)."
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

    # Carry the pairing across from production. Which device this Mac is paired to (`device_uuid`,
    # plus the name it is carrying in `device_name`) and whether it is paired at all (`paired`) are
    # per-database rows, so a freshly seeded
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
      for setting_name in paired device_uuid device_name; do
        # quote() returns the value as a ready-escaped SQL literal, quotes included, so a device name
        # containing an apostrophe cannot break the UPDATE below.
        literal="$(sqlite3 -readonly "$PRODUCTION" \
          "SELECT quote(setting_value) FROM setting WHERE setting_name = '$setting_name';")"
        if [ -n "$literal" ]; then
          sqlite3 "$TEST_DB" \
            "UPDATE setting SET setting_value = $literal WHERE setting_name = '$setting_name';"
        fi
      done
      echo "Copied the pairing (paired, device_uuid, device_name) from production.sqlite, so the app connects" \
        "to the already-paired device instead of pairing again."
    fi
  fi
fi

rm -f "$APPDATA"
ln -s "$(basename "$TARGET_DB")" "$APPDATA"

echo "appdata.sqlite now points at $(basename "$TARGET_DB"). Quit and relaunch the app to pick this up."
