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

# Memory usage
MEMORY_USAGE_MB="unknown"
MEMORY_TOTAL_MB="unknown"
if [[ -r /proc/meminfo ]]; then
  MEMORY_USAGE_MB="$(awk '/MemAvailable/ {printf \"%.0f\", ($2 / 1024)}' /proc/meminfo)"
  MEMORY_TOTAL_MB="$(awk '/MemTotal/ {printf \"%.0f\", ($2 / 1024)}' /proc/meminfo)"
fi

# CPU load average (1, 5, 15 min)
CPU_LOAD_AVG="unknown"
if [[ -r /proc/loadavg ]]; then
  CPU_LOAD_AVG="$(cat /proc/loadavg)"
fi

# Uptime in seconds
UPTIME_SECONDS="unknown"
if [[ -r /proc/uptime ]]; then
  UPTIME_SECONDS="$(awk '{print int($1)}' /proc/uptime)"
fi

# Service status checks
SERVICE_SETUP="unknown"
SERVICE_HEARTBEAT="unknown"
SERVICE_KIOSK="unknown"
SERVICE_CACHE="unknown"
SERVICE_UPDATER="unknown"
SERVICE_COMMAND_EXECUTOR="unknown"
SERVICE_WATCHDOG="unknown"
SERVICE_NIGHT_MODE="unknown"
APPLIANCE_TARGET="unknown"

if command -v systemctl >/dev/null 2>&1; then
  SERVICE_SETUP="$(systemctl is-active autopoiesis-setup.service 2>/dev/null || echo "unknown")"
  SERVICE_HEARTBEAT="$(systemctl is-active autopoiesis-heartbeat.service 2>/dev/null || echo "unknown")"
  SERVICE_KIOSK="$(systemctl is-active autopoiesis-kiosk.service 2>/dev/null || echo "unknown")"
  SERVICE_CACHE="$(systemctl is-active autopoiesis-cache.service 2>/dev/null || echo "unknown")"
  SERVICE_UPDATER="$(systemctl is-active autopoiesis-updater.service 2>/dev/null || echo "unknown")"
  SERVICE_COMMAND_EXECUTOR="$(systemctl is-active autopoiesis-command-executor.service 2>/dev/null || echo "unknown")"
  SERVICE_WATCHDOG="$(systemctl is-active autopoiesis-watchdog.service 2>/dev/null || echo "unknown")"
  SERVICE_NIGHT_MODE="$(systemctl is-active autopoiesis-night-mode.service 2>/dev/null || echo "unknown")"
  APPLIANCE_TARGET="$(systemctl is-active autopoiesis.target 2>/dev/null || echo "unknown")"
fi

printf '%s device=%s mode=%s temp=%s diskFreeMb=%s memoryUsageMb=%s memoryTotalMb=%s cpuLoadAvg=%s uptimeSeconds=%s setup=%s heartbeat=%s kiosk=%s cache=%s updater=%s commandExecutor=%s watchdog=%s nightMode=%s applianceTarget=%s\n' "$(date -Is)" "$DEVICE_ID" "$MODE" "$TEMP" "$DISK_FREE_MB" "$MEMORY_USAGE_MB" "$MEMORY_TOTAL_MB" "$CPU_LOAD_AVG" "$UPTIME_SECONDS" "$SERVICE_SETUP" "$SERVICE_HEARTBEAT" "$SERVICE_KIOSK" "$SERVICE_CACHE" "$SERVICE_UPDATER" "$SERVICE_COMMAND_EXECUTOR" "$SERVICE_WATCHDOG" "$SERVICE_NIGHT_MODE" "$APPLIANCE_TARGET" >> "$LOG_DIR/heartbeat.log"

if command -v curl >/dev/null 2>&1; then
  if curl -fsS -X POST "$HEARTBEAT_URL" >> "$LOG_DIR/heartbeat.log" 2>> "$LOG_DIR/heartbeat-error.log"; then
    printf '\n' >> "$LOG_DIR/heartbeat.log"
  else
    printf '%s local heartbeat failed\n' "$(date -Is)" >> "$LOG_DIR/heartbeat-error.log"
  fi
fi
