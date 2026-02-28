#!/bin/bash
# ASI (Agent Stability Index)
# Computes behavioral drift metrics from session history.
# Based on: arxiv.org/abs/2601.04170 (Agent Drift, Rath 2026)
#
# 7 dimensions (mapped to paper's 4 categories):
#   Response Consistency (25%):
#     1. Category Diversity    (0.15) — detects fixation
#     2. Output Consistency    (0.10) — detects behavioral instability
#   Tool Usage Patterns (25%):
#     3. Tool Selection        (0.15) — detects tool usage drift
#     4. Tool Sequencing       (0.10) — detects workflow pattern drift
#   Inter-Agent Coordination (25%):
#     5. Work Order Compliance (0.15) — detects worker rebellion
#     6. Session Reliability   (0.10) — detects infra issues
#   Behavioral Boundaries (25%):
#     7. Metric Trend          (0.25) — detects ineffectiveness
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

# --- Helper: list recent worker log files ---
worker_logs() {
  find "$LOGDIR" -maxdepth 1 -name '????????_??????.log' \
    -not -name '*_critic.log' -not -name '*_demand.log' \
    -not -name '*_strategist.log' -not -name '*_state_eval.log' \
    -not -name '*_action_eval.log' -not -name 'sessions.log' \
    -not -name 'cron.log' -not -name 'manual.log' \
    2>/dev/null | sort | tail -n "$WINDOW"
}

# --- 6. Tool Selection Stability ---
# Stability of item.type distribution (reasoning/command_execution/file_change/agent_message)
# across sessions. Low CV = stable tool mix.
calc_tool_selection_stability() {
  local logs
  logs=$(worker_logs)
  if [ -z "$logs" ] || [ "$(echo "$logs" | wc -l)" -lt 3 ]; then
    echo "null"
    return
  fi

  # For each log, extract item type counts as "session_id type count" lines
  local session_data=""
  local sid=0
  while IFS= read -r logfile; do
    sid=$((sid + 1))
    local counts
    counts=$(jq -r 'select(.type == "item.completed") | .item.type // "unknown"' "$logfile" 2>/dev/null | sort | uniq -c | awk -v s="$sid" '{print s, $2, $1}')
    if [ -n "$counts" ]; then
      session_data="${session_data}${counts}"$'\n'
    fi
  done <<< "$logs"

  if [ -z "$session_data" ]; then
    echo "null"
    return
  fi

  echo "$session_data" | awk '
  NF == 3 {
    sessions[$1] = 1
    types[$2] = 1
    count[$1, $2] = $3
    total[$1] += $3
  }
  END {
    ns = 0; for (s in sessions) ns++
    if (ns < 3) { print "null"; exit }

    # Compute proportion of each type per session
    nt = 0; for (t in types) { type_list[++nt] = t }

    # For each type, compute CV of proportions across sessions
    sum_cv = 0; n_types = 0
    for (ti = 1; ti <= nt; ti++) {
      t = type_list[ti]
      sum_p = 0; n_s = 0
      for (s in sessions) {
        p = (total[s] > 0) ? count[s, t] / total[s] : 0
        props[++n_s] = p
        sum_p += p
      }
      mean_p = sum_p / n_s
      if (mean_p < 0.01) continue  # skip rare types

      ss = 0
      for (i = 1; i <= n_s; i++) ss += (props[i] - mean_p) ^ 2
      sd = sqrt(ss / n_s)
      cv = sd / mean_p
      sum_cv += cv
      n_types++
      delete props
    }

    if (n_types == 0) { print "null"; exit }
    avg_cv = sum_cv / n_types
    score = 1 - avg_cv
    if (score < 0) score = 0
    if (score > 1) score = 1
    printf "%.3f\n", score
  }'
}

