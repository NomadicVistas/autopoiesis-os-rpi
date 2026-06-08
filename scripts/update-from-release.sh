#!/usr/bin/env bash
set -euo pipefail

RELEASE_JSON="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${AUTOPOIESIS_APP_DIR:-/opt/autopoiesis-os/app}"
INSTALL_DIR="${AUTOPOIESIS_INSTALL_DIR:-/opt/autopoiesis-os}"
DATA_DIR="${AUTOPOIESIS_DATA_DIR:-/var/lib/autopoiesis-os}"
LOG_DIR="${AUTOPOIESIS_LOG_DIR:-/var/log/autopoiesis-os}"
STAGING_DIR="$INSTALL_DIR/releases/staging"
ROLLBACK_DIR="$INSTALL_DIR/releases/rollback"
ROLLBACK_BACKUP_DIR=""
ROLLBACK_FILE="$DATA_DIR/release-rollback.json"
RELEASE_STATE_FILE="$DATA_DIR/release-state.json"
RELEASE_LOG_FILE="$DATA_DIR/release-log.json"

# Appliance services that should be stopped during app tree replacement.
AOS_SERVICES=(
  autopoiesis-kiosk.service
  autopoiesis-setup.service
  autopoiesis-heartbeat.service
  autopoiesis-display.service
  autopoiesis-feed-sync.service
  autopoiesis-poll-release.timer
)

mkdir -p "$LOG_DIR" "$INSTALL_DIR/releases" "$DATA_DIR"

# ── Logging helpers ──────────────────────────────────────────────────────

log() {
  echo "$(date -Is) release-update: $*" >> "$LOG_DIR/update.log"
}

fail() {
  log "FAILED: $*"
  append_release_event "release_update_failed" "error" "$*"
  write_release_state "failed" "$*"
  exit 2
}

# ── State tracking helpers ───────────────────────────────────────────────

append_release_event() {
  local event_type="$1" status="$2" reason="${3:-}"
  node - "$RELEASE_LOG_FILE" "$event_type" "$status" "$reason" "${PREVIOUS_VERSION:-}" "${VERSION_TARGET:-}" "${METHOD:-}" <<'NODE'
const fs = require("fs");
const [file, eventType, status, reason, previousVersion, targetVersion, method] = process.argv.slice(2);
let entries = [];
try {
  entries = JSON.parse(fs.readFileSync(file, "utf8"));
  if (!Array.isArray(entries)) entries = [];
} catch { entries = []; }
entries.push({
  eventId: eventType + "-" + new Date().toISOString(),
  eventType,
  status,
  previousVersion: previousVersion || null,
  targetVersion: targetVersion || null,
  method: method || null,
  reason: reason || null,
  observedAt: new Date().toISOString()
});
fs.mkdirSync(require("path").dirname(file), { recursive: true });
fs.writeFileSync(file, JSON.stringify(entries.slice(-200), null, 2) + "\n", { mode: 0o600 });
NODE
}

write_release_state() {
  local status="$1" error="${2:-}"
  node - "$RELEASE_STATE_FILE" "$status" "$error" "${PREVIOUS_VERSION:-}" "${VERSION_TARGET:-}" "${RELEASE_CHANNEL:-}" "${RELEASE_TAG:-}" <<'NODE'
const fs = require("fs");
const [file, status, error, previousVersion, targetVersion, channel, tag] = process.argv.slice(2);
const state = {
  status,
  previousVersion: previousVersion || null,
  targetVersion: targetVersion || null,
  channel: channel || null,
  tag: tag || null,
  updatedAt: new Date().toISOString()
};
if (error) state.error = error;
fs.mkdirSync(require("path").dirname(file), { recursive: true });
fs.writeFileSync(file, JSON.stringify(state, null, 2) + "\n", { mode: 0o600 });
NODE
}

# ── Field readers ─────────────────────────────────────────────────────────

read_device_update_channel() {
  node -e "const fs=require('fs');const p=process.argv[1];try{const d=JSON.parse(fs.readFileSync(p,'utf8'));const c=d.updateChannel||d.update_channel||d.releaseChannel||d.release_channel;if(typeof c==='string'&&c.trim())process.stdout.write(c.trim());}catch{}" "$DATA_DIR/device.json"
}

