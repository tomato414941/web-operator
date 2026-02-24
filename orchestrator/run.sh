#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOCKFILE="$PROJECT_DIR/logs/.session.lock"

mkdir -p "$PROJECT_DIR/logs"

# Prevent concurrent runs
exec 200>"$LOCKFILE"
flock -n 200 || { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) SKIP: another session running" >> "$PROJECT_DIR/logs/sessions.log"; exit 0; }

# Load API key
source ~/.secrets/openai

bash "$SCRIPT_DIR/session.sh"
