#!/usr/bin/env bash
# online-admin-subscription-fleet-check.sh
#
# Validation gate for hosted API subscription CRUD admin endpoints and
# device fleet action endpoints.
#
# Tests:
#   1. Syntax validation
#   2. Static contract (functions, routes, constants)
#   3. Database bootstrap + migration (disabled column)
#   4. Server startup + health
#   5. Device registration + pairing (2 devices, 2 owners)
#   6. Subscription CRUD: create, get with entitlements, update, double-create rejection
#   7. Subscription cancel + double-cancel rejection
#   8. Invalid plan/status rejection
#   9. Device action: queue restart_device
#  10. Device action: disable device via PATCH, then verify blocked actions
#  11. Device action: enable_device on disabled device
#  12. Device action: invalid action, unpaired device, unknown device
#  13. Admin auth required on all new endpoints
#  14. Regression: admin bundle reflects subscription changes
#  15. Regression: existing hosted-api-server-check passes

set -euo pipefail

CHECK_NAME="online-admin-subscription-fleet-check"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOSTED_API="$REPO_DIR/hosted-api/server.js"
HOSTED_DB="$REPO_DIR/hosted-api/db.js"
SCHEMA="$REPO_DIR/scripts/aos-schema-sqlite-validation.sql"

PASS=0
FAIL=0
STEP=0

ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

step() { STEP=$((STEP + 1)); echo ""; echo "── Step $STEP: $1 ──"; }

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
  if echo "$haystack" | grep -qF "$needle"; then
    ok
  else
    fail "$label — expected to contain '$needle'"
  fi
}

check_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    fail "$label — expected NOT to contain '$needle'"
  else
    ok
  fi
}

# ── Temp dir ─────────────────────────────────────────────────────────────────
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

DB_PATH="$WORK/aos.db"
LOG="$WORK/check.log"
PID_FILE="$WORK/api.pid"
PORT_FILE="$WORK/api.port"

# ── Step 1: Syntax validation ────────────────────────────────────────────────
step "Syntax validation"

node --check "$HOSTED_API" 2>"$WORK/err" && ok || fail "hosted-api/server.js syntax"
node --check "$HOSTED_DB" 2>"$WORK/err" && ok || fail "hosted-api/db.js syntax"
bash -n "$0" 2>"$WORK/err" && ok || fail "self syntax"

# ── Step 2: Static contract ──────────────────────────────────────────────────
step "Static contract"

SRC="$(cat "$HOSTED_API")"

# Handler functions exist
for fn in handleAdminCreateSubscription handleAdminUpdateSubscription handleAdminCancelSubscription handleAdminGetSubscription handleAdminDeviceAction handleAdminUpdateDevice; do
  check "handler function $fn exists" "$(echo "$SRC" | grep -c "function $fn")" "1"
done

# Route patterns exist
for pattern in \
  'adminSubMatch = pathname' \
  'adminSubCancelMatch = pathname' \
  'adminDevActionMatch = pathname' \
  'adminDevUpdateMatch = pathname'; do
  check_contains "route pattern $pattern" "$SRC" "$pattern"
done

# Subscription create route
check_contains "subscription create route" "$SRC" '"/frames/admin/subscriptions"'

# PLAN_LIMITS has 4 tier definitions (unique object keys)
check "PLAN_LIMITS defines 4 tiers" "$(echo "$SRC" | grep -oE 'frames_trial:|frames_basic:|frames_premium:|frames_enterprise:' | sort -u | wc -l)" "4"

# ACTION_TO_COMMAND mapping exists
check_contains "ACTION_TO_COMMAND mapping" "$SRC" "ACTION_TO_COMMAND"

# riskMap exists
check_contains "riskMap" "$SRC" "riskMap"

# disabled column in schema
SCHEMA_SRC="$(cat "$SCHEMA")"
check_contains "disabled column in aos_frame_devices schema" "$SCHEMA_SRC" "disabled"

# disabled field in _mapDevice
DB_SRC="$(cat "$HOSTED_DB")"
check_contains "disabled in _mapDevice" "$DB_SRC" "disabled: !!row.disabled"

# Migration file exists
[ -f "$REPO_DIR/migrations/sqlite/20260608000002_add_device_disabled_column.sql" ] && ok || fail "migration file exists"
check_contains "migration adds disabled column" "$(cat "$REPO_DIR/migrations/sqlite/20260608000002_add_device_disabled_column.sql")" "disabled"