read_release_field() {
  local field="$1"
  node -e "const fs=require('fs');const p=process.argv[1];const f=process.argv[2];const aliases={artifact_url:['artifact_url','artifactUrl','assetUrl','downloadUrl'],checksum:['checksum','sha256','artifactSha256','artifact_sha256'],version:['version','targetVersion','target_version'],channel:['channel','updateChannel','update_channel'],tag:['tagName','tag_name','tag'],release_id:['id','releaseId','release_id']};const d=JSON.parse(fs.readFileSync(p,'utf8'));const r=d.release||d;for(const k of aliases[f]||[f]){if(typeof r[k]==='string'&&r[k].trim()){process.stdout.write(r[k].trim());process.exit(0);}}process.stdout.write('');" "$RELEASE_JSON" "$field"
}

# ── App tree helpers ─────────────────────────────────────────────────────

app_tree_owner() {
  if [[ -n "${AUTOPOIESIS_USER:-}" ]]; then
    printf '%s:%s' "$AUTOPOIESIS_USER" "${AUTOPOIESIS_GROUP:-$AUTOPOIESIS_USER}"
    return
  fi
  if [[ -e "$APP_DIR" ]]; then
    stat -c '%U:%G' "$APP_DIR" 2>/dev/null && return
  fi
  printf '%s:%s' "$(id -un)" "$(id -gn)"
}

copy_app_tree() {
  local source_dir="$1"
  local target_dir="$2"
  local owner_group owner group
  owner_group="$(app_tree_owner)"
  owner="${owner_group%%:*}"
  group="${owner_group#*:}"
  "$SCRIPT_DIR/install-app-tree.sh" "$source_dir" "$target_dir" "$owner" "$group"
}

# ── Service lifecycle ────────────────────────────────────────────────────
# Track which services were active so we only restart the ones we stopped.

STOPPED_SERVICES=()

