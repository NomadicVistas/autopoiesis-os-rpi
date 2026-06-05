#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="${AUTOPOIESIS_LOG_DIR:-/var/log/autopoiesis-os}"
LOCAL_URL="${AUTOPOIESIS_LOCAL_URL:-http://127.0.0.1:3030}"

if ! command -v curl >/dev/null 2>&1; then
  echo "$(date -Is) remote status skipped: curl unavailable" >> "$LOG_DIR/remote-status.log"
  exit 0
fi

curl -fsS "$LOCAL_URL/local/status" >> "$LOG_DIR/remote-status.log" 2>> "$LOG_DIR/remote-status-error.log" || {
  echo "$(date -Is) local status unavailable" >> "$LOG_DIR/remote-status-error.log"
}
printf '\n' >> "$LOG_DIR/remote-status.log"
