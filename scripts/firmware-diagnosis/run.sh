#!/usr/bin/env bash
# Prepares and launches the firmware diagnosis harness: a throwaway database, a fresh build, and
# the app running with every BLE byte logged. See FIRMWARE-DIAGNOSIS.md for the procedure to follow
# once it is up, and for what the output means.
#
# This branch only. The build it produces carries diagnostic instrumentation that no shipping build
# should have.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

DB_DIR="$HOME/Library/Application Support/TimeFlip"
APPDATA="$DB_DIR/appdata.sqlite"
BINARY=".build/bundler/apps/TimeFlip/TimeFlip.app/Contents/MacOS/TimeFlip"

echo "==> Quitting any running instance"
if pgrep -f "TimeFlip.app/Contents/MacOS/TimeFlip" > /dev/null 2>&1; then
  osascript -e 'tell application "TimeFlip" to quit' > /dev/null 2>&1 || true
  for _ in $(seq 1 25); do
    pgrep -f "TimeFlip.app/Contents/MacOS/TimeFlip" > /dev/null 2>&1 || break
    sleep 1
  done
  if pgrep -f "TimeFlip.app/Contents/MacOS/TimeFlip" > /dev/null 2>&1; then
    echo "error: the app is still running and would hold the old database open." >&2
    exit 1
  fi
fi

echo "==> Creating a fresh test database"
scripts/use-test-database.sh fresh

# Belt and braces. Everything below writes to whatever appdata.sqlite points at, and the whole
# point of this harness is that it is safe to run repeatedly, so verify the redirection took rather
# than trusting that it did.
DB_TYPE="$(sqlite3 -readonly "$APPDATA" "SELECT setting_value FROM setting WHERE setting_name = 'db_type';")"
if [ "$DB_TYPE" != '{"type":"test"}' ]; then
  echo "error: appdata.sqlite still reads db_type=$DB_TYPE, not test." >&2
  echo "       Refusing to run a diagnosis session against a production database." >&2
  exit 1
fi
echo "    db_type = test, confirmed"

# Pairing presents exactly one PIN and has no fallback (TimeFlipBLEDevice.connectToDiscoveredDevice
# returns .wrongPassword rather than trying another), and in a developer build that PIN comes from
# config.json. Without the file the app would offer its internal dev default, which a factory-fresh
# device has never heard of, so pairing would fail at the first step for anyone but us.
#
# Only created when absent. An existing config.json is left exactly as it is: it is maintained by
# hand, and silently rewriting it is a mistake this project has already made once.
CONFIG="$DB_DIR/config.json"
if [ ! -e "$CONFIG" ]; then
  echo "==> Writing $CONFIG with the factory-default PIN"
  printf '{\n  "PIN": "000000"\n}\n' > "$CONFIG"
else
  echo "==> Leaving the existing config.json alone (PIN: $(sqlite3 /dev/null "SELECT 1" >/dev/null 2>&1; python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("PIN","absent"))' "$CONFIG" 2>/dev/null || echo unreadable))"
  echo "    If pairing reports a wrong PIN, the device is not on that PIN. Use Forget Device from"
  echo "    an install that is still paired, which resets it to the factory default 000000."
fi

echo "==> Building"
mint run stackotter/swift-bundler@main bundle TimeFlip

echo "==> Recording the build identity"
COMMIT="$(git rev-parse --short HEAD)"
DIRTY=""
if ! git diff --quiet || ! git diff --cached --quiet; then
  DIRTY=" (with uncommitted changes)"
fi
echo "    commit $COMMIT$DIRTY"

echo "==> Launching"
nohup "$BINARY" > /dev/null 2>&1 &
echo
echo "The app is running against a throwaway database."
echo "Follow the procedure in FIRMWARE-DIAGNOSIS.md, then run:"
echo
echo "    scripts/firmware-diagnosis/extract-evidence.sh"
echo