stop_appliance_services() {
  if [[ "$(id -u)" -ne 0 ]]; then
    log "not running as root — skipping service stop"
    return
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    log "systemctl not available — skipping service stop"
    return
  fi

  for svc in "${AOS_SERVICES[@]}"; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      log "stopping $svc"
      systemctl stop "$svc" 2>/dev/null || true
      STOPPED_SERVICES+=("$svc")
    fi
  done

  # Give services a moment to release file handles
  if [[ ${#STOPPED_SERVICES[@]} -gt 0 && "$(command -v sleep 2>/dev/null)" ]]; then
    sleep 1
  fi
}

start_appliance_services() {
  if [[ "$(id -u)" -ne 0 ]]; then return; fi
  if ! command -v systemctl >/dev/null 2>&1; then return; fi

  # Start services in reverse stop order for dependency correctness
  local i
  for (( i=${#STOPPED_SERVICES[@]}-1; i>=0; i-- )); do
    local svc="${STOPPED_SERVICES[$i]}"
    log "starting $svc"
    systemctl start "$svc" 2>/dev/null || true
  done
}

# ── Pre-flight checks ────────────────────────────────────────────────────

preflight_disk_space() {
  # Ensure at least 200MB free for the download + extraction staging.
  # Gracefully skip if df is unavailable (e.g. restricted PATH in tests).
  if ! command -v df >/dev/null 2>&1; then return; fi
  local required_mb="${AUTOPOIESIS_UPDATE_MIN_DISK_MB:-200}"
  local available_mb
  available_mb="$(df -m "$INSTALL_DIR" 2>/dev/null | awk 'NR==2{print $4}' || echo 0)"
  if [[ "$available_mb" -lt "$required_mb" ]]; then
    fail "insufficient disk space: ${available_mb}MB available, ${required_mb}MB required"
  fi
  log "pre-flight: ${available_mb}MB disk space available (≥ ${required_mb}MB required)"
}

preflight_version_check() {
  # Guard against accidental downgrade unless explicitly allowed.
  if [[ "${AUTOPOIESIS_ALLOW_DOWNGRADE:-}" == "1" ]]; then return; fi
  if [[ "$PREVIOUS_VERSION" == "unknown" ]]; then return; fi

  local cmp
  cmp="$(node - "$PREVIOUS_VERSION" "$VERSION_TARGET" <<'NODE'
const [prev, target] = process.argv.slice(2);
const parse = v => v.replace(/^v/, '').split('.').map(Number);
const pp = parse(prev);
const tp = parse(target);
for (let i = 0; i < Math.max(pp.length, tp.length); i++) {
  const a = pp[i] || 0;
  const b = tp[i] || 0;
  if (a < b) { process.stdout.write('-1'); process.exit(0); }
  if (a > b) { process.stdout.write('1'); process.exit(0); }
}
process.stdout.write('0');
NODE
  )"

  if [[ "$cmp" == "1" ]]; then
    fail "target version $VERSION_TARGET is older than current $PREVIOUS_VERSION. Set AUTOPOIESIS_ALLOW_DOWNGRADE=1 to override."
  fi
  log "pre-flight: version check passed ($PREVIOUS_VERSION → $VERSION_TARGET)"
}

preflight_same_version() {
  # Skip update if the target version matches current.
  if [[ "$PREVIOUS_VERSION" == "$VERSION_TARGET" ]]; then
    log "target version $VERSION_TARGET matches current — skipping update"
    write_release_state "skipped" "same_version"
    append_release_event "release_update_skipped" "skipped" "same_version"
    exit 0
  fi
}

# ── Rollback metadata ────────────────────────────────────────────────────

write_rollback_metadata() {
  node -e "const fs=require('fs');const file=process.argv[1];const previousVersion=process.argv[2];const previousRevision=process.argv[3]||null;const targetVersion=process.argv[4];const backupDir=process.argv[5]||null;const releaseChannel=process.argv[6]||null;const releaseTag=process.argv[7]||null;const releaseId=process.argv[8]||null;fs.writeFileSync(file, JSON.stringify({previousVersion,previousRevision,targetVersion,backupDir,releaseChannel,releaseTag,releaseId,startedAt:new Date().toISOString()}, null, 2)+'\n')" "$ROLLBACK_FILE" "$PREVIOUS_VERSION" "$PREVIOUS_REV" "$VERSION_TARGET" "$ROLLBACK_BACKUP_DIR" "$RELEASE_CHANNEL" "$RELEASE_TAG" "$RELEASE_ID"
}

# ══════════════════════════════════════════════════════════════════════════
# Main update flow
# ══════════════════════════════════════════════════════════════════════════

if [[ -z "$RELEASE_JSON" || ! -f "$RELEASE_JSON" ]]; then
  fail "missing release json argument"
fi

# ── 1. Channel enforcement ───────────────────────────────────────────────

if [[ -z "${AUTOPOIESIS_RELEASE_CHANNEL:-}" ]]; then
  DEVICE_UPDATE_CHANNEL="$(read_device_update_channel)"
  if [[ -n "$DEVICE_UPDATE_CHANNEL" ]]; then
    export AUTOPOIESIS_RELEASE_CHANNEL="$DEVICE_UPDATE_CHANNEL"
  fi
fi

if [[ -n "${AUTOPOIESIS_RELEASE_CHANNEL:-}" && -z "${AUTOPOIESIS_RELEASE_REQUIRE_CHANNEL+x}" ]]; then
  export AUTOPOIESIS_RELEASE_REQUIRE_CHANNEL=1
fi

# ── 2. Manifest validation ──────────────────────────────────────────────

if ! MANIFEST_CHECK_OUTPUT="$("$SCRIPT_DIR/release-manifest-check.sh" "$RELEASE_JSON" 2>&1)"; then
  fail "manifest validation: $MANIFEST_CHECK_OUTPUT"
fi
log "manifest validation passed"

# ── 3. Parse release fields ─────────────────────────────────────────────

VERSION_TARGET="$(read_release_field version)"
ARTIFACT_URL="$(read_release_field artifact_url)"
CHECKSUM="$(read_release_field checksum)"
RELEASE_CHANNEL="$(read_release_field channel)"
RELEASE_TAG="$(read_release_field tag)"
RELEASE_ID="$(read_release_field release_id)"

if [[ -z "$VERSION_TARGET" ]]; then
  fail "release has no version"
fi

PREVIOUS_VERSION="unknown"
[[ -f "$APP_DIR/VERSION" ]] && PREVIOUS_VERSION="$(tr -d '\n' < "$APP_DIR/VERSION")"
PREVIOUS_REV=""
if [[ -d "$APP_DIR/.git" ]]; then
  PREVIOUS_REV="$(git -C "$APP_DIR" rev-parse --short HEAD 2>/dev/null || true)"
fi

# ── 4. Pre-flight checks ───────────────────────────────────────────────

preflight_same_version
preflight_disk_space
preflight_version_check

log "starting update: $PREVIOUS_VERSION → $VERSION_TARGET (channel: ${RELEASE_CHANNEL:-default}, tag: ${RELEASE_TAG:-none})"
append_release_event "release_update_started" "in_progress" ""
write_release_state "in_progress" ""

# ── 5. Git fast-forward path (no artifact) ──────────────────────────────

METHOD=""

if [[ -z "$ARTIFACT_URL" ]]; then
  log "no artifact_url — applying git fast-forward"
  if [[ ! -d "$APP_DIR/.git" ]]; then
    fail "installed app is not a git checkout and no artifact_url was supplied"
  fi
  METHOD="git_ff"
  write_rollback_metadata

  stop_appliance_services

  git -C "$APP_DIR" fetch origin main
  git -C "$APP_DIR" pull --ff-only origin main
  "$APP_DIR/scripts/bootstrap.sh"
  if [[ "$(id -u)" -eq 0 ]]; then
    "$APP_DIR/scripts/install-systemd-units.sh"
  fi

  start_appliance_services

  log "completed: $PREVIOUS_VERSION → $VERSION_TARGET via git fast-forward"
  write_release_state "completed" ""
  append_release_event "release_update_completed" "completed" ""
  exit 0
fi

# ── 6. Artifact-based update ────────────────────────────────────────────

METHOD="artifact"

TMP_ARCHIVE="$(mktemp -t autopoiesis-release.XXXXXX.tar.gz)"
STAGING_WAS_CREATED=0

cleanup() {
  rm -f "$TMP_ARCHIVE"
  if [[ "$STAGING_WAS_CREATED" -eq 1 && "$UPDATE_SUCCEEDED" != "1" ]]; then
    rm -rf "$STAGING_DIR"
  fi
}
trap cleanup EXIT
UPDATE_SUCCEEDED=0

# Download and verify artifact
log "downloading artifact: $ARTIFACT_URL"
curl -fL "$ARTIFACT_URL" -o "$TMP_ARCHIVE" || fail "artifact download failed"
log "download complete ($(stat -c%s "$TMP_ARCHIVE" 2>/dev/null || echo '?') bytes)"

if [[ -n "$CHECKSUM" ]]; then
  log "verifying checksum"
  printf '%s  %s\n' "$CHECKSUM" "$TMP_ARCHIVE" | sha256sum -c - || fail "checksum verification failed"
  log "checksum verified"
fi

# Stop services before touching app tree
stop_appliance_services

# Create rollback backup (while services are stopped)
rm -rf "$ROLLBACK_DIR"
mkdir -p "$ROLLBACK_DIR/app"
copy_app_tree "$APP_DIR" "$ROLLBACK_DIR/app"
ROLLBACK_BACKUP_DIR="$ROLLBACK_DIR/app"
write_rollback_metadata
log "rollback backup created: $ROLLBACK_BACKUP_DIR"

# Extract artifact to staging
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
STAGING_WAS_CREATED=1
tar -xzf "$TMP_ARCHIVE" -C "$STAGING_DIR"

PAYLOAD_DIR="$STAGING_DIR"
if [[ $(find "$STAGING_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l) -eq 1 && $(find "$STAGING_DIR" -mindepth 1 -maxdepth 1 | wc -l) -eq 1 ]]; then
  PAYLOAD_DIR="$(find "$STAGING_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
fi

# Replace app tree
log "replacing app tree"
copy_app_tree "$PAYLOAD_DIR" "$APP_DIR"

# Bootstrap and reinstall units
"$APP_DIR/scripts/bootstrap.sh" || {
  log "WARNING: bootstrap failed after app tree replacement — attempting rollback"
  if [[ -d "$ROLLBACK_BACKUP_DIR" ]]; then
    copy_app_tree "$ROLLBACK_BACKUP_DIR" "$APP_DIR"
    "$APP_DIR/scripts/bootstrap.sh" || true
    start_appliance_services
    fail "bootstrap failed; rolled back to $PREVIOUS_VERSION"
  fi
  start_appliance_services
  fail "bootstrap failed and no rollback backup available"
}

if [[ "$(id -u)" -eq 0 ]]; then
  "$APP_DIR/scripts/install-systemd-units.sh"
fi

# Start services with new code
start_appliance_services

UPDATE_SUCCEEDED=1

log "completed: $PREVIOUS_VERSION → $VERSION_TARGET via artifact"
write_release_state "completed" ""
append_release_event "release_update_completed" "completed" ""
