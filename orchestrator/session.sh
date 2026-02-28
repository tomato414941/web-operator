#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/config.sh"

LOGDIR="$PROJECT_DIR/logs"
SESSIONS_LOG="$LOGDIR/sessions.log"
mkdir -p "$LOGDIR" "$PROJECT_DIR/workspace"

LOG_BASENAME="$(date +%Y%m%d_%H%M%S)"
LOG_CRITIC="$LOGDIR/${LOG_BASENAME}_critic.log"
LOG_DEMAND="$LOGDIR/${LOG_BASENAME}_demand.log"
LOG_STRATEGIST="$LOGDIR/${LOG_BASENAME}_strategist.log"
LOG_WORKER="$LOGDIR/${LOG_BASENAME}.log"

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|started|$LOG_BASENAME" >> "$SESSIONS_LOG"

# --- Phase 0: Deterministic Evaluation (pre-session metrics) ---
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Starting deterministic evaluation"
EVAL_EXIT=0
HUMAN_METRICS=$(bash "$SCRIPT_DIR/evaluate.sh") || EVAL_EXIT=$?
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Deterministic evaluation finished (exit=$EVAL_EXIT)"

METRICS_BLOCK="
## Current Metrics (human-defined, deterministic)
$HUMAN_METRICS"

# --- Phase 1: Critic + Demand Analyst (parallel) ---
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Starting Phase 1: Critic, Demand Analyst in parallel"

CRITIC_EXIT=0
timeout "${PHASE1_TIMEOUT:-15}m" codex exec \
  "$(cat "$HOME/AGENTS.md" "$SCRIPT_DIR/CRITIC_PROMPT.md")$METRICS_BLOCK" \
  --dangerously-bypass-approvals-and-sandbox \
  --skip-git-repo-check \
  --cd "$PROJECT_DIR/workspace" \
  --json > "$LOG_CRITIC" 2>"$LOG_CRITIC.err" || CRITIC_EXIT=$? &
PID_CRITIC=$!

DEMAND_EXIT=0
timeout "${PHASE1_TIMEOUT:-15}m" codex exec \
  "$(cat "$HOME/AGENTS.md" "$SCRIPT_DIR/DEMAND_PROMPT.md")$METRICS_BLOCK" \
  --dangerously-bypass-approvals-and-sandbox \
  --skip-git-repo-check \
  --cd "$PROJECT_DIR/workspace" \
  --json > "$LOG_DEMAND" 2>"$LOG_DEMAND.err" || DEMAND_EXIT=$? &
PID_DEMAND=$!

wait "$PID_CRITIC" || CRITIC_EXIT=$?
wait "$PID_DEMAND" || DEMAND_EXIT=$?

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Critic finished (exit=$CRITIC_EXIT)"
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Demand Analyst finished (exit=$DEMAND_EXIT)"

if [ "$CRITIC_EXIT" -ne 0 ] && [ "$DEMAND_EXIT" -ne 0 ]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] All Phase 1 agents failed — aborting session"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|aborted|eval=$EVAL_EXIT|critic=$CRITIC_EXIT|demand=$DEMAND_EXIT|$LOG_BASENAME" >> "$SESSIONS_LOG"
  exit 1
fi

# --- Phase 2: Strategist ---
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Starting Strategist"
STRATEGIST_EXIT=0
timeout "${STRATEGIST_TIMEOUT:-10}m" codex exec \
  "$(cat "$HOME/AGENTS.md" "$SCRIPT_DIR/STRATEGIST_PROMPT.md")$METRICS_BLOCK" \
  --dangerously-bypass-approvals-and-sandbox \
  --skip-git-repo-check \
  --cd "$PROJECT_DIR/workspace" \
  --json > "$LOG_STRATEGIST" 2>"$LOG_STRATEGIST.err" || STRATEGIST_EXIT=$?
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Strategist finished (exit=$STRATEGIST_EXIT)"

if [ "$STRATEGIST_EXIT" -ne 0 ]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Strategist failed — aborting session (no work order)"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|aborted|eval=$EVAL_EXIT|critic=$CRITIC_EXIT|demand=$DEMAND_EXIT|strategist=$STRATEGIST_EXIT|$LOG_BASENAME" >> "$SESSIONS_LOG"
  exit 1
fi

# --- Phase 3: Worker ---
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Starting Worker"
WORKER_EXIT=0
timeout "${WORKER_TIMEOUT:-30}m" codex exec \
  "$(cat "$HOME/AGENTS.md" "$SCRIPT_DIR/WORKER_PROMPT.md")$METRICS_BLOCK" \
  --dangerously-bypass-approvals-and-sandbox \
  --skip-git-repo-check \
  --cd "$PROJECT_DIR/workspace" \
  --json > "$LOG_WORKER" 2>"$LOG_WORKER.err" || WORKER_EXIT=$?
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Worker finished (exit=$WORKER_EXIT)"

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|finished|eval=$EVAL_EXIT|critic=$CRITIC_EXIT|demand=$DEMAND_EXIT|strategist=$STRATEGIST_EXIT|worker=$WORKER_EXIT|$LOG_BASENAME" >> "$SESSIONS_LOG"

# Auto-cleanup: keep only last 30 days of logs
find "$LOGDIR" -name "*.log" -mtime +30 -delete 2>/dev/null || true
find "$LOGDIR" -name "*.log.err" -mtime +30 -delete 2>/dev/null || true
