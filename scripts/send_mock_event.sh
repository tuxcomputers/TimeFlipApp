#!/bin/sh
set -e

BASE_URL="${TIMEFLIP_MOCK_URL:-http://127.0.0.1:8765}"

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <command> [args]"
  echo "Commands:"
  echo "  flip <facet>"
  echo "  double-tap <facet> [pause]"
  echo "  pause <on|off>"
  echo "  lock <on|off>"
  echo "  auto-pause <minutes>"
  echo "  battery <level>"
  echo "  system <status> [hardware]"
  echo "  time <epoch>"
  echo "  status"
  echo "  history-last          # returns latest event number (0xFFFFFFFF equivalent)"
  echo "  event-log <message...>"
  exit 1
fi

cmd="$1"
shift

case "$cmd" in
  flip)
    facet="${1:?facet required}"
    curl -fsS "$BASE_URL/flip?facet=$facet"
    ;;
  double-tap)
    facet="${1:?facet required}"
    pause="${2:-}"
    if [ -n "$pause" ]; then
      curl -fsS "$BASE_URL/double-tap?facet=$facet&pause=$pause"
    else
      curl -fsS "$BASE_URL/double-tap?facet=$facet"
    fi
    ;;
  pause)
    on="${1:?on or off required}"
    curl -fsS "$BASE_URL/pause?on=$on"
    ;;
  lock)
    on="${1:?on or off required}"
    curl -fsS "$BASE_URL/lock?on=$on"
    ;;
  auto-pause)
    minutes="${1:?minutes required}"
    curl -fsS "$BASE_URL/auto-pause?minutes=$minutes"
    ;;
  battery)
    level="${1:?level required}"
    curl -fsS "$BASE_URL/battery?level=$level"
    ;;
  system)
    status="${1:?status required (decimal or 0x hex)}"
    hardware="${2:-0x0000}"
    curl -fsS "$BASE_URL/system?status=$status&hardware=$hardware"
    ;;
  time)
    epoch="${1:?epoch required}"
    curl -fsS "$BASE_URL/time?epoch=$epoch"
    ;;
  status)
    curl -fsS "$BASE_URL/status"
    ;;
  event-log)
    message="$*"
    if [ -z "$message" ]; then
      echo "message required" >&2
      exit 1
    fi
    curl -fsS --get --data-urlencode "message=$message" "$BASE_URL/event-log"
    ;;
  history-last)
    curl -fsS "$BASE_URL/history/last"
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    exit 1
    ;;
esac

echo ""