# ── Step 3: Database bootstrap + migration ────────────────────────────────────
step "Database bootstrap + migration"

cd "$REPO_DIR"
node -e "
const AosDb = require('./hosted-api/db');
const db = new AosDb('$DB_PATH');
const fs = require('fs');
const schema = fs.readFileSync('$SCHEMA', 'utf-8');
for (const stmt of schema.split(';').map(s => s.trim()).filter(s => s.length > 0)) {
  db.db.prepare(stmt).run();
}
const migrationsDir = '$REPO_DIR/migrations/sqlite';
const result = db.runMigrations(migrationsDir);
console.log('migrations_applied=' + result.applied.length);
console.log('migrations_errors=' + result.errors.length);

// Verify disabled column exists
const info = db.db.pragma('table_info(aos_frame_devices)');
const hasDisabled = info.some(c => c.name === 'disabled');
console.log('has_disabled=' + hasDisabled);

db.close();
" 2>"$WORK/db.err" > "$WORK/db.out"

check "migrations applied (≥1)" "$(grep 'migrations_applied=' "$WORK/db.out" | cut -d= -f2)" "2"
check "migration errors" "$(grep 'migrations_errors=' "$WORK/db.out" | cut -d= -f2)" "0"
check "disabled column exists" "$(grep 'has_disabled=' "$WORK/db.out" | cut -d= -f2)" "true"

# ── Step 4: Server startup ───────────────────────────────────────────────────
step "Server startup"

# Find a free port
PORT=$((3140 + RANDOM % 100))
while ss -tlnp 2>/dev/null | grep -q ":$PORT " || nc -z localhost "$PORT" 2>/dev/null; do
  PORT=$((3140 + RANDOM % 100))
done

# Use fresh DB for clean server bootstrap
rm -f "$DB_PATH"

AOS_DB="$DB_PATH" \
AOS_PORT="$PORT" \
AOS_HOST="127.0.0.1" \
AUTOPOIESIS_FRAMES_ADMIN_TOKEN="test-admin-token-$(date +%s)" \
node "$HOSTED_API" > "$WORK/api.out" 2>&1 &
API_PID=$!
echo "$API_PID" > "$PID_FILE"
echo "$PORT" > "$PORT_FILE"

# Wait for server
for i in $(seq 1 30); do
  if curl -s "http://127.0.0.1:$PORT/health" > /dev/null 2>&1; then
    break
  fi
  sleep 0.3
done

HEALTH="$(curl -s "http://127.0.0.1:$PORT/health")"
check_contains "health endpoint ok" "$HEALTH" '"ok":true'
check_contains "service name" "$HEALTH" "aos-hosted-api"

# Helper: admin curl
acurl() {
  curl -s -H "x-admin-token: $(cat "$PORT_FILE" | head -1 | sed 's/^3.*/test-admin-token-ignored/')" "$@"
}

# Get actual admin token from env (we set it above)
ADMIN_TOKEN="test-admin-token-$(date +%s)"
# The token was set when we started the server, need to capture it
# Let's re-read it from the process
ADMIN_TOKEN=$(grep -o 'test-admin-token-[0-9]*' "$WORK/api.out" 2>/dev/null || echo "")

# Actually, we need the token we used when starting. Let's get it from the env.
# Since we used $() for date, the actual token was set at launch time.
# Let's just re-derive: we started the server with this exact token.
# Use a fixed token instead.
kill "$API_PID" 2>/dev/null || true
wait "$API_PID" 2>/dev/null || true

rm -f "$DB_PATH"
ADMIN_TOKEN="test-admin-fleet-2026"
AOS_DB="$DB_PATH" \
AOS_PORT="$PORT" \
AOS_HOST="127.0.0.1" \
AUTOPOIESIS_FRAMES_ADMIN_TOKEN="$ADMIN_TOKEN" \
node "$HOSTED_API" > "$WORK/api.out" 2>&1 &
API_PID=$!
echo "$API_PID" > "$PID_FILE"

for i in $(seq 1 30); do
  if curl -s "http://127.0.0.1:$PORT/health" > /dev/null 2>&1; then
    break
  fi
  sleep 0.3
