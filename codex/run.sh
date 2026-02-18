#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

mkdir -p "$SCRIPT_DIR/logs" "$ROOT_DIR/workspace"
echo $$ > "$SCRIPT_DIR/logs/loop.pid"

while true; do
  source "$ROOT_DIR/config.sh"
  TIMEOUT="${TIMEOUT:-60}" bash "$SCRIPT_DIR/session.sh"
  sleep "${SLEEP_INTERVAL:-3600}"
done
