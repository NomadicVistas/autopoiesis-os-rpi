#!/usr/bin/env bash
# cors-preflight-check.sh
# Validation gate for CORS preflight handling in the hosted API.
#
# Verifies:
#   - Static contract: CORS helper functions, headers, OPTIONS handling
#   - Live server: preflight responds 204 with correct headers
#   - Live server: actual requests include CORS headers
#   - Authenticated endpoints: preflight works before admin/device endpoints
#   - Health endpoint: preflight + CORS headers on GET
#   - Edge cases: preflight for unknown routes, POST routes, PATCH routes

set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

PASS=0; FAIL=0; SKIP=0
step=0
p() { ((PASS++)) || true; }
f() { ((FAIL++)) || true; echo "  ✗ FAIL: $1"; }
s() { ((SKIP++)) || true; echo "  ⊘ SKIP: $1"; }
step_header() { ((step++)) || true; echo ""; echo "━━ Step $step: $1 ━━"; }

# ═══════════════════════════════════════════════════════════════
# Step 1: Syntax validation
# ═══════════════════════════════════════════════════════════════
step_header "Syntax validation"
node --check hosted-api/server.js 2>/dev/null && p || f "hosted-api/server.js syntax"
node --check hosted-api/db.js 2>/dev/null && p || f "hosted-api/db.js syntax"
node --check local-ui/server.js 2>/dev/null && p || f "local-ui/server.js syntax"
bash -n install.sh 2>/dev/null && p || f "install.sh syntax"
bash -n update.sh 2>/dev/null && p || f "update.sh syntax"
bash -n uninstall-dev-tools.sh 2>/dev/null && p || f "uninstall-dev-tools.sh syntax"
bash -n factory-reset.sh 2>/dev/null && p || f "factory-reset.sh syntax"

echo "  Syntax: $PASS passed, $FAIL failed"

# ═══════════════════════════════════════════════════════════════
# Step 2: Static contract — CORS implementation
# ═══════════════════════════════════════════════════════════════
step_header "Static contract — CORS implementation"

SERVER="hosted-api/server.js"

# CORS_HEADERS object exists
grep -q 'const CORS_HEADERS' "$SERVER" && p || f "CORS_HEADERS constant defined"
grep -q 'access-control-allow-origin.*\*' "$SERVER" && p || f "access-control-allow-origin header"
grep -q 'access-control-allow-methods' "$SERVER" && p || f "access-control-allow-methods header"
grep -q 'access-control-allow-headers' "$SERVER" && p || f "access-control-allow-headers header"
grep -q 'access-control-max-age' "$SERVER" && p || f "access-control-max-age header"

# sendCorsPreflight function
grep -q 'function sendCorsPreflight' "$SERVER" && p || f "sendCorsPreflight function exists"
grep -q '204.*CORS_HEADERS' "$SERVER" && p || f "preflight returns 204"

# OPTIONS handling in handle()
grep -q 'method === "OPTIONS"' "$SERVER" && p || f "OPTIONS method check"
grep -q 'sendCorsPreflight' "$SERVER" && p || f "sendCorsPreflight called in handle()"

# Allowed methods include required methods
grep -q 'GET, POST, PATCH' "$SERVER" && p || f "GET, POST, PATCH in allowed methods"
grep -q 'DELETE, OPTIONS' "$SERVER" && p || f "DELETE, OPTIONS in allowed methods"

# Allowed headers include custom headers
grep -q 'x-admin-token' "$SERVER" && p || f "x-admin-token in allowed headers"
grep -q 'x-frame-device-key' "$SERVER" && p || f "x-frame-device-key in allowed headers"
grep -q 'Authorization' "$SERVER" && p || f "Authorization in allowed headers"
grep -q 'Content-Type' "$SERVER" && p || f "Content-Type in allowed headers"

# Existing sendJson still has CORS
grep -q '"access-control-allow-origin": "\*"' "$SERVER" && p || f "sendJson still has access-control-allow-origin"

echo "  Static contract: $PASS passed, $FAIL failed"

# ═══════════════════════════════════════════════════════════════
# Step 3: Live server — bootstrap
# ═══════════════════════════════════════════════════════════════
step_header "Live server — bootstrap"

PORT=14987
DB_FILE="/tmp/aos-cors-check-$$.db"
ADMIN_TOKEN="test-admin-cors-token-$$"