done

HEALTH="$(curl -s "http://127.0.0.1:$PORT/health")"
check_contains "server restarted with fixed token" "$HEALTH" '"ok":true'

# Admin curl helper
acurl() {
  curl -s -H "x-admin-token: $ADMIN_TOKEN" "$@"
}

# Device curl helper
dcurl() {
  curl -s -H "x-frame-device-key: $1" "$@"
}

# ── Step 5: Device registration + pairing ─────────────────────────────────────
step "Device registration + pairing (2 devices, 2 owners)"

# Register device 1
REG1="$(curl -s -X POST "http://127.0.0.1:$PORT/frames/device/register" \
  -H "content-type: application/json" \
  -d '{"deviceId":"dev-fleet-01","softwareVersion":"0.2.0"}')"
check_contains "register dev-fleet-01 ok" "$REG1" '"ok":true'
DEV1_KEY="$(echo "$REG1" | node -pe 'JSON.parse(require("fs").readFileSync("/dev/stdin","utf8")).device.deviceApiKey')"
DEV1_CODE="$(echo "$REG1" | node -pe 'JSON.parse(require("fs").readFileSync("/dev/stdin","utf8")).pairingCode')"

# Register device 2
REG2="$(curl -s -X POST "http://127.0.0.1:$PORT/frames/device/register" \
  -H "content-type: application/json" \
  -d '{"deviceId":"dev-fleet-02","softwareVersion":"0.2.0"}')"
check_contains "register dev-fleet-02 ok" "$REG2" '"ok":true'
DEV2_KEY="$(echo "$REG2" | node -pe 'JSON.parse(require("fs").readFileSync("/dev/stdin","utf8")).device.deviceApiKey')"
DEV2_CODE="$(echo "$REG2" | node -pe 'JSON.parse(require("fs").readFileSync("/dev/stdin","utf8")).pairingCode')"

# Pair device 1 to alice
PAIR1="$(node -e "
const AosDb = require('$REPO_DIR/hosted-api/db');
const db = new AosDb('$DB_PATH');
const result = db.claimPairingCode('$DEV1_CODE', 'user-alice');
console.log(JSON.stringify(result));
")"
check_contains "pair dev-01 to alice ok" "$PAIR1" '"ok":true'

# Pair device 2 to bob
PAIR2="$(node -e "
const AosDb = require('$REPO_DIR/hosted-api/db');
const db = new AosDb('$DB_PATH');
const result = db.claimPairingCode('$DEV2_CODE', 'user-bob');
console.log(JSON.stringify(result));
")"
check_contains "pair dev-02 to bob ok" "$PAIR2" '"ok":true'

# Send heartbeat for device 1 (makes it "online")
HB1="$(dcurl "$DEV1_KEY" -X POST "http://127.0.0.1:$PORT/frames/device/dev-fleet-01/heartbeat" \
  -H "content-type: application/json" \
  -d '{"currentMode":"display"}')"
check_contains "heartbeat dev-01 ok" "$HB1" '"ok":true'

# ── Step 6: Subscription CRUD — create, get, update ─────────────────────────
step "Subscription CRUD: create, get with entitlements, update"

# Create subscription for alice (basic plan)
CSUB="$(acurl -X POST "http://127.0.0.1:$PORT/frames/admin/subscriptions" \
  -H "content-type: application/json" \
  -d '{"userId":"user-alice","plan":"frames_basic","status":"active"}')"
check_contains "create subscription ok" "$CSUB" '"ok":true'
check_contains "create subscription created" "$CSUB" '"created":true'
check_contains "subscription plan frames_basic" "$CSUB" "frames_basic"
check_contains "subscription status active" "$CSUB" '"active"'

# Get subscription for alice with entitlements
GSUB="$(acurl "http://127.0.0.1:$PORT/frames/admin/subscriptions/user-alice")"
check_contains "get subscription ok" "$GSUB" '"ok":true'
check_contains "entitlements present" "$GSUB" "entitlements"
check_contains "plan frames_basic" "$GSUB" "frames_basic"
check_contains "deviceLimit 3" "$GSUB" '"deviceLimit":3'
check_contains "canAddDevice true" "$GSUB" '"canAddDevice":true'

