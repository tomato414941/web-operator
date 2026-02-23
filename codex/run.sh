#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCKFILE="$SCRIPT_DIR/logs/.session.lock"

mkdir -p "$SCRIPT_DIR/logs" "$ROOT_DIR/workspace"

# Prevent concurrent runs
exec 200>"$LOCKFILE"
flock -n 200 || { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) SKIP: another session running" >> "$SCRIPT_DIR/logs/sessions.log"; exit 0; }

# Load API key for all Codex instances (evaluators + actor)
source ~/.secrets/openai
source "$ROOT_DIR/config.sh"

bash "$SCRIPT_DIR/session.sh"
