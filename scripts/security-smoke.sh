#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${AUTOPOIESIS_SECURITY_SMOKE_PORT:-3130}"
BASE_URL="http://127.0.0.1:${PORT}"
SECRET="security-smoke-secret-$$-$(date +%s)"
TMP_DIR="$(mktemp -d)"
SERVER_PID=""

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "security smoke failed: $*" >&2
  if [[ -f "$TMP_DIR/server.log" ]]; then
    echo "--- local-ui log ---" >&2
    sed -n '1,120p' "$TMP_DIR/server.log" >&2
  fi
  exit 1
}

mkdir -p "$TMP_DIR/data"
node -e "const fs=require('fs');const dir=process.argv[1];const secret=process.argv[2];fs.writeFileSync(dir+'/device.json', JSON.stringify({deviceId:'rpi-security-smoke',deviceName:'Security Smoke Frame',paired:true,firstRunComplete:true,framesUrl:'http://127.0.0.1:1/frames',apiBaseUrl:'http://127.0.0.1:1/api',deviceApiKey:secret}, null, 2)+'\\n');fs.writeFileSync(dir+'/pairing.json', JSON.stringify({pairingCode:'SAFE-0001',mock:false,status:'paired'}, null, 2)+'\\n');" "$TMP_DIR/data" "$SECRET"

AUTOPOIESIS_DATA_DIR="$TMP_DIR/data" \
AUTOPOIESIS_LOG_DIR="$TMP_DIR/log" \
AUTOPOIESIS_CACHE_DIR="$TMP_DIR/cache" \
AUTOPOIESIS_PORT="$PORT" \
AUTOPOIESIS_API_TIMEOUT_MS=200 \
AUTOPOIESIS_LAUNCH_PROBE_TIMEOUT_MS=100 \
  node "$ROOT_DIR/local-ui/server.js" >"$TMP_DIR/server.log" 2>&1 &
SERVER_PID="$!"

for _ in {1..50}; do
  if curl -fsS "$BASE_URL/local/status" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

curl -fsS "$BASE_URL/local/status" >"$TMP_DIR/status.json" || fail "GET /local/status failed"
curl -fsS "$BASE_URL/local/pairing/status" >"$TMP_DIR/pairing-status.json" || fail "GET /local/pairing/status failed"
curl -fsS "$BASE_URL/local/diagnostics" >"$TMP_DIR/diagnostics.json" || fail "GET /local/diagnostics failed"
curl -fsS "$BASE_URL/local/health" >"$TMP_DIR/health.json" || fail "GET /local/health failed"
curl -fsS "$BASE_URL/local/readiness" >"$TMP_DIR/readiness.json" || fail "GET /local/readiness failed"
curl -fsS "$BASE_URL/local/offline-cache" >"$TMP_DIR/offline-cache.json" || fail "GET /local/offline-cache failed"
curl -fsS "$BASE_URL/local/commands/audit" >"$TMP_DIR/command-audit.json" || fail "GET /local/commands/audit failed"

COMBINED="$TMP_DIR/combined.json"
cat "$TMP_DIR/status.json" "$TMP_DIR/pairing-status.json" "$TMP_DIR/diagnostics.json" "$TMP_DIR/health.json" "$TMP_DIR/readiness.json" "$TMP_DIR/offline-cache.json" "$TMP_DIR/command-audit.json" >"$COMBINED"

if grep -F "$SECRET" "$COMBINED" >/dev/null; then
  fail "stored device API key leaked through a local JSON endpoint"
fi

if grep -E '"deviceApiKey"|"device_api_key"' "$COMBINED" >/dev/null; then
  fail "device API key field name leaked through a local JSON endpoint"
fi

grep -F '"hasDeviceApiKey": true' "$TMP_DIR/status.json" >/dev/null || fail "/local/status did not expose redacted key presence"
grep -F '"deviceKeyPresent": true' "$TMP_DIR/diagnostics.json" >/dev/null || fail "/local/diagnostics did not expose health key presence"
grep -F '"deviceKeyPresent": true' "$TMP_DIR/health.json" >/dev/null || fail "/local/health did not expose health key presence"
grep -F '"deviceKeyPresent": true' "$TMP_DIR/readiness.json" >/dev/null || fail "/local/readiness did not expose redacted key presence"

if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  TRACKED_SENSITIVE="$(git -C "$ROOT_DIR" ls-files | grep -E '(^|/)(\.env|.*\.pem|.*\.key|secrets?)(/|$)' || true)"
  if [[ -n "$TRACKED_SENSITIVE" ]]; then
    echo "$TRACKED_SENSITIVE" >&2
    fail "sensitive-looking files are tracked"
  fi
fi

echo "security smoke passed: local status, pairing status, diagnostics, health, readiness, offline cache, and command audit redact device API keys"
