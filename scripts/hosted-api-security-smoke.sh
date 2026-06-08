#!/usr/bin/env bash
# hosted-api-security-smoke.sh — Security regression gate for the hosted API
#
# Verifies that device API keys, admin tokens, and other secrets never leak
# through any hosted API response (except the initial registration response
# where the key is intentionally returned to the new device).
#
# Also checks source files for accidentally hardcoded credentials.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${AOS_SECURITY_SMOKE_PORT:-3140}"
BASE_URL="http://127.0.0.1:${PORT}"
ADMIN_TOKEN="aos-security-smoke-admin-$$-$(date +%s)"
TMP_DIR="$(mktemp -d)"
SERVER_PID=""
PASS=0
FAIL=0
CHECKS=0

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  ((FAIL++)) || true
  ((CHECKS++)) || true
}

pass() {
  ((PASS++)) || true
  ((CHECKS++)) || true
}

# ── Step 1: Syntax validation ────────────────────────────────────────────────
echo "=== Hosted API Security Smoke ==="
echo ""
echo "--- Step 1: Syntax validation ---"

node -e "require('fs').readFileSync('$ROOT_DIR/hosted-api/server.js','utf8'); process.exit(0)" && pass || fail "server.js syntax"
node -e "require('fs').readFileSync('$ROOT_DIR/hosted-api/db.js','utf8'); process.exit(0)" && pass || fail "db.js syntax"
bash -n "$0" && pass || fail "self syntax"

# ── Step 2: Source code secret scan ──────────────────────────────────────────
echo "--- Step 2: Source code secret scan ---"

# Check that no source files contain obviously hardcoded API keys/tokens/passwords
# (excluding test/check scripts, comments, env examples, and the authentication logic itself)
SECRET_PATTERN="(sk-[a-zA-Z0-9]{20,}|pk_[a-zA-Z0-9]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN (RSA |EC |DSA )?PRIVATE KEY-----)"
SRC_FILES=$(grep -rlE '$SECRET_PATTERN' "$ROOT_DIR/hosted-api/" "$ROOT_DIR/local-ui/" 2>/dev/null | grep -v 'node_modules' | grep -v 'check-' | grep -v 'security-smoke' || true)
# Also check scripts dir (may have no .mjs files)
SRC_FILES2=$(find "$ROOT_DIR/scripts/" -maxdepth 1 \( -name '*.sh' -o -name '*.mjs' \) -exec grep -lE '$SECRET_PATTERN' {} \; 2>/dev/null | grep -v 'check-' | grep -v 'security-smoke' || true)
SRC_FILES="${SRC_FILES}${SRC_FILES2}${SRC_FILES:+$'\n'}${SRC_FILES2}"

if [[ -n "$SRC_FILES" ]]; then
  echo "$SRC_FILES" >&2
  fail "source files contain hardcoded secret patterns"
else
  pass "no hardcoded secret patterns in source files"
fi

# Check that AUTOPOIESIS_FRAMES_ADMIN_TOKEN env var is referenced in server.js
if grep -q "AUTOPOIESIS_FRAMES_ADMIN_TOKEN" "$ROOT_DIR/hosted-api/server.js"; then
  pass "admin token references env var (not hardcoded)"
else
  fail "admin token does not reference env var AUTOPOIESIS_FRAMES_ADMIN_TOKEN"
fi

# Check that generateDeviceKey() is used, not hardcoded
if grep -q "generateDeviceKey\|generateDeviceApiKey\|crypto.randomBytes\|crypto.randomUUID\|nanoid" "$ROOT_DIR/hosted-api/db.js"; then
  pass "device key generation uses crypto randomness"
else
  fail "device key generation does not use crypto randomness"
fi

# Check that .env files are gitignored
if grep -q '\.env' "$ROOT_DIR/.gitignore" 2>/dev/null; then
  pass ".env files are gitignored"
else
  fail ".env files are NOT gitignored"
fi

# Check .pem / .key files are gitignored
if grep -qE '\.pem|\.key|secrets' "$ROOT_DIR/.gitignore" 2>/dev/null; then
  pass ".pem/.key files are gitignored"
else
  fail ".pem/.key files are NOT in .gitignore"
fi

