#!/usr/bin/env bash
# Night mode periodic enforcement
# Called by autopoiesis-night-mode.timer every minute.
# Probes the local UI /local/night-mode/apply endpoint which runs
# displayPowerCommand(vcgencmd display_power) when night mode is enabled
# and the current time is inside the configured window.
set -euo pipefail

LOCAL_URL="${AUTOPOIESIS_LOCAL_URL:-http://127.0.0.1:3030}"
LOG_DIR="${AUTOPOIESIS_LOG_DIR:-/var/log/autopoiesis-os}"
DRY_RUN="${AUTOPOIESIS_NIGHT_MODE_DRY_RUN:-0}"
CURL_TIMEOUT="${AUTOPOIESIS_NIGHT_MODE_CURL_TIMEOUT:-5}"

APPLY_URL="${LOCAL_URL%/}/local/night-mode/apply"

log() {
  local ts
  ts="$(date -Is 2>/dev/null || date)"
  printf '%s night-mode-apply: %s\n' "$ts" "$*" >> "$LOG_DIR/heartbeat.log"
}

if [[ "$DRY_RUN" == "1" ]]; then
  echo "dry-run: would POST $APPLY_URL"
  exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
  log "skipped: curl unavailable"
  exit 0
fi

mkdir -p "$LOG_DIR"

response="$(curl -fsS -X POST --max-time "$CURL_TIMEOUT" "$APPLY_URL" 2>/dev/null)" || {
  log "apply endpoint unreachable or failed (curl exit $?)"
  exit 0
}

# Log state transition for diagnostics
enabled="$(printf '%s' "$response" | node -e '
  try {
    const body = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const nm = body.nightMode || {};
    process.stdout.write(
      "enabled=" + nm.enabled +
      " active=" + nm.active +
      " displayOn=" + (nm.displayOn !== undefined ? nm.displayOn : "unknown")
    );
  } catch { process.stdout.write("parse-error"); }
' 2>/dev/null || echo "parse-error")"

log "applied: $enabled"
