#!/bin/bash
# ASI (Agent Stability Index) - Simplified
# Computes behavioral drift metrics from session history.
# Based on: arxiv.org/abs/2601.04170 (Agent Drift, Rath 2026)
#
# 5 dimensions (simplified from 12):
#   1. Category Diversity  (0.30) — detects fixation
#   2. Work Order Compliance (0.25) — detects worker rebellion
#   3. Session Reliability   (0.20) — detects infra issues
#   4. Output Consistency    (0.15) — detects behavioral instability
#   5. Metric Trend          (0.10) — detects ineffectiveness
#
# Output: ASI metrics to stdout (for prompt injection)
# Side effect: appends to asi_history.jsonl
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
WORKSPACE="$PROJECT_DIR/workspace"
LOGDIR="$PROJECT_DIR/logs"
METRICS_DIR="$WORKSPACE/metrics"
mkdir -p "$METRICS_DIR"

SESSION_LOG="$WORKSPACE/session_log.jsonl"
SESSIONS_LOG="$LOGDIR/sessions.log"
HUMAN_METRICS="$METRICS_DIR/human_metrics.jsonl"
ASI_HISTORY="$METRICS_DIR/asi_history.jsonl"

WINDOW=10       # sessions to analyze
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# --- Helper: safe tail that handles missing/empty files ---
safe_tail() {
  local file="$1" n="$2"
  if [ -f "$file" ] && [ -s "$file" ]; then
    tail -n "$n" "$file"
  fi
}

# --- 1. Category Diversity (Shannon entropy, normalized) ---
# 0.0 = all same category (full fixation)
# 1.0 = perfectly uniform across 6 categories (C/I/S/M/A/N)
calc_category_diversity() {
  local data
  data=$(safe_tail "$SESSION_LOG" "$WINDOW")
  if [ -z "$data" ]; then
    echo "null"
    return
  fi

  echo "$data" | jq -r '.primary_category // empty' | awk '
  {
    count[$1]++
    total++
  }
  END {
    if (total == 0) { print "null"; exit }
    max_entropy = log(6) / log(2)  # 6 categories
    entropy = 0
    for (c in count) {
      p = count[c] / total
      if (p > 0) entropy -= p * (log(p) / log(2))
    }
    printf "%.3f\n", (max_entropy > 0) ? entropy / max_entropy : 0
  }'
}

# --- 2. Work Order Compliance ---
# avg(completed / total) over last N sessions
# 1.0 = all orders fully completed
calc_work_order_compliance() {
  local data
  data=$(safe_tail "$SESSION_LOG" "$WINDOW")
  if [ -z "$data" ]; then
    echo "null"
    return
  fi

  echo "$data" | jq -r '
    select(.work_order_actions_total != null and .work_order_actions_total > 0) |
    "\(.work_order_actions_completed // 0) \(.work_order_actions_total)"
  ' | awk '
  {
    if ($2 > 0) {
      sum += $1 / $2
      n++
    }
  }
  END {
    if (n == 0) { print "null"; exit }
    printf "%.3f\n", sum / n
  }'
}

# --- 3. Session Reliability ---
# finished / (finished + aborted) over last N sessions
calc_session_reliability() {
  local data
  data=$(safe_tail "$SESSIONS_LOG" $((WINDOW * 2)))
  if [ -z "$data" ]; then
    echo "null"
    return
  fi

  echo "$data" | awk -F'|' '
  {
    if ($2 == "finished") finished++
    else if ($2 == "aborted") aborted++
  }
  END {
    total = finished + aborted
    if (total == 0) { print "null"; exit }
    printf "%.3f\n", finished / total
  }'
}

# --- 4. Output Consistency ---
# 1 - coefficient_of_variation(worker_log_sizes)
# High CV = unstable behavior. Clamped to [0, 1].
calc_output_consistency() {
  local log_sizes
  # Worker logs only: YYYYMMDD_HHMMSS.log (exclude _critic/_demand/_strategist)
  log_sizes=$(find "$LOGDIR" -maxdepth 1 -name '????????_??????.log' \
    -not -name '*_critic.log' -not -name '*_demand.log' \
    -not -name '*_strategist.log' -not -name 'sessions.log' \
    -not -name 'cron.log' -not -name 'manual.log' \
    -printf '%s\n' 2>/dev/null | sort -n | tail -n "$WINDOW")

  if [ -z "$log_sizes" ] || [ "$(echo "$log_sizes" | wc -l)" -lt 3 ]; then
    echo "null"
    return
  fi

  echo "$log_sizes" | awk '
  {
    vals[NR] = $1
    sum += $1
    n++
  }
  END {
    if (n < 3) { print "null"; exit }
    mean = sum / n
    if (mean == 0) { print "null"; exit }
    for (i = 1; i <= n; i++) {
      ss += (vals[i] - mean) ^ 2
    }
    sd = sqrt(ss / n)
    cv = sd / mean
    score = 1 - cv
    if (score < 0) score = 0
    if (score > 1) score = 1
    printf "%.3f\n", score
  }'
}