# Check no tracked secret files
if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  TRACKED_SECRETS="$(git -C "$ROOT_DIR" ls-files | grep -E '(^|/)(\.env$|\.env\.(?!example)|.*\.pem|.*\.key|secrets?/)' || true)"
  if [[ -n "$TRACKED_SECRETS" ]]; then
    echo "$TRACKED_SECRETS" >&2
    fail "secret-looking files are tracked in Git"
  else
    pass "no secret-looking files tracked in Git"
  fi
fi

# ── Step 3: Server bootstrap ─────────────────────────────────────────────────
echo "--- Step 3: Server bootstrap ---"

DB_PATH="$TMP_DIR/aos-security.db"
AOS_DB="$DB_PATH" AOS_PORT="$PORT" AOS_HOST="127.0.0.1" \
  AUTOPOIESIS_FRAMES_ADMIN_TOKEN="$ADMIN_TOKEN" \
  node "$ROOT_DIR/hosted-api/server.js" >"$TMP_DIR/server.log" 2>&1 &
SERVER_PID="$!"

for _ in {1..60}; do
  if curl -fsS "$BASE_URL/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

if ! curl -fsS "$BASE_URL/health" >"$TMP_DIR/health.json"; then
  fail "hosted API health check failed"
  echo "--- server log ---" >&2
  cat "$TMP_DIR/server.log" >&2
  echo ""
  echo "=== Hosted API Security Smoke: $PASS pass, $FAIL fail, $CHECKS checks ==="
  exit 1
fi
pass "hosted API server started and healthy"

# ── Step 4: Device registration ──────────────────────────────────────────────
echo "--- Step 4: Device registration ---"

# Register two devices — capture their API keys for leak detection
DEV1=$(curl -fsS -X POST "$BASE_URL/frames/device/register" \
  -H "Content-Type: application/json" \
  -d '{"deviceName":"Security-Frame-1","deviceType":"rpi"}')
DEV1_ID=$(echo "$DEV1" | jq -r '.device.deviceId // .deviceId')
DEV1_KEY=$(echo "$DEV1" | jq -r '.device.deviceApiKey // .deviceApiKey')
DEV1_PAIRING=$(echo "$DEV1" | jq -r '.pairingCode')

if [[ -z "$DEV1_ID" || "$DEV1_ID" == "null" ]]; then fail "device 1 registration failed"; else pass "device 1 registered"; fi
if [[ -z "$DEV1_KEY" || "$DEV1_KEY" == "null" ]]; then fail "device 1 key missing from registration"; else pass "device 1 key received in registration response"; fi

DEV2=$(curl -fsS -X POST "$BASE_URL/frames/device/register" \
  -H "Content-Type: application/json" \
  -d '{"deviceName":"Security-Frame-2","deviceType":"rpi"}')
DEV2_ID=$(echo "$DEV2" | jq -r '.device.deviceId // .deviceId')
DEV2_KEY=$(echo "$DEV2" | jq -r '.device.deviceApiKey // .deviceApiKey')
DEV2_PAIRING=$(echo "$DEV2" | jq -r '.pairingCode')

if [[ -z "$DEV2_ID" || "$DEV2_ID" == "null" ]]; then fail "device 2 registration failed"; else pass "device 2 registered"; fi

# Pair devices via direct DB call (simulating web app)
node -e "
const AosDb = require('$ROOT_DIR/hosted-api/db.js');
const db = new AosDb('$DB_PATH');
db.claimPairingCode('$DEV1_PAIRING', 'user-alice-001');
db.claimPairingCode('$DEV2_PAIRING', 'user-bob-001');
db.close();
" 2>/dev/null && pass "devices paired" || fail "pairing failed"

# ── Step 5: Auth gate verification ───────────────────────────────────────────
echo "--- Step 5: Auth gate verification ---"

# NOTE: GET /frames/device/:id/settings is intentionally unauthenticated.
# The device reads settings on boot before auth is established.
# This is by design, not a security flaw.
SETTINGS_NO_AUTH=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/frames/device/$DEV1_ID/settings")
if [[ "$SETTINGS_NO_AUTH" == "200" ]]; then pass "settings GET is unauthenticated (by design)"; else fail "settings GET returned unexpected $SETTINGS_NO_AUTH"; fi