# Start server
AOS_PORT=$PORT AOS_DB="$DB_FILE" AUTOPOIESIS_FRAMES_ADMIN_TOKEN="$ADMIN_TOKEN" \
  node hosted-api/server.js > /tmp/aos-cors-server-$$.log 2>&1 &
SERVER_PID=$!
sleep 1.5

# Check server started
if kill -0 "$SERVER_PID" 2>/dev/null; then
  p "Server started (PID $SERVER_PID)"
else
  f "Server failed to start"
  cat /tmp/aos-cors-server-$$.log
fi

# ═══════════════════════════════════════════════════════════════
# Step 4: Preflight requests
# ═══════════════════════════════════════════════════════════════
step_header "Preflight (OPTIONS) responses"

# Preflight to health endpoint
OPT_HEALTH=$(curl -s -o /dev/null -w '%{http_code}' \
  -X OPTIONS "http://127.0.0.1:$PORT/frames/health")
[ "$OPT_HEALTH" = "204" ] && p || f "OPTIONS /frames/health → 204 (got $OPT_HEALTH)"

# Preflight response headers
OPT_HEADERS=$(curl -sI -X OPTIONS "http://127.0.0.1:$PORT/frames/health")
echo "$OPT_HEADERS" | grep -qi 'access-control-allow-origin' && p || f "OPTIONS response has access-control-allow-origin"
echo "$OPT_HEADERS" | grep -qi 'access-control-allow-methods' && p || f "OPTIONS response has access-control-allow-methods"
echo "$OPT_HEADERS" | grep -qi 'access-control-allow-headers' && p || f "OPTIONS response has access-control-allow-headers"

# Preflight body is empty
OPT_BODY=$(curl -s -X OPTIONS "http://127.0.0.1:$PORT/frames/health")
[ -z "$OPT_BODY" ] && p || f "OPTIONS response body is empty (got: $(echo "$OPT_BODY" | head -c 80))"

# Preflight to unknown route (should still return 204 with CORS headers)
OPT_UNKNOWN=$(curl -s -o /dev/null -w '%{http_code}' \
  -X OPTIONS "http://127.0.0.1:$PORT/nonexistent/path")
[ "$OPT_UNKNOWN" = "204" ] && p || f "OPTIONS /nonexistent → 204 (got $OPT_UNKNOWN)"

# Preflight to admin endpoint
OPT_ADMIN=$(curl -s -o /dev/null -w '%{http_code}' \
  -X OPTIONS "http://127.0.0.1:$PORT/frames/admin/bundle")
[ "$OPT_ADMIN" = "204" ] && p || f "OPTIONS /frames/admin/bundle → 204 (got $OPT_ADMIN)"

# Preflight to device endpoint
OPT_DEVICE=$(curl -s -o /dev/null -w '%{http_code}' \
  -X OPTIONS "http://127.0.0.1:$PORT/frames/device/test-123/settings")
[ "$OPT_DEVICE" = "204" ] && p || f "OPTIONS /frames/device/:id/settings → 204 (got $OPT_DEVICE)"

echo "  Preflight: $PASS passed, $FAIL failed"

# ═══════════════════════════════════════════════════════════════
# Step 5: Actual requests include CORS headers
# ═══════════════════════════════════════════════════════════════
step_header "CORS headers on actual requests"

# Health GET
HEALTH_HEADERS=$(curl -sI "http://127.0.0.1:$PORT/frames/health")
echo "$HEALTH_HEADERS" | grep -qi 'access-control-allow-origin.*\*' && p || f "GET /health has access-control-allow-origin: *"

# Health body
HEALTH_BODY=$(curl -s "http://127.0.0.1:$PORT/frames/health")
echo "$HEALTH_BODY" | grep -q '"ok"' && p || f "GET /health returns ok"

# 404 response has CORS headers
NOTFOUND_HEADERS=$(curl -sI "http://127.0.0.1:$PORT/nonexistent")
echo "$NOTFOUND_HEADERS" | grep -qi 'access-control-allow-origin' && p || f "404 response has access-control-allow-origin"

# Admin endpoint (401 without token) has CORS
ADMIN_HEADERS=$(curl -sI "http://127.0.0.1:$PORT/frames/admin/bundle")
echo "$ADMIN_HEADERS" | grep -qi 'access-control-allow-origin' && p || f "401 admin response has access-control-allow-origin"

