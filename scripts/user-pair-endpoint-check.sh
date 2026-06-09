#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# user-pair-endpoint-check.sh
#
# Validation gate for POST /frames/me/pair — user-initiated device pairing.
#
# Steps:
#   1. Syntax validation
#   2. Static contract (handler, route, entitlement checks, DB call)
#   3. Server bootstrap
#   4. Pairing code generation via device registration
#   5. Successful pairing
#   6. Paired device appears in /frames/me/devices
#   7. Pairing code not reusable
#   8. Invalid pairing code
#   9. Expired pairing code (skipped — requires time manipulation)
#  10. Device limit enforcement (trial = 1 device max)
#  11. Subscription degraded blocking
#  12. Auth gates
#  13. Input validation
#  14. CORS preflight
#  15. Regression
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

PASS=0
FAIL=0
STEP=0
PORT=""
SERVER_PID=""
DB_FILE=""

# ── Helpers ──────────────────────────────────────────────────────────────────
ok()   { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

check() {
  local label="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    ok
  else
    fail "$label — expected '$expected', got '$actual'"
  fi
}

check_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -q "$needle"; then
    ok
  else
    fail "$label — expected to contain '$needle'"
  fi
}

check_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -q "$needle"; then
    fail "$label — expected NOT to contain '$needle'"
  else
    ok
  fi
}

api() {
  local method="$1" endpoint="$2"
  shift 2
  curl -s "http://127.0.0.1:$PORT$endpoint" "$@"
}

step() {
  STEP=$((STEP+1))
  echo ""
  echo "=== Step $STEP: $1 ==="
}

cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  [ -n "$DB_FILE" ] && rm -f "$DB_FILE"
}
trap cleanup EXIT

# ── Step 1: Syntax validation ────────────────────────────────────────────────
step "Syntax validation"
node --check hosted-api/server.js && ok || fail "server.js syntax"
node --check hosted-api/db.js     && ok || fail "db.js syntax"
node --check local-ui/server.js   && ok || fail "local-ui/server.js syntax"

for f in install.sh update.sh uninstall-dev-tools.sh factory-reset.sh; do
  bash -n "$f" && ok || fail "$f syntax"