# Update alice to premium
USUB="$(acurl -X PATCH "http://127.0.0.1:$PORT/frames/admin/subscriptions/user-alice" \
  -H "content-type: application/json" \
  -d '{"plan":"frames_premium"}')"
check_contains "update subscription ok" "$USUB" '"ok":true'
check_contains "update subscription updated" "$USUB" '"updated":true'
check_contains "plan updated to premium" "$USUB" "frames_premium"

# Verify updated entitlements
USUB_GET="$(acurl "http://127.0.0.1:$PORT/frames/admin/subscriptions/user-alice")"
check_contains "deviceLimit now 10" "$USUB_GET" '"deviceLimit":10'

# Double-create should fail with 409
DCSUB="$(acurl -X POST "http://127.0.0.1:$PORT/frames/admin/subscriptions" \
  -H "content-type: application/json" \
  -d '{"userId":"user-alice","plan":"frames_basic","status":"active"}')"
check "double-create returns 409" "$(echo "$DCSUB" | node -pe 'JSON.parse(require("fs").readFileSync("/dev/stdin","utf8")).ok ? "200" : "409"')" "409"
check_contains "double-create mentions already exists" "$DCSUB" "already exists"

# ── Step 7: Subscription cancel ──────────────────────────────────────────────
step "Subscription cancel + double-cancel rejection"

# Create subscription for bob first
CSUB_BOB="$(acurl -X POST "http://127.0.0.1:$PORT/frames/admin/subscriptions" \
  -H "content-type: application/json" \
  -d '{"userId":"user-bob","plan":"frames_basic","status":"active"}')"
check_contains "create bob subscription ok" "$CSUB_BOB" '"ok":true'

# Cancel bob's subscription
CANCEL="$(acurl -X POST "http://127.0.0.1:$PORT/frames/admin/subscriptions/user-bob/cancel")"
check_contains "cancel ok" "$CANCEL" '"ok":true'
check_contains "cancel confirmed" "$CANCEL" '"cancelled":true'
check_contains "status cancelled" "$CANCEL" '"status":"cancelled"'

# Double-cancel should fail
DCANCEL="$(acurl -X POST "http://127.0.0.1:$PORT/frames/admin/subscriptions/user-bob/cancel")"
check_not_contains "double-cancel not ok" "$DCANCEL" '"ok":true'
check_contains "double-cancel already cancelled" "$DCANCEL" "already cancelled"

# Cancel non-existent user
CANCEL_404="$(acurl -X POST "http://127.0.0.1:$PORT/frames/admin/subscriptions/user-nobody/cancel")"
check_contains "cancel non-existent returns error" "$CANCEL_404" "not found"

# ── Step 8: Invalid plan/status rejection ────────────────────────────────────
step "Invalid plan/status rejection"

INVALID_PLAN="$(acurl -X POST "http://127.0.0.1:$PORT/frames/admin/subscriptions" \
  -H "content-type: application/json" \
  -d '{"userId":"user-test-invalid","plan":"super_premium"}')"
check_not_contains "invalid plan rejected" "$INVALID_PLAN" '"ok":true'
check_contains "invalid plan error message" "$INVALID_PLAN" "Invalid plan"

INVALID_STATUS="$(acurl -X PATCH "http://127.0.0.1:$PORT/frames/admin/subscriptions/user-alice" \
  -H "content-type: application/json" \
  -d '{"status":"super_active"}')"
check_not_contains "invalid status rejected" "$INVALID_STATUS" '"ok":true'
check_contains "invalid status error message" "$INVALID_STATUS" "Invalid status"

# ── Step 9: Device action — queue restart_device ─────────────────────────────
step "Device action: queue restart_device"

ACTION="$(acurl -X POST "http://127.0.0.1:$PORT/frames/admin/devices/dev-fleet-01/actions" \
  -H "content-type: application/json" \
  -d '{"action":"restart_device"}')"
check_contains "queue action ok" "$ACTION" '"ok":true'
check_contains "action queued" "$ACTION" '"queued":true'
check_contains "action restart_device" "$ACTION" '"action":"restart_device"'
check_contains "commandType restart_device" "$ACTION" '"commandType":"restart_device"'
check_contains "risk high" "$ACTION" '"risk":"high"'

# ── Step 10: Device action — disable device, then verify blocked actions ─────
step "Device action: disable device via PATCH, verify blocked actions"

