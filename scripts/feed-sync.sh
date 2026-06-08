#!/usr/bin/env bash
# feed-sync.sh — Standalone feed sync for Pi appliance
#
# Syncs the personalized content feed from the hosted API through the
# local UI server, populating feed.json and feed-cache.json so that:
#   1. The kiosk has fresh content to display immediately on load.
#   2. The cache-artworks.sh pipeline has a manifest to download from.
#   3. Offline fallback always has cached items available.
#
# This decouples feed sync from the kiosk browser polling loop, making
# the cache pipeline self-sufficient even when Chromium is not running
# (crashed, in setup mode, between page loads).
#
# Called by:
#   - autopoiesis-cache.service (before cache-artworks.sh)
#   - Manually: sudo -u frame /opt/autopoiesis-os/app/scripts/feed-sync.sh
#
# Usage:
#   scripts/feed-sync.sh [--json] [--verbose]
#
# Exit codes:
#   0  sync succeeded or skipped gracefully
#   1  sync failed (local UI unreachable or returned error)
set -euo pipefail

LOCAL_URL="${AUTOPOIESIS_LOCAL_URL:-http://127.0.0.1:3030}"
LOG_DIR="${AUTOPOIESIS_LOG_DIR:-/var/log/autopoiesis-os}"
SYNC_URL="${LOCAL_URL%/}/local/feed/sync"
CURL_TIMEOUT="${AUTOPOIESIS_FEED_SYNC_CURL_TIMEOUT:-30}"
DRY_RUN="${AUTOPOIESIS_FEED_SYNC_DRY_RUN:-0}"
JSON_OUTPUT=0
VERBOSE=0

for arg in "$@"; do
  case "$arg" in
    --json|-j)    JSON_OUTPUT=1 ;;
    --verbose|-v) VERBOSE=1 ;;
    -h|--help)
      cat <<'HELP'
Usage: feed-sync.sh [--json] [--verbose]

Standalone feed sync for the Autopoiesis Pi appliance.
Calls the local UI /local/feed/sync endpoint to pull fresh content
from the hosted API and populate the local feed + cache manifest.

Options:
  --json      Output sync result as JSON
  --verbose   Print sync result to stdout
  -h, --help  Show this help
HELP
      exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

log() {
  local ts
  ts="$(date -Is 2>/dev/null || date)"
  printf '%s feed-sync: %s\n' "$ts" "$*" >> "$LOG_DIR/feed-sync.log"
}

# ── Guards ───────────────────────────────────────────────────────────────

if ! command -v curl >/dev/null 2>&1; then
  log "skipped: curl unavailable"
  if [[ "$JSON_OUTPUT" == "1" ]]; then
    printf '{"ok":false,"skipped":true,"reason":"curl unavailable"}\n'
  fi
  exit 0
fi

mkdir -p "$LOG_DIR"

if [[ "$DRY_RUN" == "1" ]]; then
  log "dry-run: would POST $SYNC_URL"
  if [[ "$JSON_OUTPUT" == "1" ]]; then
    printf '{"ok":false,"skipped":true,"reason":"dry_run"}\n'
  fi
  exit 0
fi

# ── Check local UI health ────────────────────────────────────────────────

HEALTH_URL="${LOCAL_URL%/}/local/health"
if ! curl -fsS --max-time 5 "$HEALTH_URL" >/dev/null 2>&1; then
  log "skipped: local UI not reachable at $LOCAL_URL"
  if [[ "$JSON_OUTPUT" == "1" ]]; then
    printf '{"ok":false,"skipped":true,"reason":"local_ui_unreachable"}\n'
  fi
  exit 0
fi

# ── Sync feed ────────────────────────────────────────────────────────────

log "syncing feed from $SYNC_URL"

response=""
http_code=0
response="$(curl -sS -X POST --max-time "$CURL_TIMEOUT" -w '\n__HTTP_CODE__%{http_code}' "$SYNC_URL" 2>/dev/null)" || {
  curl_exit=$?
  log "sync failed: curl exit $curl_exit"
  if [[ "$JSON_OUTPUT" == "1" ]]; then
    printf '{"ok":false,"error":"curl_exit_%d","reason":"request_failed"}\n' "$curl_exit"
  fi
  exit 1
}

# Separate body from HTTP status
http_code="$(printf '%s' "$response" | grep -o '__HTTP_CODE__[0-9]*' | sed 's/__HTTP_CODE__//' || echo 0)"
body="$(printf '%s' "$response" | sed '/^__HTTP_CODE__/d')"

if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
  log "sync failed: HTTP $http_code"
  if [[ "$JSON_OUTPUT" == "1" ]]; then
    printf '{"ok":false,"error":"http_%d","body":%s}\n' "$http_code" "$(printf '%s' "$body" | node -e 'try{process.stdout.write(JSON.stringify(require("fs").readFileSync(0,"utf8")))}catch{process.stdout.write("null")}' 2>/dev/null || echo 'null')"
  fi
  exit 1
fi

# ── Parse result ─────────────────────────────────────────────────────────

# Extract key fields for logging
parsed="$(printf '%s' "$body" | node -e '
  try {
    const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const parts = [
      "ok=" + r.ok,
      "endpoint=" + (r.endpoint || "unknown"),
      "items=" + (r.totalItems || 0),
      "eligible=" + (r.eligibleItems || 0),
    ];
    if (r.offline) parts.push("offline=true");
    if (r.skipped) parts.push("skipped=true");
    if (r.fallbackReason) parts.push("fallback=" + r.fallbackReason);
    process.stdout.write(parts.join(" "));
  } catch(e) {
    process.stdout.write("parse_error");
  }
' 2>/dev/null || echo "parse_error")"

if [[ "$parsed" == *"parse_error"* ]]; then
  log "sync completed but response was unparseable"
else
  log "sync completed: $parsed"
fi

if [[ "$VERBOSE" == "1" || "$JSON_OUTPUT" == "1" ]]; then
  printf '%s\n' "$body"
fi

# Determine exit code based on response
ok="$(printf '%s' "$body" | node -e '
  try {
    const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
    process.stdout.write(String(r.ok === true));
  } catch { process.stdout.write("false"); }
' 2>/dev/null || echo "false")"

skipped="$(printf '%s' "$body" | node -e '
  try {
    const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
    process.stdout.write(String(r.skipped === true));
  } catch { process.stdout.write("false"); }
' 2>/dev/null || echo "false")"

if [[ "$ok" == "true" || "$skipped" == "true" ]]; then
  exit 0
fi

exit 1
