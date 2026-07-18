#!/usr/bin/env bash
# Repoints the appdata.sqlite symlink back at production.sqlite, ending a testing session started
# by use-test-database.sh. See Tests/Bench/README.md.
set -euo pipefail

DB_DIR="$HOME/Library/Application Support/TimeFlip"
APPDATA="$DB_DIR/appdata.sqlite"
PRODUCTION="$DB_DIR/production.sqlite"

if [ -e "$APPDATA" ] && [ ! -L "$APPDATA" ]; then
  echo "error: $APPDATA exists but is not a symlink -- refusing to touch it." >&2
  exit 1
fi

if [ ! -e "$PRODUCTION" ]; then
  echo "error: $PRODUCTION does not exist -- this would point appdata.sqlite at a database" \
    "that's never been created. Launch the app once while appdata.sqlite points at" \
    "production.sqlite (the default) so it can be created, then re-run this script." >&2
  exit 1
fi

if pgrep -x TimeFlipApp > /dev/null 2>&1; then
  echo "warning: TimeFlipApp is currently running -- it already has the old database file open" \
    "and won't see this change until you quit and relaunch it." >&2
fi

rm -f "$APPDATA"
ln -s "$(basename "$PRODUCTION")" "$APPDATA"

echo "appdata.sqlite now points at production.sqlite. Quit and relaunch the app to pick this up."