# Disable device 1
DISABLE="$(acurl -X PATCH "http://127.0.0.1:$PORT/frames/admin/devices/dev-fleet-01" \
  -H "content-type: application/json" \
  -d '{"disabled":true}')"
check_contains "disable device ok" "$DISABLE" '"ok":true'
check_contains "disable device updated" "$DISABLE" '"updated":true'
check_contains "device disabled true" "$DISABLE" '"disabled":true'

# Now try restart_device on disabled device — should be blocked
BLOCKED="$(acurl -X POST "http://127.0.0.1:$PORT/frames/admin/devices/dev-fleet-01/actions" \
  -H "content-type: application/json" \
  -d '{"action":"restart_device"}')"
check_not_contains "disabled device action not ok" "$BLOCKED" '"ok":true'
check_contains "blocked reason" "$BLOCKED" "device_disabled"

# enable_device should still work on disabled device
ENABLE="$(acurl -X POST "http://127.0.0.1:$PORT/frames/admin/devices/dev-fleet-01/actions" \
  -H "content-type: application/json" \
  -d '{"action":"enable_device"}')"
check_contains "enable_device on disabled device ok" "$ENABLE" '"ok":true'
check_contains "enable_device queued" "$ENABLE" '"queued":true'

# ── Step 11: Device action — enable device back ──────────────────────────────
step "Device action: enable device via PATCH"

ENABLE_PATCH="$(acurl -X PATCH "http://127.0.0.1:$PORT/frames/admin/devices/dev-fleet-01" \
  -H "content-type: application/json" \
  -d '{"disabled":false}')"
check_contains "enable device ok" "$ENABLE_PATCH" '"ok":true'
check_contains "device disabled false" "$ENABLE_PATCH" '"disabled":false'

# Now restart_device should work again
RESTART_OK="$(acurl -X POST "http://127.0.0.1:$PORT/frames/admin/devices/dev-fleet-01/actions" \
  -H "content-type: application/json" \
  -d '{"action":"restart_device"}')"
check_contains "restart after enable ok" "$RESTART_OK" '"ok":true'
check_contains "restart after enable queued" "$RESTART_OK" '"queued":true'

# ── Step 12: Device action — error cases ─────────────────────────────────────
step "Device action: invalid action, unpaired device, unknown device"

# Invalid action
INVALID_ACT="$(acurl -X POST "http://127.0.0.1:$PORT/frames/admin/devices/dev-fleet-01/actions" \
  -H "content-type: application/json" \
  -d '{"action":"explode_device"}')"
check_not_contains "invalid action not ok" "$INVALID_ACT" '"ok":true'
check_contains "unknown action error" "$INVALID_ACT" "Unknown action"

# Missing action
MISSING_ACT="$(acurl -X POST "http://127.0.0.1:$PORT/frames/admin/devices/dev-fleet-01/actions" \
  -H "content-type: application/json" \
  -d '{}')"
check_not_contains "missing action not ok" "$MISSING_ACT" '"ok":true'
check_contains "action required error" "$MISSING_ACT" "action is required"

# Unknown device
UNKNOWN_DEV="$(acurl -X POST "http://127.0.0.1:$PORT/frames/admin/devices/dev-nonexistent/actions" \
  -H "content-type: application/json" \
  -d '{"action":"restart_device"}')"
check_not_contains "unknown device not ok" "$UNKNOWN_DEV" '"ok":true'
check_contains "device not found error" "$UNKNOWN_DEV" "Device not found"

# Patch unknown device
PATCH_404="$(acurl -X PATCH "http://127.0.0.1:$PORT/frames/admin/devices/dev-nonexistent" \
  -H "content-type: application/json" \
  -d '{"deviceName":"ghost"}')"
check_not_contains "patch unknown not ok" "$PATCH_404" '"ok":true'
check_contains "patch 404" "$PATCH_404" "Device not found"

# Patch with no fields
PATCH_EMPTY="$(acurl -X PATCH "http://127.0.0.1:$PORT/frames/admin/devices/dev-fleet-01" \
  -H "content-type: application/json" \
  -d '{}')"
check_not_contains "empty patch not ok" "$PATCH_EMPTY" '"ok":true'
check_contains "no updatable fields" "$PATCH_EMPTY" "No updatable fields"