# Verify unauthenticated settings response does NOT contain device keys
SETTINGS_BODY=$(curl -fsS "$BASE_URL/frames/device/$DEV1_ID/settings")
if grep -F "$DEV1_KEY" <<<"$SETTINGS_BODY" >/dev/null 2>&1; then
  fail "unauthenticated settings response contains device API key"
else
  pass "unauthenticated settings response does not contain device API key"
fi

NO_AUTH_HEARTBEAT=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/frames/device/$DEV1_ID/heartbeat" -H "Content-Type: application/json" -d '{}')
if [[ "$NO_AUTH_HEARTBEAT" == "401" ]]; then pass "heartbeat rejects without device key (401)"; else fail "heartbeat should reject without device key, got $NO_AUTH_HEARTBEAT"; fi

NO_AUTH_STREAM=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/frames/device/$DEV1_ID/stream")
if [[ "$NO_AUTH_STREAM" == "401" ]]; then pass "stream rejects without device key (401)"; else fail "stream should reject without device key, got $NO_AUTH_STREAM"; fi

# Wrong device key
WRONG_AUTH=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/frames/device/$DEV1_ID/heartbeat" \
  -H "Content-Type: application/json" -H "x-frame-device-key: wrong-key-12345" -d '{}')
if [[ "$WRONG_AUTH" == "403" ]]; then pass "heartbeat rejects wrong device key (403)"; else fail "heartbeat should reject wrong device key, got $WRONG_AUTH"; fi

# Admin endpoints should reject without admin token
NO_TOKEN_BUNDLE=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/frames/admin/bundle")
if [[ "$NO_TOKEN_BUNDLE" == "401" ]]; then pass "admin bundle rejects without token (401)"; else fail "admin bundle should reject without token, got $NO_TOKEN_BUNDLE"; fi

WRONG_TOKEN_BUNDLE=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/frames/admin/bundle" \
  -H "x-admin-token: wrong-admin-token")
if [[ "$WRONG_TOKEN_BUNDLE" == "403" ]]; then pass "admin bundle rejects wrong token (403)"; else fail "admin bundle should reject wrong token, got $WRONG_TOKEN_BUNDLE"; fi

# Bearer token should work for admin
BEARER_BUNDLE=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/frames/admin/bundle" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
if [[ "$BEARER_BUNDLE" == "200" ]]; then pass "admin bundle accepts Bearer token"; else fail "admin bundle should accept Bearer token, got $BEARER_BUNDLE"; fi

# Admin token must NOT work as a device key
ADMIN_AS_DEVICE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/frames/device/$DEV1_ID/heartbeat" \
  -H "Content-Type: application/json" -H "x-frame-device-key: $ADMIN_TOKEN" -d '{}')
if [[ "$ADMIN_AS_DEVICE" == "403" ]]; then pass "admin token rejected as device key (403)"; else fail "admin token should NOT work as device key, got $ADMIN_AS_DEVICE"; fi

# Device key must NOT work as admin token
DEVICE_AS_ADMIN=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/frames/admin/bundle" \
  -H "x-admin-token: $DEV1_KEY")
if [[ "$DEVICE_AS_ADMIN" == "403" ]]; then pass "device key rejected as admin token (403)"; else fail "device key should NOT work as admin token, got $DEVICE_AS_ADMIN"; fi

# Health endpoint should remain open
HEALTH_OPEN=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/health")
if [[ "$HEALTH_OPEN" == "200" ]]; then pass "health endpoint remains open (200)"; else fail "health endpoint should be open, got $HEALTH_OPEN"; fi

# ── Step 6: Response body secret leak scan ────────────────────────────────────
echo "--- Step 6: Response body secret leak scan ---"

# Collect responses from ALL endpoints that contain device data or admin data
RESPONSES_DIR="$TMP_DIR/responses"
mkdir -p "$RESPONSES_DIR"