# --- 7. Tool Sequence Consistency ---
# Stability of item.type transition patterns (bigrams) across sessions.
# Compares bigram distributions using averaged cosine similarity.
calc_tool_sequence_consistency() {
  local logs
  logs=$(worker_logs)
  if [ -z "$logs" ] || [ "$(echo "$logs" | wc -l)" -lt 3 ]; then
    echo "null"
    return
  fi

  # For each log, extract bigram counts as "session_id bigram count"
  local bigram_data=""
  local sid=0
  while IFS= read -r logfile; do
    sid=$((sid + 1))
    local bigrams
    bigrams=$(jq -r 'select(.type == "item.completed") | .item.type // "unknown"' "$logfile" 2>/dev/null \
      | awk 'NR>1 {print prev">"$0} {prev=$0}' \
      | sort | uniq -c | awk -v s="$sid" '{print s, $2, $1}')
    if [ -n "$bigrams" ]; then
      bigram_data="${bigram_data}${bigrams}"$'\n'
    fi
  done <<< "$logs"

  if [ -z "$bigram_data" ]; then
    echo "null"
    return
  fi

  echo "$bigram_data" | awk '
  NF == 3 {
    sessions[$1] = 1
    bigrams[$2] = 1
    count[$1, $2] = $3
    total[$1] += $3
  }
  END {
    ns = 0; for (s in sessions) { s_list[++ns] = s }
    if (ns < 3) { print "null"; exit }
    nb = 0; for (b in bigrams) { b_list[++nb] = b }

    # Compute mean bigram distribution
    for (bi = 1; bi <= nb; bi++) {
      b = b_list[bi]
      s_sum = 0
      for (si = 1; si <= ns; si++) {
        s = s_list[si]
        p = (total[s] > 0) ? count[s, b] / total[s] : 0
        s_sum += p
      }
      mean_dist[b] = s_sum / ns
    }

    # Compute average cosine similarity of each session to mean
    sum_cos = 0
    for (si = 1; si <= ns; si++) {
      s = s_list[si]
      dot = 0; mag_s = 0; mag_m = 0
      for (bi = 1; bi <= nb; bi++) {
        b = b_list[bi]
        p_s = (total[s] > 0) ? count[s, b] / total[s] : 0
        p_m = mean_dist[b]
        dot += p_s * p_m
        mag_s += p_s * p_s
        mag_m += p_m * p_m
      }
      mag_s = sqrt(mag_s); mag_m = sqrt(mag_m)
      cosim = (mag_s > 0 && mag_m > 0) ? dot / (mag_s * mag_m) : 0
      sum_cos += cosim
    }

    score = sum_cos / ns
    if (score < 0) score = 0
    if (score > 1) score = 1
    printf "%.3f\n", score
  }'
}

# --- Compute all dimensions ---
D_DIVERSITY=$(calc_category_diversity)
D_COMPLIANCE=$(calc_work_order_compliance)
D_RELIABILITY=$(calc_session_reliability)
D_CONSISTENCY=$(calc_output_consistency)
D_TREND=$(calc_metric_trend)
D_TOOL_SELECT=$(calc_tool_selection_stability)
D_TOOL_SEQ=$(calc_tool_sequence_consistency)

# --- Compute composite ASI ---
# Weights mapped to paper's 4 categories (each 25%):
#   Response Consistency: diversity(0.15) + consistency(0.10) = 0.25
#   Tool Usage Patterns:  tool_select(0.15) + tool_seq(0.10)  = 0.25
#   Inter-Agent Coord:    compliance(0.15) + reliability(0.10) = 0.25
#   Behavioral Bounds:    trend(0.25)                          = 0.25
ASI=$(awk -v d="$D_DIVERSITY" -v c="$D_COMPLIANCE" -v r="$D_RELIABILITY" \
         -v o="$D_CONSISTENCY" -v t="$D_TREND" \
         -v ts="$D_TOOL_SELECT" -v tq="$D_TOOL_SEQ" '
BEGIN {
  dims = 0; weighted = 0; total_weight = 0
  if (d != "null")  { weighted += 0.15 * d;  total_weight += 0.15; dims++ }
  if (o != "null")  { weighted += 0.10 * o;  total_weight += 0.10; dims++ }
  if (ts != "null") { weighted += 0.15 * ts; total_weight += 0.15; dims++ }
  if (tq != "null") { weighted += 0.10 * tq; total_weight += 0.10; dims++ }
  if (c != "null")  { weighted += 0.15 * c;  total_weight += 0.15; dims++ }
  if (r != "null")  { weighted += 0.10 * r;  total_weight += 0.10; dims++ }
  if (t != "null")  { weighted += 0.25 * t;  total_weight += 0.25; dims++ }

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
  response_consistency:
    category_diversity: $D_DIVERSITY
    output_consistency: $D_CONSISTENCY
  tool_usage_patterns:
    tool_selection_stability: $D_TOOL_SELECT
    tool_sequence_consistency: $D_TOOL_SEQ
  inter_agent_coordination:
    work_order_compliance: $D_COMPLIANCE
    session_reliability: $D_RELIABILITY
  behavioral_boundaries:
    metric_trend: $D_TREND
  window: $WINDOW sessions
EOF

# --- Append to history ---
NULL_SAFE() { if [ "$1" = "null" ]; then echo "null"; else echo "$1"; fi; }
cat >> "$ASI_HISTORY" <<HIST
{"timestamp":"$TIMESTAMP","asi":$(NULL_SAFE "$ASI"),"alert":"$ALERT","category_diversity":$(NULL_SAFE "$D_DIVERSITY"),"output_consistency":$(NULL_SAFE "$D_CONSISTENCY"),"tool_selection_stability":$(NULL_SAFE "$D_TOOL_SELECT"),"tool_sequence_consistency":$(NULL_SAFE "$D_TOOL_SEQ"),"work_order_compliance":$(NULL_SAFE "$D_COMPLIANCE"),"session_reliability":$(NULL_SAFE "$D_RELIABILITY"),"metric_trend":$(NULL_SAFE "$D_TREND"),"window":$WINDOW}
HIST