echo "  CORS on actual requests: $PASS passed, $FAIL failed"

# ═══════════════════════════════════════════════════════════════
# Step 6: Full CORS flow — preflight then actual
# ═══════════════════════════════════════════════════════════════
step_header "Full CORS flow — preflight → actual"

# Register a device for testing
REG_BODY=$(curl -s -X POST "http://127.0.0.1:$PORT/frames/device/register" \
  -H "Content-Type: application/json" \
  -d '{"deviceType":"test-frame","deviceName":"cors-test-device"}')
echo "$REG_BODY" | grep -q '"ok"' && p || f "Device registration succeeds"
DEVICE_ID=$(echo "$REG_BODY" | grep -o '"deviceId":"[^"]*"' | head -1 | cut -d'"' -f4)
DEVICE_KEY=$(echo "$REG_BODY" | grep -o '"deviceApiKey":"[^"]*"' | head -1 | cut -d'"' -f4)

# Preflight before device settings
OPT_SETTINGS=$(curl -s -o /dev/null -w '%{http_code}' \
  -X OPTIONS "http://127.0.0.1:$PORT/frames/device/$DEVICE_ID/settings")
[ "$OPT_SETTINGS" = "204" ] && p || f "OPTIONS device settings → 204"

# Actual GET with device key has CORS
SETTINGS_HEADERS=$(curl -sI "http://127.0.0.1:$PORT/frames/device/$DEVICE_ID/settings" \
  -H "x-frame-device-key: $DEVICE_KEY")
echo "$SETTINGS_HEADERS" | grep -qi 'access-control-allow-origin' && p || f "Device settings GET has CORS"

# Preflight before admin bundle
OPT_BUNDLE=$(curl -s -o /dev/null -w '%{http_code}' \
  -X OPTIONS "http://127.0.0.1:$PORT/frames/admin/bundle")
[ "$OPT_BUNDLE" = "204" ] && p || f "OPTIONS admin bundle → 204"

# Admin bundle GET with token has CORS
BUNDLE_HEADERS=$(curl -sI "http://127.0.0.1:$PORT/frames/admin/bundle" \
  -H "x-admin-token: $ADMIN_TOKEN")
echo "$BUNDLE_HEADERS" | grep -qi 'access-control-allow-origin' && p || f "Admin bundle GET has CORS"

echo "  Full flow: $PASS passed, $FAIL failed"

# ═══════════════════════════════════════════════════════════════
# Step 7: No regression — existing endpoints work
# ═══════════════════════════════════════════════════════════════
step_header "No regression — existing endpoints"

# Settings still works
SETTINGS=$(curl -s "http://127.0.0.1:$PORT/frames/device/$DEVICE_ID/settings" \
  -H "x-frame-device-key: $DEVICE_KEY")
echo "$SETTINGS" | grep -q '"ok"' && p || f "GET settings still works"

# Health still works
HEALTH=$(curl -s "http://127.0.0.1:$PORT/frames/health")
echo "$HEALTH" | grep -q '"ok"' && p || f "GET health still works"

# Admin bundle still works
BUNDLE=$(curl -s "http://127.0.0.1:$PORT/frames/admin/bundle" \
  -H "x-admin-token: $ADMIN_TOKEN")
echo "$BUNDLE" | grep -q '"ok"' && p || f "GET admin bundle still works"

# Registration still works for second device
REG2=$(curl -s -X POST "http://127.0.0.1:$PORT/frames/device/register" \
  -H "Content-Type: application/json" \
  -d '{"deviceType":"test-frame-2","deviceName":"cors-test-device-2"}')
echo "$REG2" | grep -q '"ok"' && p || f "Second device registration still works"

echo "  Regression: $PASS passed, $FAIL failed"

# ═══════════════════════════════════════════════════════════════
# Cleanup
# ═══════════════════════════════════════════════════════════════
kill "$SERVER_PID" 2>/dev/null || true
rm -f "$DB_FILE" /tmp/aos-cors-server-$$.log
wait "$SERVER_PID" 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════
TOTAL=$((PASS + FAIL + SKIP))
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CORS preflight check: $PASS passed, $FAIL failed, $SKIP skipped ($TOTAL total)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