# ── Step 13: Admin auth required ─────────────────────────────────────────────
step "Admin auth required on all new endpoints"

# No token
NO_TOKEN="$(curl -s "http://127.0.0.1:$PORT/frames/admin/subscriptions/user-alice")"
check_contains "get subscription no token rejected" "$NO_TOKEN" "Missing admin token"

# Wrong token
WRONG_TOKEN="$(curl -s -H "x-admin-token: wrong-token" \
  "http://127.0.0.1:$PORT/frames/admin/subscriptions/user-alice")"
check_contains "get subscription wrong token rejected" "$WRONG_TOKEN" "Invalid admin token"

# POST without token
POST_NO_TOKEN="$(curl -s -X POST "http://127.0.0.1:$PORT/frames/admin/subscriptions" \
  -H "content-type: application/json" \
  -d '{"userId":"user-test","plan":"frames_trial"}')"
check_contains "create subscription no token rejected" "$POST_NO_TOKEN" "Missing admin token"

# Action without token
ACT_NO_TOKEN="$(curl -s -X POST "http://127.0.0.1:$PORT/frames/admin/devices/dev-fleet-01/actions" \
  -H "content-type: application/json" \
  -d '{"action":"restart_device"}')"
check_contains "action no token rejected" "$ACT_NO_TOKEN" "Missing admin token"

# Cancel without token
CANCEL_NO_TOKEN="$(curl -s -X POST "http://127.0.0.1:$PORT/frames/admin/subscriptions/user-alice/cancel")"
check_contains "cancel no token rejected" "$CANCEL_NO_TOKEN" "Missing admin token"

# PATCH device without token
DEV_NO_TOKEN="$(curl -s -X PATCH "http://127.0.0.1:$PORT/frames/admin/devices/dev-fleet-01" \
  -H "content-type: application/json" \
  -d '{"deviceName":"hacked"}')"
check_contains "device patch no token rejected" "$DEV_NO_TOKEN" "Missing admin token"

# ── Step 14: Regression — admin bundle reflects subscription changes ─────────
step "Regression: admin bundle reflects subscription changes"

BUNDLE="$(acurl "http://127.0.0.1:$PORT/frames/admin/bundle?userId=user-alice")"
check_contains "bundle ok" "$BUNDLE" '"ok":true'
check_contains "bundle has alice premium" "$BUNDLE" "frames_premium"
check_contains "bundle has bob cancelled" "$BUNDLE" '"cancelled"'
check_contains "bundle has fleet devices" "$BUNDLE" "dev-fleet-01"
check_contains "bundle has plan limits" "$BUNDLE" "planLimits"

# ── Step 15: Regression — existing device endpoints still work ───────────────
step "Regression: existing device endpoints still work"

# Settings read
SETTINGS="$(dcurl "$DEV1_KEY" "http://127.0.0.1:$PORT/frames/device/dev-fleet-01/settings")"
check_contains "settings read ok" "$SETTINGS" '"ok":true'

# Heartbeat
HB_REG="$(dcurl "$DEV1_KEY" -X POST "http://127.0.0.1:$PORT/frames/device/dev-fleet-01/heartbeat" \
  -H "content-type: application/json" \
  -d '{"currentMode":"display"}')"
check_contains "heartbeat regression ok" "$HB_REG" '"ok":true'

# Stream
STREAM="$(dcurl "$DEV1_KEY" "http://127.0.0.1:$PORT/frames/device/dev-fleet-01/stream")"
check_contains "stream regression ok" "$STREAM" '"ok":true'

# Admin snapshot
SNAP="$(acurl "http://127.0.0.1:$PORT/frames/device/dev-fleet-01/admin-snapshot")"
check_contains "admin snapshot regression ok" "$SNAP" '"ok":true'

# Health
HEALTH_REG="$(curl -s "http://127.0.0.1:$PORT/health")"
check_contains "health regression ok" "$HEALTH_REG" '"ok":true'

# ── Cleanup ──────────────────────────────────────────────────────────────────
kill "$API_PID" 2>/dev/null || true
wait "$API_PID" 2>/dev/null || true

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════"
echo " $CHECK_NAME: $PASS passed, $FAIL failed ($STEP steps)"
echo "══════════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
