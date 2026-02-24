#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/config.sh"

LOGDIR="$PROJECT_DIR/logs"
SESSIONS_LOG="$LOGDIR/sessions.log"
mkdir -p "$LOGDIR" "$PROJECT_DIR/workspace"

LOG_BASENAME="$(date +%Y%m%d_%H%M%S)"
LOG_STATE_EVAL="$LOGDIR/${LOG_BASENAME}_state_eval.log"
LOG_ACTOR="$LOGDIR/${LOG_BASENAME}.log"
LOG_ACTION_EVAL="$LOGDIR/${LOG_BASENAME}_action_eval.log"

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|started|$LOG_BASENAME" >> "$SESSIONS_LOG"

# --- Step 1: State Evaluator ---
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Starting State Evaluator"
STATE_EVAL_EXIT=0
timeout "${STATE_EVAL_TIMEOUT:-30}m" codex exec \
  "$(cat "$HOME/AGENTS.md" "$SCRIPT_DIR/EVAL_STATE_PROMPT.md")" \
  --dangerously-bypass-approvals-and-sandbox \
  --skip-git-repo-check \
  --cd "$PROJECT_DIR/workspace" \
  --json > "$LOG_STATE_EVAL" 2>"$LOG_STATE_EVAL.err" || STATE_EVAL_EXIT=$?
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] State Evaluator finished (exit=$STATE_EVAL_EXIT)"

if [ "$STATE_EVAL_EXIT" -ne 0 ]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] State Evaluator failed — skipping Actor and Action Evaluator"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|aborted|state_exit=$STATE_EVAL_EXIT|$LOG_BASENAME" >> "$SESSIONS_LOG"
  exit 1
fi

# --- Step 2: Actor ---
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Starting Actor"
ACTOR_EXIT=0
timeout "${TIMEOUT:-35}m" codex exec \
  "$(cat "$HOME/AGENTS.md" "$SCRIPT_DIR/AGENT_PROMPT.md")" \
  --dangerously-bypass-approvals-and-sandbox \
  --skip-git-repo-check \
  --cd "$PROJECT_DIR/workspace" \
  --json > "$LOG_ACTOR" 2>"$LOG_ACTOR.err" || ACTOR_EXIT=$?
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Actor finished (exit=$ACTOR_EXIT)"

if [ "$ACTOR_EXIT" -ne 0 ]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Actor failed — skipping Action Evaluator"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|aborted|state_exit=$STATE_EVAL_EXIT|actor_exit=$ACTOR_EXIT|$LOG_BASENAME" >> "$SESSIONS_LOG"
  exit 1
fi

# --- Step 3: Deterministic Evaluation ---
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Starting deterministic evaluation"
EVAL_EXIT=0
bash "$SCRIPT_DIR/evaluate.sh" || EVAL_EXIT=$?
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Deterministic evaluation finished (exit=$EVAL_EXIT)"

# --- Step 4: Action Evaluator ---
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Starting Action Evaluator"
ACTION_EVAL_EXIT=0
source ~/.secrets/openai
ACTION_EVAL_PROMPT="$(cat "$SCRIPT_DIR/EVAL_ACTION_PROMPT.md")

The actor session log is at: $LOG_ACTOR"
timeout "${ACTION_EVAL_TIMEOUT:-30}m" codex exec \
  "$ACTION_EVAL_PROMPT" \
  --dangerously-bypass-approvals-and-sandbox \
  --skip-git-repo-check \
  --cd "$PROJECT_DIR/workspace" \
  --json > "$LOG_ACTION_EVAL" 2>"$LOG_ACTION_EVAL.err" || ACTION_EVAL_EXIT=$?
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Action Evaluator finished (exit=$ACTION_EVAL_EXIT)"

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|finished|state_exit=$STATE_EVAL_EXIT|actor_exit=$ACTOR_EXIT|eval_exit=$EVAL_EXIT|action_exit=$ACTION_EVAL_EXIT|$LOG_BASENAME" >> "$SESSIONS_LOG"

# Auto-cleanup: keep only last 30 days of logs
find "$LOGDIR" -name "*.log" -mtime +30 -delete 2>/dev/null || true
find "$LOGDIR" -name "*.log.err" -mtime +30 -delete 2>/dev/null || true
