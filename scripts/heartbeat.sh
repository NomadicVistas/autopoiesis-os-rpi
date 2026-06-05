#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="${AUTOPOIESIS_DATA_DIR:-/var/lib/autopoiesis-os}"
LOG_DIR="${AUTOPOIESIS_LOG_DIR:-/var/log/autopoiesis-os}"
DEVICE_JSON="$DATA_DIR/device.json"
STATE_JSON="$DATA_DIR/state.json"
LOCAL_URL="${AUTOPOIESIS_LOCAL_URL:-http://127.0.0.1:3030}"

DEVICE_ID="$(node -e "const fs=require('fs');const d=JSON.parse(fs.readFileSync('$DEVICE_JSON','utf8'));process.stdout.write(d.deviceId || 'unknown')")"
MODE="$(node -e "const fs=require('fs');const d=JSON.parse(fs.readFileSync('$STATE_JSON','utf8'));process.stdout.write(d.currentMode || 'unknown')")"
TEMP="unknown"
if [[ -r /sys/class/thermal/thermal_zone0/temp ]]; then
  TEMP="$(awk '{ printf \"%.1f\", $1 / 1000 }' /sys/class/thermal/thermal_zone0/temp)"
fi
DISK_FREE_MB="$(df -Pm / | awk 'NR==2 {print $4}')"

printf '%s device=%s mode=%s temp=%s diskFreeMb=%s\n' "$(date -Is)" "$DEVICE_ID" "$MODE" "$TEMP" "$DISK_FREE_MB" >> "$LOG_DIR/heartbeat.log"

if command -v curl >/dev/null 2>&1; then
  if curl -fsS -X POST "$LOCAL_URL/local/heartbeat" >> "$LOG_DIR/heartbeat.log" 2>> "$LOG_DIR/heartbeat-error.log"; then
    printf '\n' >> "$LOG_DIR/heartbeat.log"
  else
    printf '%s local heartbeat failed\n' "$(date -Is)" >> "$LOG_DIR/heartbeat-error.log"
  fi
fi