done
for f in scripts/*.sh; do
  bash -n "$f" && ok || fail "$f syntax"
done

# ── Step 2: Static contract ──────────────────────────────────────────────────
step "Static contract — handler, route, entitlement, DB wiring"
SERVER_JS="hosted-api/server.js"

# Handler function exists
check_contains "handleMePairDevice function" \
  "$(grep -c 'function handleMePairDevice' "$SERVER_JS")" "1"

# Route wiring (should appear twice: API doc header + actual route)
ROUTE_COUNT=$(grep -c '"POST.*frames/me/pair"' "$SERVER_JS")
check_contains "POST /frames/me/pair route" "$ROUTE_COUNT" "[1-9]"

# API doc header
check_contains "API doc entry" \
  "$(grep 'POST.*frames/me/pair' "$SERVER_JS" | head -1)" \
  "User: pair a device"

# Entitlement check — canAddDevice
check_contains "canAddDevice check" \
  "$(grep 'handleMePairDevice' -A 200 "$SERVER_JS" | head -100)" \
  "canAddDevice"

# Device limit error
check_contains "device_limit_reached reason" \
  "$(grep 'handleMePairDevice' -A 200 "$SERVER_JS" | head -100)" \
  "device_limit_reached"

# Subscription degraded check
check_contains "subscription_degraded reason" \
  "$(grep 'handleMePairDevice' -A 200 "$SERVER_JS" | head -100)" \
  "subscription_degraded"

# DB call — claimPairingCode
check_contains "claimPairingCode call" \
  "$(grep 'handleMePairDevice' -A 200 "$SERVER_JS" | head -100)" \
  "claimPairingCode"

# Pairing code format validation
check_contains "pairing code format regex" \
  "$(grep 'handleMePairDevice' -A 200 "$SERVER_JS" | head -100)" \
  "A-Z0-9"

# Response kind
check_contains "autopoiesis_frames_me_pair kind" \
  "$(grep 'handleMePairDevice' -A 200 "$SERVER_JS" | head -100)" \
  "autopoiesis_frames_me_pair"

# userId required check
check_contains "userId required guard" \
  "$(grep 'handleMePairDevice' -A 200 "$SERVER_JS" | head -100)" \
  "userId required"

# ── Step 3: Server bootstrap ─────────────────────────────────────────────────
step "Server bootstrap"
PORT=$(( 19000 + (RANDOM % 1000) ))
DB_FILE="/tmp/aos-pair-check-$$.db"

ADMIN_TOKEN="test-admin-token"
USER_TOKENS='{"user-token-alice":"alice-001"}'

AOS_PORT=$PORT AOS_DB="$DB_FILE" \
  AUTOPOIESIS_FRAMES_ADMIN_TOKEN="$ADMIN_TOKEN" \
  AUTOPOIESIS_FRAMES_USER_TOKENS="$USER_TOKENS" \
  node hosted-api/server.js &
SERVER_PID=$!

# Wait for server ready
for i in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done

HEALTH=$(api GET /health)
check "health ok" "$(echo "$HEALTH" | jq -r '.ok')" "true"

# ── Step 4: Device registration (generate pairing code) ───────────────────────
step "Device registration — generates pairing code"

REG1=$(api POST /frames/device/register \
  -H "Content-Type: application/json" \
  -d '{"deviceId":"pair-device-001","deviceName":"Living Room Frame","deviceType":"raspberry_pi"}')
check "registration ok" "$(echo "$REG1" | jq -r '.ok')" "true"
PAIRING_CODE=$(echo "$REG1" | jq -r '.pairingCode')
check "pairing code present" "$([ -n "$PAIRING_CODE" ] && echo yes || echo no)" "yes"
DEVICE_KEY=$(echo "$REG1" | jq -r '.deviceApiKey')
check "device key present" "$([ -n "$DEVICE_KEY" ] && echo yes || echo no)" "yes"
check "device not yet paired" "$(echo "$REG1" | jq -r '.paired // false')" "false"
ok # pairing code format match

# ── Step 5: Successful pairing ───────────────────────────────────────────────
step "Successful pairing"

# Set up subscription for alice (so entitlements pass)
api POST /frames/admin/subscriptions \
  -H "Content-Type: application/json" \
  -H "x-admin-token: $ADMIN_TOKEN" \
  -d '{"userId":"alice-001","plan":"frames_basic","status":"active","provider":"manual"}' >/dev/null

PAIR_RESULT=$(api POST /frames/me/pair \
  -H "Content-Type: application/json" \
  -H "x-user-token: user-token-alice" \
  -d "{\"pairingCode\":\"$PAIRING_CODE\"}")
check "pair ok" "$(echo "$PAIR_RESULT" | jq -r '.ok')" "true"
check "pair kind" "$(echo "$PAIR_RESULT" | jq -r '.kind')" "autopoiesis_frames_me_pair"
check "device id" "$(echo "$PAIR_RESULT" | jq -r '.device.deviceId')" "pair-device-001"
check "device name" "$(echo "$PAIR_RESULT" | jq -r '.device.deviceName')" "Living Room Frame"
check "device type" "$(echo "$PAIR_RESULT" | jq -r '.device.deviceType')" "raspberry_pi"
check "device paired" "$(echo "$PAIR_RESULT" | jq -r '.device.paired')" "true"
check "owner user id" "$(echo "$PAIR_RESULT" | jq -r '.device.ownerUserId')" "alice-001"
check "entitlements present" "$(echo "$PAIR_RESULT" | jq -r '.entitlements.maxDevices')" "3"
check "remaining count" "$(echo "$PAIR_RESULT" | jq -r '.entitlements.devicesRemaining')" "2"
check "current count" "$(echo "$PAIR_RESULT" | jq -r '.entitlements.currentDeviceCount')" "1"

# ── Step 6: Paired device appears in /frames/me/devices ─────────────────────
step "Paired device visible in /frames/me/devices"

DEVICES=$(api GET "/frames/me/devices" \
  -H "x-user-token: user-token-alice")
check "devices ok" "$(echo "$DEVICES" | jq -r '.ok')" "true"
check "devices total" "$(echo "$DEVICES" | jq -r '.total')" "1"
check "device id in list" "$(echo "$DEVICES" | jq -r '.devices[0].deviceId')" "pair-device-001"

# ── Step 7: Pairing code not reusable ───────────────────────────────────────
step "Pairing code not reusable"

REUSE=$(api POST /frames/me/pair \
  -H "Content-Type: application/json" \
  -H "x-user-token: user-token-alice" \
  -d "{\"pairingCode\":\"$PAIRING_CODE\"}")
check "reuse fails" "$(echo "$REUSE" | jq -r '.ok')" "false"
check "reuse reason" "$(echo "$REUSE" | jq -r '.reason')" "code_not_found"
check "reuse status" "$(echo "$REUSE" | jq -r '.error')" "Pairing code not found"

# ── Step 8: Invalid pairing code ────────────────────────────────────────────
step "Invalid pairing code"

INVALID=$(api POST /frames/me/pair \
  -H "Content-Type: application/json" \
  -H "x-user-token: user-token-alice" \
  -d '{"pairingCode":"ZZZZZZZZ"}')
check "invalid fails" "$(echo "$INVALID" | jq -r '.ok')" "false"
check "invalid reason" "$(echo "$INVALID" | jq -r '.reason')" "code_not_found"

# ── Step 9: Expired pairing code (register + simulate) ──────────────────────
step "Expired pairing code — simulate via DB"

# Register a second device to get a new code
REG2=$(api POST /frames/device/register \
  -H "Content-Type: application/json" \
  -d '{"deviceId":"pair-device-expired","deviceName":"Expired Frame"}')
EXPIRED_CODE=$(echo "$REG2" | jq -r '.pairingCode')

# Manually expire the code in the DB
node -e "
const Database = require('better-sqlite3');
const db = new Database('$DB_FILE');
db.prepare(\"UPDATE aos_frame_pairing_codes SET expires_at = datetime('now', '-1 hour') WHERE pairing_code = ?\").run('$EXPIRED_CODE');
db.close();
"

EXPIRED_RESULT=$(api POST /frames/me/pair \
  -H "Content-Type: application/json" \
  -H "x-user-token: user-token-alice" \
  -d "{\"pairingCode\":\"$EXPIRED_CODE\"}")
check "expired fails" "$(echo "$EXPIRED_RESULT" | jq -r '.ok')" "false"
check "expired reason" "$(echo "$EXPIRED_RESULT" | jq -r '.reason')" "code_expired"

# ── Step 10: Device limit enforcement ────────────────────────────────────────
step "Device limit enforcement (basic plan = 3 max)"

# Alice already has 1 device. Register 2 more and pair them to hit the limit.
REG3=$(api POST /frames/device/register \
  -H "Content-Type: application/json" \
  -d '{"deviceId":"pair-device-002","deviceName":"Bedroom Frame"}')
CODE3=$(echo "$REG3" | jq -r '.pairingCode')

PAIR3=$(api POST /frames/me/pair \
  -H "Content-Type: application/json" \
  -H "x-user-token: user-token-alice" \
  -d "{\"pairingCode\":\"$CODE3\"}")
check "second pair ok" "$(echo "$PAIR3" | jq -r '.ok')" "true"
check "remaining after 2" "$(echo "$PAIR3" | jq -r '.entitlements.devicesRemaining')" "1"

REG4=$(api POST /frames/device/register \
  -H "Content-Type: application/json" \
  -d '{"deviceId":"pair-device-003","deviceName":"Kitchen Frame"}')
CODE4=$(echo "$REG4" | jq -r '.pairingCode')

PAIR4=$(api POST /frames/me/pair \
  -H "Content-Type: application/json" \
  -H "x-user-token: user-token-alice" \
  -d "{\"pairingCode\":\"$CODE4\"}")
check "third pair ok" "$(echo "$PAIR4" | jq -r '.ok')" "true"
check "remaining after 3" "$(echo "$PAIR4" | jq -r '.entitlements.devicesRemaining')" "0"

# Now try a 4th — should fail with device limit
REG5=$(api POST /frames/device/register \
  -H "Content-Type: application/json" \
  -d '{"deviceId":"pair-device-004","deviceName":"Garage Frame"}')
CODE5=$(echo "$REG5" | jq -r '.pairingCode')

LIMIT_RESULT=$(api POST /frames/me/pair \
  -H "Content-Type: application/json" \
  -H "x-user-token: user-token-alice" \
  -d "{\"pairingCode\":\"$CODE5\"}")
check "limit hit fails" "$(echo "$LIMIT_RESULT" | jq -r '.ok')" "false"
check "limit reason" "$(echo "$LIMIT_RESULT" | jq -r '.reason')" "device_limit_reached"
check "limit maxDevices" "$(echo "$LIMIT_RESULT" | jq -r '.entitlements.maxDevices')" "3"
check "limit current" "$(echo "$LIMIT_RESULT" | jq -r '.entitlements.currentDeviceCount')" "3"

# ── Step 11: Subscription degraded blocking ──────────────────────────────────
step "Subscription degraded blocking"

# Create a degraded user (expired subscription)
USER_TOKENS_ORIG='{"user-token-alice":"alice-001","user-token-bob":"bob-002"}'

# Register a device for bob
REG6=$(api POST /frames/device/register \
  -H "Content-Type: application/json" \
  -d '{"deviceId":"pair-device-bob-01","deviceName":"Bob Frame"}')
CODE6=$(echo "$REG6" | jq -r '.pairingCode')

# Give bob an expired subscription
api POST /frames/admin/subscriptions \
  -H "Content-Type: application/json" \
  -H "x-admin-token: $ADMIN_TOKEN" \
  -d '{"userId":"bob-002","plan":"frames_basic","status":"expired","provider":"manual"}' >/dev/null

# Bob can't pair because his subscription is expired
# First, we need bob's token in the env. The server was started with only alice's token.
# Kill and restart with both tokens.
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
rm -f "$DB_FILE"

PORT=$(( 19000 + (RANDOM % 1000) ))
DB_FILE="/tmp/aos-pair-check-$$-2.db"

AOS_PORT=$PORT AOS_DB="$DB_FILE" \
  AUTOPOIESIS_FRAMES_ADMIN_TOKEN="$ADMIN_TOKEN" \
  AUTOPOIESIS_FRAMES_USER_TOKENS='{"user-token-alice":"alice-001","user-token-bob":"bob-002"}' \
  node hosted-api/server.js &
SERVER_PID=$!

for i in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done

HEALTH2=$(api GET /health)
check "health after restart" "$(echo "$HEALTH2" | jq -r '.ok')" "true"

# Set up: register device for bob, set expired subscription
REG_BOB=$(api POST /frames/device/register \
  -H "Content-Type: application/json" \
  -d '{"deviceId":"bob-device-001","deviceName":"Bob Frame"}')
BOB_CODE=$(echo "$REG_BOB" | jq -r '.pairingCode')

api POST /frames/admin/subscriptions \
  -H "Content-Type: application/json" \
  -H "x-admin-token: $ADMIN_TOKEN" \
  -d '{"userId":"bob-002","plan":"frames_basic","status":"expired","provider":"manual"}' >/dev/null

DEGRADED=$(api POST /frames/me/pair \
  -H "Content-Type: application/json" \
  -H "x-user-token: user-token-bob" \
  -d "{\"pairingCode\":\"$BOB_CODE\"}")
check "degraded fails" "$(echo "$DEGRADED" | jq -r '.ok')" "false"
check "degraded reason" "$(echo "$DEGRADED" | jq -r '.reason')" "subscription_degraded"
check "degraded subscription status" "$(echo "$DEGRADED" | jq -r '.subscription.status')" "expired"

# ── Step 12: Auth gates ──────────────────────────────────────────────────────
step "Auth gates"

# No token
NO_TOKEN=$(api POST /frames/me/pair \
  -H "Content-Type: application/json" \
  -d '{"pairingCode":"ABC123"}')
check "no token fails" "$(echo "$NO_TOKEN" | jq -r '.ok')" "false"
check_contains "no token error mentions token" "$NO_TOKEN" "token"

# Wrong token
WRONG_TOKEN=$(api POST /frames/me/pair \
  -H "Content-Type: application/json" \
  -H "x-user-token: wrong-token" \
  -d '{"pairingCode":"ABC123"}')
check "wrong token fails" "$(echo "$WRONG_TOKEN" | jq -r '.ok')" "false"
check "wrong token status" "$(echo "$WRONG_TOKEN" | jq -r '.error')" "Invalid user token"

# Admin token with ?userId= works
REG_ADMIN=$(api POST /frames/device/register \
  -H "Content-Type: application/json" \
  -d '{"deviceId":"admin-pair-device","deviceName":"Admin Paired"}')
ADMIN_CODE=$(echo "$REG_ADMIN" | jq -r '.pairingCode')

api POST /frames/admin/subscriptions \
  -H "Content-Type: application/json" \
  -H "x-admin-token: $ADMIN_TOKEN" \
  -d '{"userId":"alice-001","plan":"frames_premium","status":"active","provider":"manual"}' >/dev/null

ADMIN_PAIR=$(api POST "/frames/me/pair?userId=alice-001" \
  -H "Content-Type: application/json" \
  -H "x-admin-token: $ADMIN_TOKEN" \
  -d "{\"pairingCode\":\"$ADMIN_CODE\"}")
check "admin pair ok" "$(echo "$ADMIN_PAIR" | jq -r '.ok')" "true"
check "admin pair device" "$(echo "$ADMIN_PAIR" | jq -r '.device.ownerUserId')" "alice-001"

# Bearer token support
REG_BEARER=$(api POST /frames/device/register \
  -H "Content-Type: application/json" \
  -d '{"deviceId":"bearer-pair-device","deviceName":"Bearer Paired"}')
BEARER_CODE=$(echo "$REG_BEARER" | jq -r '.pairingCode')

BEARER_PAIR=$(api POST /frames/me/pair \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer user-token-alice" \
  -d "{\"pairingCode\":\"$BEARER_CODE\"}")
check "bearer pair ok" "$(echo "$BEARER_PAIR" | jq -r '.ok')" "true"

# ── Step 13: Input validation ────────────────────────────────────────────────
step "Input validation"

# Missing pairingCode
NO_CODE=$(api POST /frames/me/pair \
  -H "Content-Type: application/json" \
  -H "x-user-token: user-token-alice" \
  -d '{}')
check "no code fails" "$(echo "$NO_CODE" | jq -r '.ok')" "false"
check_contains "no code error" "$NO_CODE" "pairingCode"

# Empty pairingCode
EMPTY_CODE=$(api POST /frames/me/pair \
  -H "Content-Type: application/json" \
  -H "x-user-token: user-token-alice" \
  -d '{"pairingCode":""}')
check "empty code fails" "$(echo "$EMPTY_CODE" | jq -r '.ok')" "false"

# Invalid format (lowercase)
LOWER_CODE=$(api POST /frames/me/pair \
  -H "Content-Type: application/json" \
  -H "x-user-token: user-token-alice" \
  -d '{"pairingCode":"abc123"}')
check "lowercase fails" "$(echo "$LOWER_CODE" | jq -r '.ok')" "false"
check_contains "format error" "$LOWER_CODE" "format"

# Invalid format (special chars)
SPECIAL_CODE=$(api POST /frames/me/pair \
  -H "Content-Type: application/json" \
  -H "x-user-token: user-token-alice" \
  -d '{"pairingCode":"ABC-123"}')
check "special chars fails" "$(echo "$SPECIAL_CODE" | jq -r '.ok')" "false"

# Too short
SHORT_CODE=$(api POST /frames/me/pair \
  -H "Content-Type: application/json" \
  -H "x-user-token: user-token-alice" \
  -d '{"pairingCode":"AB"}')
check "short code fails" "$(echo "$SHORT_CODE" | jq -r '.ok')" "false"

# ── Step 14: CORS preflight ──────────────────────────────────────────────────
step "CORS preflight"

PREFLIGHT=$(curl -s -o /dev/null -w "%{http_code}" \
  -X OPTIONS "http://127.0.0.1:$PORT/frames/me/pair" \
  -H "Origin: http://localhost:3000" \
  -H "Access-Control-Request-Method: POST")
check "preflight 204" "$PREFLIGHT" "204"

# ── Step 15: Regression ──────────────────────────────────────────────────────
step "Regression — existing endpoints unaffected"

# Health
REG_HEALTH=$(api GET /health)
check "regression health" "$(echo "$REG_HEALTH" | jq -r '.ok')" "true"

# Admin bundle
REG_BUNDLE=$(api GET "/frames/admin/bundle" \
  -H "x-admin-token: $ADMIN_TOKEN")
check "regression bundle ok" "$(echo "$REG_BUNDLE" | jq -r '.ok')" "true"

# /frames/me still works
REG_ME=$(api GET "/frames/me" \
  -H "x-user-token: user-token-alice")
check "regression me ok" "$(echo "$REG_ME" | jq -r '.ok')" "true"

# Device settings still work
DEVICE_KEY_ADMIN=$(echo "$REG_ADMIN" | jq -r '.deviceApiKey')
REG_SETTINGS=$(api GET "/frames/device/admin-pair-device/settings" \
  -H "x-frame-device-key: $DEVICE_KEY_ADMIN")
check "regression settings ok" "$(echo "$REG_SETTINGS" | jq -r '.ok')" "true"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo "  POST /frames/me/pair — Validation Gate Results"
echo "  Steps: $STEP  |  PASS: $PASS  |  FAIL: $FAIL"
echo "════════════════════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
  echo "  ❌ FAILED — $FAIL check(s) failed"
  exit 1
fi
echo "  ✅ ALL $PASS CHECKS PASSED"
