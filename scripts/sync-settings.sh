#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="${AUTOPOIESIS_LOG_DIR:-/var/log/autopoiesis-os}"
LOCAL_URL="${AUTOPOIESIS_LOCAL_URL:-http://127.0.0.1:3030}"

if ! command -v curl >/dev/null 2>&1; then
  echo "$(date -Is) settings sync skipped: curl unavailable" >> "$LOG_DIR/sync-settings.log"
  exit 0
fi

if curl -fsS -X POST "$LOCAL_URL/local/settings/sync" >> "$LOG_DIR/sync-settings.log" 2>> "$LOG_DIR/sync-settings-error.log"; then
  printf '\n' >> "$LOG_DIR/sync-settings.log"
else
  echo "$(date -Is) settings sync failed" >> "$LOG_DIR/sync-settings-error.log"
fi