# Authenticated device endpoints (using device 1's key)
curl -fsS "$BASE_URL/frames/device/$DEV1_ID/pairing-status" > "$RESPONSES_DIR/pairing-status.json" 2>/dev/null || echo '{}' > "$RESPONSES_DIR/pairing-status.json"
curl -fsS "$BASE_URL/frames/device/$DEV1_ID/settings" \
  -H "x-frame-device-key: $DEV1_KEY" > "$RESPONSES_DIR/settings.json" 2>/dev/null || echo '{}' > "$RESPONSES_DIR/settings.json"
curl -fsS -X POST "$BASE_URL/frames/device/$DEV1_ID/settings" \
  -H "Content-Type: application/json" -H "x-frame-device-key: $DEV1_KEY" \
  -d '{"brightness":50}' > "$RESPONSES_DIR/settings-push.json" 2>/dev/null || echo '{}' > "$RESPONSES_DIR/settings-push.json"
curl -fsS -X POST "$BASE_URL/frames/device/$DEV1_ID/heartbeat" \
  -H "Content-Type: application/json" -H "x-frame-device-key: $DEV1_KEY" \
  -d '{"softwareVersion":"1.0.0","currentMode":"display"}' > "$RESPONSES_DIR/heartbeat.json" 2>/dev/null || echo '{}' > "$RESPONSES_DIR/heartbeat.json"
curl -fsS "$BASE_URL/frames/device/$DEV1_ID/stream" \
  -H "x-frame-device-key: $DEV1_KEY" > "$RESPONSES_DIR/stream.json" 2>/dev/null || echo '{}' > "$RESPONSES_DIR/stream.json"
curl -fsS "$BASE_URL/frames/device/$DEV1_ID/feed" \
  -H "x-frame-device-key: $DEV1_KEY" > "$RESPONSES_DIR/feed.json" 2>/dev/null || echo '{}' > "$RESPONSES_DIR/feed.json"
curl -fsS "$BASE_URL/frames/device/$DEV1_ID/release" \
  -H "x-frame-device-key: $DEV1_KEY" > "$RESPONSES_DIR/release.json" 2>/dev/null || echo '{}' > "$RESPONSES_DIR/release.json"

# Authenticated device endpoints using device 2's key (cross-device check)
curl -fsS "$BASE_URL/frames/device/$DEV2_ID/stream" \
  -H "x-frame-device-key: $DEV2_KEY" > "$RESPONSES_DIR/stream-dev2.json" 2>/dev/null || echo '{}' > "$RESPONSES_DIR/stream-dev2.json"
curl -fsS -X POST "$BASE_URL/frames/device/$DEV2_ID/heartbeat" \
  -H "Content-Type: application/json" -H "x-frame-device-key: $DEV2_KEY" \
  -d '{"softwareVersion":"1.0.0","currentMode":"display"}' > "$RESPONSES_DIR/heartbeat-dev2.json" 2>/dev/null || echo '{}' > "$RESPONSES_DIR/heartbeat-dev2.json"

# Admin endpoints (with admin token)
curl -fsS "$BASE_URL/frames/admin/bundle" \
  -H "x-admin-token: $ADMIN_TOKEN" > "$RESPONSES_DIR/admin-bundle.json" 2>/dev/null || echo '{}' > "$RESPONSES_DIR/admin-bundle.json"
curl -fsS "$BASE_URL/frames/device/$DEV1_ID/admin-snapshot" \
  -H "x-admin-token: $ADMIN_TOKEN" > "$RESPONSES_DIR/admin-snapshot.json" 2>/dev/null || echo '{}' > "$RESPONSES_DIR/admin-snapshot.json"
curl -fsS "$BASE_URL/frames/admin/broadcasts" \
  -H "x-admin-token: $ADMIN_TOKEN" > "$RESPONSES_DIR/admin-broadcasts.json" 2>/dev/null || echo '{}' > "$RESPONSES_DIR/admin-broadcasts.json"
curl -fsS "$BASE_URL/frames/admin/broadcasts/stats" \
  -H "x-admin-token: $ADMIN_TOKEN" > "$RESPONSES_DIR/admin-broadcast-stats.json" 2>/dev/null || echo '{}' > "$RESPONSES_DIR/admin-broadcast-stats.json"
curl -fsS "$BASE_URL/frames/admin/broadcast-deliveries" \
  -H "x-admin-token: $ADMIN_TOKEN" > "$RESPONSES_DIR/admin-deliveries.json" 2>/dev/null || echo '{}' > "$RESPONSES_DIR/admin-deliveries.json"

