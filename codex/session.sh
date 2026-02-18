#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOGDIR="$SCRIPT_DIR/logs"
WORKSPACE="$ROOT_DIR/workspace"

mkdir -p "$LOGDIR" "$WORKSPACE"
cd "$WORKSPACE"

SESSIONS_LOG="$LOGDIR/sessions.log"
LOG_BASENAME="$(date +%Y%m%d_%H%M%S)"
LOG="$LOGDIR/$LOG_BASENAME.log"
LOG_ERR="$LOGDIR/$LOG_BASENAME.log.err"

rm -f "$WORKSPACE/.session_complete" 2>/dev/null || true
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) session_start" >> "$SESSIONS_LOG"

source "$ROOT_DIR/config.sh"

timeout "${TIMEOUT:-60}m" codex exec \
  --dangerously-bypass-approvals-and-sandbox \
  --skip-git-repo-check \
  --json \
  "$(cat "$ROOT_DIR/AGENT_PROMPT.md")" >"$LOG" 2>"$LOG_ERR"
EXIT_STATUS=$?

LOG_SIZE="$(wc -c <"$LOG" 2>/dev/null || echo 0)"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) codex_exit code=$EXIT_STATUS size=$LOG_SIZE" >> "$SESSIONS_LOG"

bash "$ROOT_DIR/evaluate.sh"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) evaluate_done code=$?" >> "$SESSIONS_LOG"

exit "$EXIT_STATUS"
