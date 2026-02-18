#!/bin/bash
WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/workspace"
METRICS_DIR="$WORKSPACE/metrics"
mkdir -p "$METRICS_DIR"

NGINX_LOG="/var/log/nginx/web-ceo.access.log"

# Parse nginx access log for last 24h
REQUESTS_24H=0
UNIQUE_IPS_24H=0
if [ -f "$NGINX_LOG" ]; then
  YESTERDAY=$(date -d '24 hours ago' '+%d/%b/%Y')
  TODAY=$(date '+%d/%b/%Y')
  REQUESTS_24H=$(grep -cE "$YESTERDAY|$TODAY" "$NGINX_LOG" 2>/dev/null || echo 0)
  UNIQUE_IPS_24H=$(grep -E "$YESTERDAY|$TODAY" "$NGINX_LOG" 2>/dev/null | awk '{print $1}' | sort -u | wc -l)
fi

# Check if site is live
SITE_LIVE=false
if curl -s -o /dev/null -w "%{http_code}" http://localhost/ | grep -q "200"; then
  SITE_LIVE=true
fi

# Write score
cat > "$METRICS_DIR/score.json" << EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "nginx_requests_24h": $REQUESTS_24H,
  "unique_ips_24h": $UNIQUE_IPS_24H,
  "site_is_live": $SITE_LIVE
}
EOF

# Append to history
cat >> "$METRICS_DIR/history.jsonl" << EOF
$(cat "$METRICS_DIR/score.json")
EOF
