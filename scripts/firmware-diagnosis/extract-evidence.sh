#!/usr/bin/env bash
# Extracts the rows that evidence the firmware behaviours from a diagnosis run into a small,
# standalone SQLite file that can be attached to a bug report.
#
# Original debug_log_id values and timestamps are carried over unchanged, so ordering by id is true
# chronological order and nothing has been re-stamped. The extract is a subset, never a rewrite.
set -euo pipefail

SRC="${1:-$HOME/Library/Application Support/TimeFlip/appdata.sqlite}"
OUT="${2:-firmware-evidence-$(date +%Y%m%d-%H%M%S).sqlite}"

if [ ! -f "$SRC" ]; then
  echo "error: no such database: $SRC" >&2
  exit 1
fi

rm -f "$OUT"
sqlite3 "$OUT" <<'SQL'
-- debug_log
-- Rows evidencing TimeFlip2 firmware behaviour, extracted from a diagnosis run. Ids and timestamps
-- are the source database's own.
CREATE TABLE debug_log (
  debug_log_id  INTEGER CONSTRAINT PK_debug_log PRIMARY KEY
  , logged_at   TEXT NOT NULL
  , tag         TEXT NOT NULL
  , message     TEXT NOT NULL
);
SQL

sqlite3 "$OUT" <<SQL
ATTACH DATABASE '$SRC' AS src;
INSERT INTO debug_log (debug_log_id, logged_at, tag, message)
SELECT debug_log_id, logged_at, tag, message FROM src.debug_log
WHERE
  -- the rename itself, and everything the app decided from it
     message LIKE 'Device name set to%'
  OR message LIKE 'Device name written%'
  OR message LIKE 'Device renamed to%'
  OR message LIKE 'Device rename refused%'
  OR message LIKE '0x15 commandResult re-read%'
  OR tag = 'device-name'
  -- what the scan saw, and which row was chosen
  OR tag = 'scan'
  OR message LIKE 'Discovered-device row tapped%'
  -- the pairing lifecycle around it
  OR message LIKE 'Button clicked: Forget Device%'
  OR message LIKE 'Button clicked: Scan for Devices%'
  OR message LIKE 'Resetting device password to default%'
  OR message LIKE 'Login accepted%'
  -- and the raw traffic, which is what the findings actually rest on
  OR tag IN ('ble-tx', 'ble-rx')
ORDER BY debug_log_id;
DETACH DATABASE src;
SQL

ROWS="$(sqlite3 "$OUT" "SELECT COUNT(*) FROM debug_log;")"
if [ "$ROWS" -eq 0 ]; then
  echo "error: no matching rows -- was the procedure in FIRMWARE-DIAGNOSIS.md actually run?" >&2
  rm -f "$OUT"
  exit 1
fi

# The claim that ordering by id is chronological is worth checking rather than asserting: it would
# be quietly false if rows were ever inserted out of order.
OUT_OF_ORDER="$(sqlite3 "$OUT" "
  SELECT COUNT(*) FROM (
    SELECT logged_at, LAG(logged_at) OVER (ORDER BY debug_log_id) AS prev FROM debug_log
  ) WHERE prev IS NOT NULL AND logged_at < prev;")"

echo "wrote $OUT"
echo "  rows:     $ROWS"
echo "  range:    $(sqlite3 "$OUT" "SELECT MIN(logged_at) || '  ..  ' || MAX(logged_at) FROM debug_log;")"
echo "  ordering: $([ "$OUT_OF_ORDER" -eq 0 ] && echo 'id order is chronological' || echo "$OUT_OF_ORDER ROWS OUT OF ORDER")"
echo "  integrity: $(sqlite3 "$OUT" 'PRAGMA integrity_check;')"
