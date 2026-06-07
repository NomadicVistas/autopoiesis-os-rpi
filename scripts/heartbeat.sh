#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="${AUTOPOIESIS_DATA_DIR:-/var/lib/autopoiesis-os}"
LOG_DIR="${AUTOPOIESIS_LOG_DIR:-/var/log/autopoiesis-os}"
DEVICE_JSON="$DATA_DIR/device.json"
STATE_JSON="$DATA_DIR/state.json"
LOCAL_URL="${AUTOPOIESIS_LOCAL_URL:-http://127.0.0.1:3030}"
HEARTBEAT_URL="${LOCAL_URL%/}/local/heartbeat"

json_field() {
  node - "$1" "$2" "$3" <<'NODE'
const fs = require("fs");
const file = process.argv[2];
const field = process.argv[3];
const fallback = process.argv[4] || "unknown";

try {
  const payload = JSON.parse(fs.readFileSync(file, "utf8"));
  const value = payload && typeof payload === "object" ? payload[field] : null;
  process.stdout.write(value === undefined || value === null || value === "" ? fallback : String(value));
} catch (_) {
  process.stdout.write(fallback);
}
NODE
}

install -d "$LOG_DIR"

DEVICE_ID="$(json_field "$DEVICE_JSON" deviceId unknown)"
MODE="$(json_field "$STATE_JSON" currentMode unknown)"
TEMP="unknown"
if [[ -r /sys/class/thermal/thermal_zone0/temp ]]; then
  TEMP="$(awk '{ printf \"%.1f\", $1 / 1000 }' /sys/class/thermal/thermal_zone0/temp)"
fi
DISK_FREE_MB="$(df -Pm / | awk 'NR==2 {print $4}')"

printf '%s device=%s mode=%s temp=%s diskFreeMb=%s\n' "$(date -Is)" "$DEVICE_ID" "$MODE" "$TEMP" "$DISK_FREE_MB" >> "$LOG_DIR/heartbeat.log"

if command -v curl >/dev/null 2>&1; then
  if curl -fsS -X POST "$HEARTBEAT_URL" >> "$LOG_DIR/heartbeat.log" 2>> "$LOG_DIR/heartbeat-error.log"; then
    printf '\n' >> "$LOG_DIR/heartbeat.log"
  else
    printf '%s local heartbeat failed\n' "$(date -Is)" >> "$LOG_DIR/heartbeat-error.log"
  fi
fi
