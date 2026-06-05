#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="${AUTOPOIESIS_LOG_DIR:-/var/log/autopoiesis-os}"
LOCAL_URL="${AUTOPOIESIS_LOCAL_URL:-http://127.0.0.1:3030}"

mkdir -p "$LOG_DIR"

if ! command -v curl >/dev/null 2>&1; then
  echo "$(date -Is) command processing skipped: curl unavailable" >> "$LOG_DIR/commands.log"
  exit 0
fi

if curl -fsS -X POST "$LOCAL_URL/local/commands/process" >> "$LOG_DIR/commands.log" 2>> "$LOG_DIR/commands-error.log"; then
  printf '\n' >> "$LOG_DIR/commands.log"
else
  echo "$(date -Is) command processing failed" >> "$LOG_DIR/commands-error.log"
fi
