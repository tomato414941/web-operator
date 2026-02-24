#!/bin/bash
# Human-defined metrics (deterministic, not modifiable by agents)
# Output: metrics text to stdout (injected into agent prompts by session.sh)
# Side effect: appends to history file for future trend analysis
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
METRICS_DIR="$PROJECT_DIR/workspace/metrics"
mkdir -p "$METRICS_DIR"

NGINX_LOG="/var/log/nginx/web-ceo.access.log"
SELF_DOMAIN="devtoolbox.dedyn.io"
SERVER_IP="46.225.49.219"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# --- Health check ---
SITE_LIVE=false
if curl -s -o /dev/null -w "%{http_code}" http://localhost/ 2>/dev/null | grep -q "200"; then
  SITE_LIVE=true
fi

# --- Organic non-bot referrals per property (24h) ---
YESTERDAY=$(date -d '24 hours ago' '+%d/%b/%Y')
TODAY=$(date '+%d/%b/%Y')

if [ -f "$NGINX_LOG" ]; then
  ORGANIC_DATA=$(grep -E "$YESTERDAY|$TODAY" "$NGINX_LOG" 2>/dev/null | awk -F'"' \
    -v self="$SELF_DOMAIN" -v ip="$SERVER_IP" '
  {
    ref = $4
    if (ref == "-" || ref == "") next
    if (index(ref, self) > 0) next
    if (index(ref, ip) > 0) next

    ua = tolower($6)
    if (index(ua, "bot") > 0) next
    if (index(ua, "crawler") > 0) next
    if (index(ua, "spider") > 0) next
    if (index(ua, "chatgpt") > 0) next
    if (index(ua, "curl") > 0) next
    if (index(ua, "wget") > 0) next
    if (index(ua, "python") > 0) next
    if (index(ua, "scraper") > 0) next
    if (index(ua, "headless") > 0) next

    split($2, req, " ")
    path = req[2]

    if (path ~ /^\/blog/) prop = "blog"
    else if (path ~ /^\/tools/) prop = "tools"
    else if (path ~ /^\/cheatsheets/) prop = "cheatsheets"
    else if (path ~ /^\/datekit/) prop = "datekit"
    else if (path ~ /^\/budgetkit/) prop = "budgetkit"
    else if (path ~ /^\/healthkit/) prop = "healthkit"
    else if (path ~ /^\/sleepkit/) prop = "sleepkit"
    else if (path ~ /^\/focuskit/) prop = "focuskit"
    else if (path ~ /^\/opskit/) prop = "opskit"
    else if (path ~ /^\/studykit/) prop = "studykit"
    else if (path ~ /^\/careerkit/) prop = "careerkit"
    else if (path ~ /^\/housingkit/) prop = "housingkit"
    else if (path ~ /^\/taxkit/) prop = "taxkit"
    else if (path ~ /^\/autokit/) prop = "autokit"
    else if (path == "/") prop = "homepage"
    else prop = "other"

    total++
    count[prop]++
  }
  END {
    printf "%d\n", total+0
    props = "homepage blog tools cheatsheets datekit budgetkit healthkit sleepkit focuskit opskit studykit careerkit housingkit taxkit autokit other"
    n = split(props, arr, " ")
    for (i = 1; i <= n; i++) {
      printf "%s %d\n", arr[i], count[arr[i]]+0
    }
  }
  ')
else
  ORGANIC_DATA="0"
fi

# Parse awk output
ORGANIC_TOTAL=$(echo "$ORGANIC_DATA" | head -1)
declare -A ORGANIC_BY_PROP
while IFS=' ' read -r prop val; do
  ORGANIC_BY_PROP[$prop]=$val
done <<< "$(echo "$ORGANIC_DATA" | tail -n +2)"

# --- Output to stdout (for prompt injection) ---
cat <<EOF
timestamp: $TIMESTAMP
site_is_live: $SITE_LIVE

organic_non_bot_referrals_24h: $ORGANIC_TOTAL
per_property:
  blog: ${ORGANIC_BY_PROP[blog]:-0}
  tools: ${ORGANIC_BY_PROP[tools]:-0}
  cheatsheets: ${ORGANIC_BY_PROP[cheatsheets]:-0}
  homepage: ${ORGANIC_BY_PROP[homepage]:-0}
  careerkit: ${ORGANIC_BY_PROP[careerkit]:-0}
  taxkit: ${ORGANIC_BY_PROP[taxkit]:-0}
  housingkit: ${ORGANIC_BY_PROP[housingkit]:-0}
  focuskit: ${ORGANIC_BY_PROP[focuskit]:-0}
  sleepkit: ${ORGANIC_BY_PROP[sleepkit]:-0}
  healthkit: ${ORGANIC_BY_PROP[healthkit]:-0}
  opskit: ${ORGANIC_BY_PROP[opskit]:-0}
  studykit: ${ORGANIC_BY_PROP[studykit]:-0}
  datekit: ${ORGANIC_BY_PROP[datekit]:-0}
  budgetkit: ${ORGANIC_BY_PROP[budgetkit]:-0}
  autokit: ${ORGANIC_BY_PROP[autokit]:-0}
  other: ${ORGANIC_BY_PROP[other]:-0}
EOF

# --- Append to history (one JSON line per evaluation) ---
cat >> "$METRICS_DIR/human_metrics.jsonl" <<HIST
{"timestamp":"$TIMESTAMP","site_is_live":$SITE_LIVE,"organic_non_bot_referrals_24h":$ORGANIC_TOTAL,"blog":${ORGANIC_BY_PROP[blog]:-0},"tools":${ORGANIC_BY_PROP[tools]:-0},"cheatsheets":${ORGANIC_BY_PROP[cheatsheets]:-0},"homepage":${ORGANIC_BY_PROP[homepage]:-0},"careerkit":${ORGANIC_BY_PROP[careerkit]:-0},"taxkit":${ORGANIC_BY_PROP[taxkit]:-0},"housingkit":${ORGANIC_BY_PROP[housingkit]:-0},"focuskit":${ORGANIC_BY_PROP[focuskit]:-0},"sleepkit":${ORGANIC_BY_PROP[sleepkit]:-0},"healthkit":${ORGANIC_BY_PROP[healthkit]:-0},"opskit":${ORGANIC_BY_PROP[opskit]:-0},"studykit":${ORGANIC_BY_PROP[studykit]:-0},"datekit":${ORGANIC_BY_PROP[datekit]:-0},"budgetkit":${ORGANIC_BY_PROP[budgetkit]:-0},"autokit":${ORGANIC_BY_PROP[autokit]:-0}}
HIST
