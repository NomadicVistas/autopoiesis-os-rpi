#!/usr/bin/env bash
set -euo pipefail

# Bridge between the systemd updater timer and the local UI release system.
# On installed appliances (no .git checkout), this calls the local UI's
# /local/release/check and, when auto-update is enabled and a new release
# is available, /local/release/apply.  The local UI handles manifest
# validation, channel enforcement, artifact download, checksum verification,
# app-tree replacement, bootstrap, and systemd unit reinstallation.

LOCAL_URL="${AUTOPOIESIS_LOCAL_URL:-http://127.0.0.1:3030}"
DATA_DIR="${AUTOPOIESIS_DATA_DIR:-/var/lib/autopoiesis-os}"
LOG_DIR="${AUTOPOIESIS_LOG_DIR:-/var/log/autopoiesis-os}"
CURL_TIMEOUT="${AUTOPOIESIS_RELEASE_CURL_TIMEOUT:-30}"
DRY_RUN="${AUTOPOIESIS_RELEASE_CHECK_DRY_RUN:-0}"

mkdir -p "$LOG_DIR"

log() {
  echo "$(date -Is) release-update: $*" >> "$LOG_DIR/update.log"
}

if ! command -v curl >/dev/null 2>&1; then
  log "skipped: curl unavailable"
  exit 0
fi

# Respect device auto-update preference when available.
AUTO_UPDATE=""
if command -v node >/dev/null 2>&1 && [[ -f "$DATA_DIR/device.json" ]]; then
  AUTO_UPDATE="$(node -e "
    try {
      const d = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
      process.stdout.write(String(d.autoUpdate === false ? false : true));
    } catch { process.stdout.write('true'); }
  " "$DATA_DIR/device.json" 2>/dev/null || echo true)"
fi
if [[ "$AUTO_UPDATE" == "false" ]]; then
  log "skipped: auto-update disabled in device preferences"
  exit 0
fi

# Check if the local UI is reachable.
HEALTH_URL="${LOCAL_URL%/}/local/health"
if ! curl -fsS --max-time "$CURL_TIMEOUT" "$HEALTH_URL" >/dev/null 2>&1; then
  log "skipped: local UI not reachable at $LOCAL_URL"
  exit 0
fi

# Ask the local UI to check the hosted release endpoint.
CHECK_URL="${LOCAL_URL%/}/local/release/check"
CHECK_RESPONSE=""
CHECK_EXIT=0
CHECK_RESPONSE="$(curl -fsS -X POST --max-time "$CURL_TIMEOUT" "$CHECK_URL" 2>/dev/null)" || CHECK_EXIT=$?

if [[ $CHECK_EXIT -ne 0 ]]; then
  log "release check request failed (curl exit $CHECK_EXIT)"
  exit 0
fi

# Parse the check response.
UPDATE_AVAILABLE="false"
TARGET_VERSION=""
if command -v node >/dev/null 2>&1 && [[ -n "$CHECK_RESPONSE" ]]; then
  PARSED="$(node -e "
    try {
      const r = JSON.parse(process.argv[1]);
      const available = !!(r.release && r.release.version);
      const version = available ? r.release.version : '';
      process.stdout.write(JSON.stringify({ available, version }));
    } catch {
      process.stdout.write(JSON.stringify({ available: false, version: '' }));
    }
  " "$CHECK_RESPONSE" 2>/dev/null || echo '{"available":false,"version":""}')"
  UPDATE_AVAILABLE="$(node -e "const p=JSON.parse(process.argv[1]);process.stdout.write(String(p.available));" "$PARSED")"
  TARGET_VERSION="$(node -e "const p=JSON.parse(process.argv[1]);process.stdout.write(p.version);" "$PARSED")"
fi

if [[ "$UPDATE_AVAILABLE" != "true" || -z "$TARGET_VERSION" ]]; then
  log "release check: no update available"
  exit 0
fi

if [[ "$DRY_RUN" == "1" ]]; then
  log "dry-run: would apply release $TARGET_VERSION"
  exit 0
fi

# Apply the release through the local UI.
APPLY_URL="${LOCAL_URL%/}/local/release/apply"
APPLY_RESPONSE=""
APPLY_EXIT=0
APPLY_RESPONSE="$(curl -fsS -X POST --max-time 600 "$APPLY_URL" 2>/dev/null)" || APPLY_EXIT=$?

if [[ $APPLY_EXIT -ne 0 ]]; then
  log "release apply request failed for $TARGET_VERSION (curl exit $APPLY_EXIT)"
  exit 1
fi

# Parse the apply result.
APPLY_STATUS="unknown"
if command -v node >/dev/null 2>&1 && [[ -n "$APPLY_RESPONSE" ]]; then
  APPLY_STATUS="$(node -e "
    try {
      const r = JSON.parse(process.argv[1]);
      const ok = r.ok !== false;
      const version = r.version || '';
      const error = r.error || '';
      process.stdout.write(ok ? 'ok:' + version : 'error:' + error);
    } catch {
      process.stdout.write('parse_error');
    }
  " "$APPLY_RESPONSE" 2>/dev/null || echo "parse_error")"
fi

if [[ "$APPLY_STATUS" == ok:* ]]; then
  log "applied release $TARGET_VERSION → ${APPLY_STATUS#ok:}"
else
  log "release apply failed for $TARGET_VERSION: $APPLY_STATUS"
  exit 1
fi