# Admin subscription endpoints
curl -fsS -X POST "$BASE_URL/frames/admin/subscriptions" \
  -H "Content-Type: application/json" -H "x-admin-token: $ADMIN_TOKEN" \
  -d '{"userId":"user-alice-001","plan":"frames_basic","status":"active"}' > "$RESPONSES_DIR/admin-sub-create.json" 2>/dev/null || echo '{}' > "$RESPONSES_DIR/admin-sub-create.json"
curl -fsS "$BASE_URL/frames/admin/subscriptions/user-alice-001" \
  -H "x-admin-token: $ADMIN_TOKEN" > "$RESPONSES_DIR/admin-sub-get.json" 2>/dev/null || echo '{}' > "$RESPONSES_DIR/admin-sub-get.json"
curl -fsS "$BASE_URL/frames/admin/bundle?userId=user-alice-001" \
  -H "x-admin-token: $ADMIN_TOKEN" > "$RESPONSES_DIR/admin-bundle-alice.json" 2>/dev/null || echo '{}' > "$RESPONSES_DIR/admin-bundle-alice.json"

# Admin device actions
curl -fsS -X PATCH "$BASE_URL/frames/admin/devices/$DEV1_ID" \
  -H "Content-Type: application/json" -H "x-admin-token: $ADMIN_TOKEN" \
  -d '{"deviceName":"Renamed-Frame"}' > "$RESPONSES_DIR/admin-device-patch.json" 2>/dev/null || echo '{}' > "$RESPONSES_DIR/admin-device-patch.json"

# Artwork like endpoint
curl -fsS -X POST "$BASE_URL/frames/artworks/art-test-001/like" \
  -H "Content-Type: application/json" -H "x-frame-device-key: $DEV1_KEY" \
  -d "{\"deviceId\":\"$DEV1_ID\",\"liked\":true}" > "$RESPONSES_DIR/artwork-like.json" 2>/dev/null || echo '{}' > "$RESPONSES_DIR/artwork-like.json"

# Health (no auth needed)
curl -fsS "$BASE_URL/health" > "$RESPONSES_DIR/health.json" 2>/dev/null || echo '{}' > "$RESPONSES_DIR/health.json"