# --- 5. Metric Trend ---
# Compare recent vs older organic referrals.
# recent_avg / older_avg, normalized: >1 = improving.
# Score: 0.0 = declining, 0.5 = flat, 1.0 = growing fast
calc_metric_trend() {
  local data
  data=$(safe_tail "$HUMAN_METRICS" "$WINDOW")
  if [ -z "$data" ] || [ "$(echo "$data" | wc -l)" -lt 4 ]; then
    echo "null"
    return
  fi

  echo "$data" | jq -r '.organic_non_bot_referrals_24h // 0' | awk '
  {
    vals[NR] = $1
    n++
  }
  END {
    if (n < 4) { print "null"; exit }
    half = int(n / 2)

    older_sum = 0
    for (i = 1; i <= half; i++) older_sum += vals[i]
    older_avg = older_sum / half

    recent_sum = 0
    for (i = half + 1; i <= n; i++) recent_sum += vals[i]
    recent_avg = recent_sum / (n - half)

    if (older_avg <= 0 && recent_avg <= 0) {
      printf "%.3f\n", 0.5
      exit
    }
    if (older_avg <= 0) {
      printf "%.3f\n", 1.0
      exit
    }

    ratio = recent_avg / older_avg
    # Sigmoid-like normalization: ratio 0.5->0.2, 1.0->0.5, 2.0->0.8
    score = 1 / (1 + exp(-2 * (ratio - 1)))
    printf "%.3f\n", score
  }'
}

# --- Compute all dimensions ---
D_DIVERSITY=$(calc_category_diversity)
D_COMPLIANCE=$(calc_work_order_compliance)
D_RELIABILITY=$(calc_session_reliability)
D_CONSISTENCY=$(calc_output_consistency)
D_TREND=$(calc_metric_trend)

# --- Compute composite ASI ---
ASI=$(awk -v d="$D_DIVERSITY" -v c="$D_COMPLIANCE" -v r="$D_RELIABILITY" \
         -v o="$D_CONSISTENCY" -v t="$D_TREND" '
BEGIN {
  dims = 0; weighted = 0; total_weight = 0
  if (d != "null") { weighted += 0.30 * d; total_weight += 0.30; dims++ }
  if (c != "null") { weighted += 0.25 * c; total_weight += 0.25; dims++ }
  if (r != "null") { weighted += 0.20 * r; total_weight += 0.20; dims++ }
  if (o != "null") { weighted += 0.15 * o; total_weight += 0.15; dims++ }
  if (t != "null") { weighted += 0.10 * t; total_weight += 0.10; dims++ }

  if (dims == 0 || total_weight == 0) { print "null"; exit }
  printf "%.3f\n", weighted / total_weight
}')

# --- Drift alert level ---
ALERT="none"
if [ "$ASI" != "null" ]; then
  ALERT=$(awk -v a="$ASI" 'BEGIN {
    if (a < 0.4) print "critical"
    else if (a < 0.6) print "warning"
    else if (a < 0.8) print "watch"
    else print "none"
  }')
fi

# --- Output to stdout (for prompt injection) ---
cat <<EOF

agent_stability_index:
  composite: $ASI
  alert: $ALERT
  dimensions:
    category_diversity: $D_DIVERSITY
    work_order_compliance: $D_COMPLIANCE
    session_reliability: $D_RELIABILITY
    output_consistency: $D_CONSISTENCY
    metric_trend: $D_TREND
  window: $WINDOW sessions
  interpretation:
    - "1.0 = perfectly stable, 0.0 = severe drift"
    - "alert levels: none (>=0.8), watch (0.6-0.8), warning (0.4-0.6), critical (<0.4)"
EOF

# --- Append to history ---
NULL_SAFE() { if [ "$1" = "null" ]; then echo "null"; else echo "$1"; fi; }
cat >> "$ASI_HISTORY" <<HIST
{"timestamp":"$TIMESTAMP","asi":$(NULL_SAFE "$ASI"),"alert":"$ALERT","category_diversity":$(NULL_SAFE "$D_DIVERSITY"),"work_order_compliance":$(NULL_SAFE "$D_COMPLIANCE"),"session_reliability":$(NULL_SAFE "$D_RELIABILITY"),"output_consistency":$(NULL_SAFE "$D_CONSISTENCY"),"metric_trend":$(NULL_SAFE "$D_TREND"),"window":$WINDOW}
HIST
