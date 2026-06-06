#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${AUTOPOIESIS_APP_DIR:-/opt/autopoiesis-os/app}"
INSTALL_DIR="${AUTOPOIESIS_INSTALL_DIR:-/opt/autopoiesis-os}"
DATA_DIR="${AUTOPOIESIS_DATA_DIR:-/var/lib/autopoiesis-os}"
LOG_DIR="${AUTOPOIESIS_LOG_DIR:-/var/log/autopoiesis-os}"
ROLLBACK_FILE="${AUTOPOIESIS_ROLLBACK_FILE:-$DATA_DIR/release-rollback.json}"
RELEASE_STATE_FILE="$DATA_DIR/release-state.json"
RELEASE_LOG_FILE="$DATA_DIR/release-log.json"
METHOD=""

mkdir -p "$DATA_DIR" "$LOG_DIR"

log() {
  echo "$(date -Is) rollback: $*" >> "$LOG_DIR/update.log"
}

fail() {
  log "failed: $*"
  append_release_event "release_rollback_failed" "error" "$*"
  exit 2
}

read_rollback_field() {
  local field="$1"
  node -e "const fs=require('fs');const d=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));process.stdout.write(String(d[process.argv[2]]||''));" "$ROLLBACK_FILE" "$field"
}

append_release_event() {
  local event_type="$1"
  local status="$2"
  local reason="${3:-}"
  node - "$RELEASE_LOG_FILE" "$event_type" "$status" "$reason" "${PREVIOUS_VERSION:-}" "${TARGET_VERSION:-}" "${METHOD:-}" <<'NODE'
const fs = require("fs");
const [file, eventType, status, reason, previousVersion, targetVersion, method] = process.argv.slice(2);
let entries = [];
try {
  entries = JSON.parse(fs.readFileSync(file, "utf8"));
  if (!Array.isArray(entries)) entries = [];
} catch {
  entries = [];
}
const observedAt = new Date().toISOString();
entries.push({
  eventId: "release-rollback-" + observedAt,
  eventType,
  status,
  previousVersion: targetVersion || null,
  targetVersion: previousVersion || null,
  version: previousVersion || null,
  rollbackFromVersion: targetVersion || null,
  rollbackToVersion: previousVersion || null,
  method: method || null,
  reason: reason || null,
  observedAt
});
fs.mkdirSync(require("path").dirname(file), { recursive: true });
fs.writeFileSync(file, JSON.stringify(entries.slice(-100), null, 2) + "\n", { mode: 0o600 });
NODE
}

write_release_state() {
  node - "$RELEASE_STATE_FILE" "$METHOD" "$PREVIOUS_VERSION" "$TARGET_VERSION" "$PREVIOUS_REVISION" <<'NODE'
const fs = require("fs");
const [file, method, previousVersion, targetVersion, previousRevision] = process.argv.slice(2);
fs.mkdirSync(require("path").dirname(file), { recursive: true });
fs.writeFileSync(file, JSON.stringify({
  status: "rolled_back",
  targetVersion: previousVersion || null,
  previousVersion: targetVersion || null,
  rollbackFromVersion: targetVersion || null,
  rollbackToVersion: previousVersion || null,
  previousRevision: previousRevision || null,
  method: method || null,
  rolledBackAt: new Date().toISOString()
}, null, 2) + "\n", { mode: 0o600 });
NODE
}

if [[ ! -f "$ROLLBACK_FILE" ]]; then
  fail "missing rollback metadata at $ROLLBACK_FILE"
fi

PREVIOUS_VERSION="$(read_rollback_field previousVersion)"
PREVIOUS_REVISION="$(read_rollback_field previousRevision)"
TARGET_VERSION="$(read_rollback_field targetVersion)"
BACKUP_DIR="$(read_rollback_field backupDir)"

if [[ -z "$PREVIOUS_VERSION" ]]; then
  fail "rollback metadata has no previousVersion"
fi

log "starting rollback from ${TARGET_VERSION:-unknown} to $PREVIOUS_VERSION"
append_release_event "release_rollback_started" "in_progress" ""

if [[ -n "$PREVIOUS_REVISION" && -d "$APP_DIR/.git" ]]; then
  git -C "$APP_DIR" reset --hard "$PREVIOUS_REVISION"
  METHOD="git_reset"
elif [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
  rsync -a --delete --exclude '.git' --exclude 'node_modules' "$BACKUP_DIR/" "$APP_DIR/"
  METHOD="snapshot_restore"
else
  fail "no usable git revision or snapshot backup is available"
fi

"$APP_DIR/scripts/bootstrap.sh"
if [[ "$(id -u)" -eq 0 ]]; then
  "$APP_DIR/scripts/install-systemd-units.sh"
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl restart autopoiesis-setup.service autopoiesis-kiosk.service >> "$LOG_DIR/update.log" 2>&1 || true
fi

write_release_state
append_release_event "release_rollback_completed" "completed" ""
log "completed rollback to $PREVIOUS_VERSION via $METHOD"

echo "Rolled back Autopoiesis OS to $PREVIOUS_VERSION via $METHOD"