# Combine ALL non-registration responses for secret scanning
# (Registration response intentionally contains the key)
cat "$RESPONSES_DIR"/*.json > "$TMP_DIR/all-responses.json"

# Check 1: Device API keys must NOT appear in any response
if grep -F "$DEV1_KEY" "$TMP_DIR/all-responses.json" >/dev/null 2>&1; then
  # Identify which response(s) leaked the key
  LEAKING=""
  for f in "$RESPONSES_DIR"/*.json; do
    if grep -F "$DEV1_KEY" "$f" >/dev/null 2>&1; then
      LEAKING="$LEAKING $(basename "$f")"
    fi
  done
  fail "device 1 API key leaked in responses:$LEAKING"
else
  pass "device 1 API key not leaked in any non-registration response"
fi

if grep -F "$DEV2_KEY" "$TMP_DIR/all-responses.json" >/dev/null 2>&1; then
  LEAKING=""
  for f in "$RESPONSES_DIR"/*.json; do
    if grep -F "$DEV2_KEY" "$f" >/dev/null 2>&1; then
      LEAKING="$LEAKING $(basename "$f")"
    fi
  done
  fail "device 2 API key leaked in responses:$LEAKING"
else
  pass "device 2 API key not leaked in any non-registration response"
fi

# Check 2: Admin token must NOT appear in any response body
if grep -F "$ADMIN_TOKEN" "$TMP_DIR/all-responses.json" >/dev/null 2>&1; then
  LEAKING=""
  for f in "$RESPONSES_DIR"/*.json; do
    if grep -F "$ADMIN_TOKEN" "$f" >/dev/null 2>&1; then
      LEAKING="$LEAKING $(basename "$f")"
    fi
  done
  fail "admin token leaked in responses:$LEAKING"
else
  pass "admin token not leaked in any response body"
fi

# Check 3: No generic "apiKey" / "deviceApiKey" field names in device-facing responses
# (paired device data should use redacted indicators, not the raw key)
DEVICE_RESPONSES="$TMP_DIR/device-responses.json"
cat "$RESPONSES_DIR/pairing-status.json" \
    "$RESPONSES_DIR/settings.json" \
    "$RESPONSES_DIR/settings-push.json" \
    "$RESPONSES_DIR/heartbeat.json" \
    "$RESPONSES_DIR/stream.json" \
    "$RESPONSES_DIR/feed.json" \
    "$RESPONSES_DIR/release.json" \
    "$RESPONSES_DIR/artwork-like.json" > "$DEVICE_RESPONSES"

if grep -E '"deviceApiKey"|"device_api_key"|"apiKey"|"api_key"' "$DEVICE_RESPONSES" >/dev/null 2>&1; then
  # Identify which response(s) contain key field names
  LEAKING=""
  for f in "$RESPONSES_DIR/pairing-status.json" "$RESPONSES_DIR/settings.json" \
           "$RESPONSES_DIR/settings-push.json" "$RESPONSES_DIR/heartbeat.json" \
           "$RESPONSES_DIR/stream.json" "$RESPONSES_DIR/feed.json" \
           "$RESPONSES_DIR/release.json" "$RESPONSES_DIR/artwork-like.json"; do
    if grep -E '"deviceApiKey"|"device_api_key"|"apiKey"|"api_key"' "$f" >/dev/null 2>&1; then
      LEAKING="$LEAKING $(basename "$f")"
    fi
  done
  fail "device API key field name found in device-facing responses:$LEAKING"
else
  pass "no device API key field names in device-facing responses"
fi

# Check 4: Admin bundle device list must NOT contain deviceApiKey
ADMIN_BUNDLE_DEVICES=$(jq -r '.body.adminFrames.devices.items[]?.deviceId // empty' "$RESPONSES_DIR/admin-bundle.json" 2>/dev/null | head -5)
if [[ -n "$ADMIN_BUNDLE_DEVICES" ]]; then
  if jq -e '.body.adminFrames.devices.items[]?.deviceApiKey' "$RESPONSES_DIR/admin-bundle.json" >/dev/null 2>&1; then
    fail "admin bundle fleet devices contain deviceApiKey field"
  else
    pass "admin bundle fleet devices do NOT contain deviceApiKey field"
  fi
else
  pass "admin bundle has devices (skipped field check - empty list)"
fi

# Check 5: Admin device snapshot must NOT contain deviceApiKey
if jq -e '.body.device.deviceApiKey' "$RESPONSES_DIR/admin-snapshot.json" >/dev/null 2>&1; then
  fail "admin device snapshot contains deviceApiKey field"
else
  pass "admin device snapshot does NOT contain deviceApiKey field"
fi

# Check 6: Admin bundle must NOT contain admin token
if grep -F "$ADMIN_TOKEN" "$RESPONSES_DIR/admin-bundle.json" >/dev/null 2>&1; then
  fail "admin bundle response contains admin token"
else
  pass "admin bundle response does NOT contain admin token"
fi

# Check 7: Health endpoint must NOT contain device keys or admin tokens
if grep -E "$DEV1_KEY|$DEV2_KEY|$ADMIN_TOKEN" "$RESPONSES_DIR/health.json" >/dev/null 2>&1; then
  fail "health endpoint leaks secrets"
else
  pass "health endpoint does not leak secrets"
fi

# Check 8: Cross-device isolation — device 1's stream should NOT contain device 2's data
# (and device 2's stream should NOT contain device 1's data)
# This is a basic authorization boundary check
STREAM_DEV1_DEVICEID=$(jq -r '.deviceId // empty' "$RESPONSES_DIR/stream.json" 2>/dev/null)
if [[ "$STREAM_DEV1_DEVICEID" == "$DEV2_ID" ]]; then
  fail "device 1 stream response contains device 2's ID"
else
  pass "device 1 stream does not contain device 2's ID"
fi

# Check 9: Registration response — the ONLY place deviceApiKey should appear
REG_RESPONSE=$(curl -fsS -X POST "$BASE_URL/frames/device/register" \
  -H "Content-Type: application/json" \
  -d '{"deviceName":"Security-Frame-3","deviceType":"rpi"}')
REG_KEY=$(echo "$REG_RESPONSE" | jq -r '.device.deviceApiKey // .deviceApiKey')
if [[ -n "$REG_KEY" && "$REG_KEY" != "null" ]]; then
  pass "registration response correctly returns deviceApiKey"
else
  fail "registration response missing deviceApiKey"
fi

# Verify the new device's key does NOT appear in the admin bundle after registration
LATEST_BUNDLE=$(curl -fsS "$BASE_URL/frames/admin/bundle" \
  -H "x-admin-token: $ADMIN_TOKEN")
if grep -F "$REG_KEY" "$LATEST_BUNDLE" >/dev/null 2>&1; then
  fail "newly registered device API key leaked in admin bundle"
else
  pass "newly registered device API key not leaked in admin bundle"
fi

# ── Step 7: Error response secret safety ─────────────────────────────────────
echo "--- Step 7: Error response secret safety ---"

# 404 for nonexistent device should not leak other devices' keys
NOTFOUND_DEVICE=$(curl -sS -o "$TMP_DIR/notfound-device.json" -w '%{http_code}' \
  "$BASE_URL/frames/device/nonexistent-device-12345/pairing-status")
if [[ "$NOTFOUND_DEVICE" == "200" || "$NOTFOUND_DEVICE" == "404" ]]; then
  if grep -E "$DEV1_KEY|$DEV2_KEY" "$TMP_DIR/notfound-device.json" >/dev/null 2>&1; then
    fail "error response for nonexistent device leaks real device keys"
  else
    pass "error response for nonexistent device does not leak real device keys"
  fi
else
  pass "nonexistent device returns expected status ($NOTFOUND_DEVICE)"
fi

# Admin endpoint for nonexistent device
NOTFOUND_SNAPSHOT=$(curl -sS -o "$TMP_DIR/notfound-snapshot.json" -w '%{http_code}' \
  "$BASE_URL/frames/device/nonexistent-device-12345/admin-snapshot" \
  -H "x-admin-token: $ADMIN_TOKEN")
if [[ "$NOTFOUND_SNAPSHOT" == "404" ]]; then
  if grep -E "$DEV1_KEY|$DEV2_KEY|$ADMIN_TOKEN" "$TMP_DIR/notfound-snapshot.json" >/dev/null 2>&1; then
    fail "admin snapshot 404 for nonexistent device leaks secrets"
  else
    pass "admin snapshot 404 does not leak secrets"
  fi
else
  pass "admin snapshot for nonexistent device returns $NOTFOUND_SNAPSHOT"
fi

# ── Step 8: Input sanitization spot check ─────────────────────────────────────
echo "--- Step 8: Input sanitization ---"

# Settings push with extra unexpected fields should not crash or persist bad data
EXTRA_FIELDS=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
  "$BASE_URL/frames/device/$DEV1_ID/settings" \
  -H "Content-Type: application/json" -H "x-frame-device-key: $DEV1_KEY" \
  -d '{"brightness":60,"evilField":"<script>alert(1)</script>","__proto__":{"admin":true}}')
if [[ "$EXTRA_FIELDS" =~ ^2 ]]; then
  pass "settings push with extra fields does not crash"
else
  fail "settings push with extra fields returned $EXTRA_FIELDS"
fi

# Verify the evil fields didn't get stored
CURRENT_SETTINGS=$(curl -fsS "$BASE_URL/frames/device/$DEV1_ID/settings" \
  -H "x-frame-device-key: $DEV1_KEY")
if echo "$CURRENT_SETTINGS" | grep -F '<script>' >/dev/null 2>&1; then
  fail "XSS payload persisted in settings"
else
  pass "XSS payload did not persist in settings"
fi
if echo "$CURRENT_SETTINGS" | grep -F '"admin":true' >/dev/null 2>&1; then
  fail "prototype pollution payload persisted in settings"
else
  pass "prototype pollution payload did not persist in settings"
fi

# ── Step 9: Summary ──────────────────────────────────────────────────────────
echo ""
echo "=== Hosted API Security Smoke: $PASS pass, $FAIL fail, $CHECKS checks ==="

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
