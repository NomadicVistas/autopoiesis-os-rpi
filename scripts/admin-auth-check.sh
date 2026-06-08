#!/usr/bin/env bash
# admin-auth-check.sh
# Validation gate for hosted API admin endpoint authentication.
# Proves: all admin endpoints require AUTOPOIESIS_FRAMES_ADMIN_TOKEN,
#         token-not-configured returns 503, missing token returns 401,
#         invalid token returns 403, valid token grants access,
#         device endpoints remain unaffected.
set -euo pipefail

CHECKS=0 PASS=0 FAIL=0
R=$(cd "$(dirname "$0")/.." && pwd)

die()   { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
try()   { CHECKS=$((CHECKS+1)); if "$@"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi; }
assert(){ CHECKS=$((CHECKS+1)); if eval "$2"; then PASS=$((PASS+1)); else die "$1"; fi; }

C() { printf "\033[36m%-14s\033[0m %s\n" "$1" "$2"; }

# ── Step 1: Syntax validation ─────────────────────────────────────────────────
C "STEP-1" "Syntax validation"
try node --check "$R/hosted-api/server.js"
try node --check "$R/hosted-api/db.js"
try bash -n "$0"

# ── Step 2: Static contract ────────────────────────────────────────────────────
C "STEP-2" "Static contract"

SERVER="$R/hosted-api/server.js"

# authenticateAdmin function exists
try grep -q 'function authenticateAdmin' "$SERVER"

# ADMIN_TOKEN constant references the env var
try grep -q 'AUTOPOIESIS_FRAMES_ADMIN_TOKEN' "$SERVER"

# All admin routes have authenticateAdmin gate (11 routes)
ADMIN_AUTH_COUNT=$(grep -c 'authenticateAdmin(req)' "$SERVER")
assert "All admin routes have auth gate (found $ADMIN_AUTH_COUNT, need ≥11)" \
  '[ "$ADMIN_AUTH_COUNT" -ge 11 ]'

# authenticateDevice still exists (device auth unchanged)
try grep -q 'function authenticateDevice' "$SERVER"

# ── Step 3: Token-not-configured → 503 on admin, device endpoints fine ───────
C "STEP-3" "No token configured → 503"

DB3="/tmp/test-admin-auth-503-$$.db"
PORT3=$((31600 + $$ % 1000))
PID3=""
rm -f "$DB3"

# Start WITHOUT AUTOPOIESIS_FRAMES_ADMIN_TOKEN
AOS_DB="$DB3" AOS_PORT="$PORT3" AOS_HOST="127.0.0.1" \
  node "$R/hosted-api/server.js" > /tmp/aos-auth-3-$$.log 2>&1 &
PID3=$!

for i in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:$PORT3/health" > /dev/null 2>&1; then break; fi
  sleep 0.3
done

# Admin endpoints → 503
HTTP503_BUNDLE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT3/frames/admin/bundle")
assert "Admin bundle returns 503 when no token configured ($HTTP503_BUNDLE)" \
  '[ "$HTTP503_BUNDLE" = "503" ]'

HTTP503_DELIVERIES=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT3/frames/admin/broadcast-deliveries")
assert "Admin broadcast deliveries returns 503 ($HTTP503_DELIVERIES)" \
  '[ "$HTTP503_DELIVERIES" = "503" ]'

HTTP503_CREATE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "http://127.0.0.1:$PORT3/frames/admin/broadcasts" \
  -H "content-type: application/json" -d '{"type":"artwork","title":"test"}')
assert "Admin create broadcast returns 503 ($HTTP503_CREATE)" \
  '[ "$HTTP503_CREATE" = "503" ]'

HTTP503_STATS=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT3/frames/admin/broadcasts/stats")
assert "Admin stats returns 503 ($HTTP503_STATS)" \
  '[ "$HTTP503_STATS" = "503" ]'

# Health endpoint still works
HTTP_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT3/health")
assert "Health endpoint works without admin token ($HTTP_HEALTH)" \
  '[ "$HTTP_HEALTH" = "200" ]'

# Device registration still works (no auth needed)
HTTP_REG=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "http://127.0.0.1:$PORT3/frames/device/register" \
  -H "content-type: application/json" -d '{"deviceType":"rpi"}')
assert "Device registration works without admin token ($HTTP_REG)" \
  '[ "$HTTP_REG" = "200" ]'

kill "$PID3" 2>/dev/null || true; wait "$PID3" 2>/dev/null || true
rm -f "$DB3"

# ── Step 4: Token configured, missing token → 401 ─────────────────────────────
C "STEP-4" "Token configured, missing token → 401"

DB4="/tmp/test-admin-auth-401-$$.db"
PORT4=$((31700 + $$ % 1000))
PID4=""
TOKEN4="secret-token-step4"
rm -f "$DB4"

AOS_DB="$DB4" AOS_PORT="$PORT4" AOS_HOST="127.0.0.1" \
  AUTOPOIESIS_FRAMES_ADMIN_TOKEN="$TOKEN4" \
  node "$R/hosted-api/server.js" > /tmp/aos-auth-4-$$.log 2>&1 &
PID4=$!

for i in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:$PORT4/health" > /dev/null 2>&1; then break; fi
  sleep 0.3
done

HTTP401=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT4/frames/admin/bundle")
assert "Admin bundle returns 401 when no token provided ($HTTP401)" \
  '[ "$HTTP401" = "401" ]'

ERR_MSG=$(curl -s "http://127.0.0.1:$PORT4/frames/admin/bundle")
assert "Error body mentions missing admin token" \
  'echo "$ERR_MSG" | grep -q "Missing admin token"'

HTTP401_STATS=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT4/frames/admin/broadcasts/stats")
assert "Admin stats returns 401 ($HTTP401_STATS)" \
  '[ "$HTTP401_STATS" = "401" ]'

HTTP401_LIST=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT4/frames/admin/broadcasts")
assert "Admin list broadcasts returns 401 ($HTTP401_LIST)" \
  '[ "$HTTP401_LIST" = "401" ]'

kill "$PID4" 2>/dev/null || true; wait "$PID4" 2>/dev/null || true
rm -f "$DB4"

# ── Step 5: Invalid token → 403 ───────────────────────────────────────────────
C "STEP-5" "Invalid token → 403"

DB5="/tmp/test-admin-auth-403-$$.db"
PORT5=$((31800 + $$ % 1000))
PID5=""
TOKEN5="correct-token-step5"
rm -f "$DB5"

AOS_DB="$DB5" AOS_PORT="$PORT5" AOS_HOST="127.0.0.1" \
  AUTOPOIESIS_FRAMES_ADMIN_TOKEN="$TOKEN5" \
  node "$R/hosted-api/server.js" > /tmp/aos-auth-5-$$.log 2>&1 &
PID5=$!

for i in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:$PORT5/health" > /dev/null 2>&1; then break; fi
  sleep 0.3
done

# Wrong x-admin-token → 403
HTTP403=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "x-admin-token: wrong-token" \
  "http://127.0.0.1:$PORT5/frames/admin/bundle")
assert "Admin bundle returns 403 with wrong x-admin-token ($HTTP403)" \
  '[ "$HTTP403" = "403" ]'

ERR3=$(curl -s -H "x-admin-token: wrong-token" "http://127.0.0.1:$PORT5/frames/admin/bundle")
assert "Error body mentions invalid admin token" \
  'echo "$ERR3" | grep -q "Invalid admin token"'

# Wrong Bearer → 403
HTTP403B=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer wrong-bearer" \
  "http://127.0.0.1:$PORT5/frames/admin/bundle")
assert "Admin bundle returns 403 with wrong Bearer ($HTTP403B)" \
  '[ "$HTTP403B" = "403" ]'

kill "$PID5" 2>/dev/null || true; wait "$PID5" 2>/dev/null || true
rm -f "$DB5"

# ── Step 6: Valid token → access granted (full CRUD lifecycle) ────────────────
C "STEP-6" "Valid token → access granted"

DB6="/tmp/test-admin-auth-ok-$$.db"
PORT6=$((31900 + $$ % 1000))
PID6=""
TOKEN6="valid-token-step6"
rm -f "$DB6"

AOS_DB="$DB6" AOS_PORT="$PORT6" AOS_HOST="127.0.0.1" \
  AUTOPOIESIS_FRAMES_ADMIN_TOKEN="$TOKEN6" \
  node "$R/hosted-api/server.js" > /tmp/aos-auth-6-$$.log 2>&1 &
PID6=$!

for i in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:$PORT6/health" > /dev/null 2>&1; then break; fi
  sleep 0.3
done

AUTH_HEADER="x-admin-token: $TOKEN6"

# Admin bundle with x-admin-token → 200
HTTP200=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "$AUTH_HEADER" "http://127.0.0.1:$PORT6/frames/admin/bundle")
assert "Admin bundle returns 200 with valid x-admin-token ($HTTP200)" \
  '[ "$HTTP200" = "200" ]'

# Admin bundle with Bearer → 200
HTTP200B=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN6" \
  "http://127.0.0.1:$PORT6/frames/admin/bundle")
assert "Admin bundle returns 200 with valid Bearer ($HTTP200B)" \
  '[ "$HTTP200B" = "200" ]'

# Admin broadcast deliveries → 200
HTTP200D=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "$AUTH_HEADER" "http://127.0.0.1:$PORT6/frames/admin/broadcast-deliveries")
assert "Admin broadcast deliveries returns 200 ($HTTP200D)" \
  '[ "$HTTP200D" = "200" ]'

# Admin stats → 200
HTTP200S=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "$AUTH_HEADER" "http://127.0.0.1:$PORT6/frames/admin/broadcasts/stats")
assert "Admin stats returns 200 ($HTTP200S)" \
  '[ "$HTTP200S" = "200" ]'

# Create broadcast → 200
BC_RAW=$(curl -s -w "\n%{http_code}" \
  -H "$AUTH_HEADER" -H "content-type: application/json" \
  -d '{"type":"artwork","title":"Test Art","priority":"normal"}' \
  -X POST "http://127.0.0.1:$PORT6/frames/admin/broadcasts")
BC_HTTP=$(echo "$BC_RAW" | tail -1)
BC_BODY=$(echo "$BC_RAW" | sed '$d')
assert "Admin create broadcast returns 200 ($BC_HTTP)" \
  '[ "$BC_HTTP" = "200" ]'

# Parse broadcast ID
BC_ID=$(echo "$BC_BODY" | jq -r '.broadcast.id // empty' 2>/dev/null || echo "")

if [ -n "$BC_ID" ] && [ "$BC_ID" != "null" ]; then
  # List broadcasts → 200
  HTTP200L=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "$AUTH_HEADER" "http://127.0.0.1:$PORT6/frames/admin/broadcasts")
  assert "Admin list broadcasts returns 200 ($HTTP200L)" \
    '[ "$HTTP200L" = "200" ]'

  # Get broadcast → 200
  HTTP200G=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "$AUTH_HEADER" "http://127.0.0.1:$PORT6/frames/admin/broadcasts/$BC_ID")
  assert "Admin get broadcast returns 200 ($HTTP200G)" \
    '[ "$HTTP200G" = "200" ]'

  # Update broadcast → 200
  HTTP200U=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "$AUTH_HEADER" -H "content-type: application/json" \
    -d '{"title":"Updated Art"}' \
    -X PATCH "http://127.0.0.1:$PORT6/frames/admin/broadcasts/$BC_ID")
  assert "Admin update broadcast returns 200 ($HTTP200U)" \
    '[ "$HTTP200U" = "200" ]'

  # Publish → 200
  HTTP200P=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "$AUTH_HEADER" \
    -X POST "http://127.0.0.1:$PORT6/frames/admin/broadcasts/$BC_ID/publish")
  assert "Admin publish returns 200 ($HTTP200P)" \
    '[ "$HTTP200P" = "200" ]'

  # Unpublish → 200
  HTTP200UP=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "$AUTH_HEADER" \
    -X POST "http://127.0.0.1:$PORT6/frames/admin/broadcasts/$BC_ID/unpublish")
  assert "Admin unpublish returns 200 ($HTTP200UP)" \
    '[ "$HTTP200UP" = "200" ]'
else
  die "Could not parse broadcast ID from create response (body: ${BC_BODY:0:100})"
fi

# Register + pair a device for admin snapshot test
REG6_RAW=$(curl -s -X POST "http://127.0.0.1:$PORT6/frames/device/register" \
  -H "content-type: application/json" -d '{"deviceType":"rpi"}')
DEV6=$(echo "$REG6_RAW" | jq -r '.device.deviceId // empty' 2>/dev/null || echo "")

if [ -n "$DEV6" ] && [ "$DEV6" != "null" ]; then
  # Admin snapshot → 200 (device exists, even unpaired)
  HTTP200SN=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "$AUTH_HEADER" "http://127.0.0.1:$PORT6/frames/device/$DEV6/admin-snapshot")
  assert "Admin snapshot returns 200 ($HTTP200SN)" \
    '[ "$HTTP200SN" = "200" ]'
else
  die "Could not register device for snapshot test"
fi

kill "$PID6" 2>/dev/null || true; wait "$PID6" 2>/dev/null || true
rm -f "$DB6"

# ── Step 7: Device endpoints unaffected by admin auth ──────────────────────────
C "STEP-7" "Device endpoints unaffected"

DB7="/tmp/test-admin-auth-dev-$$.db"
PORT7=$((32000 + $$ % 1000))
PID7=""
TOKEN7="admin-token-step7"
rm -f "$DB7"

AOS_DB="$DB7" AOS_PORT="$PORT7" AOS_HOST="127.0.0.1" \
  AUTOPOIESIS_FRAMES_ADMIN_TOKEN="$TOKEN7" \
  node "$R/hosted-api/server.js" > /tmp/aos-auth-7-$$.log 2>&1 &
PID7=$!

for i in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:$PORT7/health" > /dev/null 2>&1; then break; fi
  sleep 0.3
done

# Health (no auth)
HTTPH=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT7/health")
assert "Health works without auth ($HTTPH)" '[ "$HTTPH" = "200" ]'

# Device registration (no auth)
REGR=$(curl -s -X POST "http://127.0.0.1:$PORT7/frames/device/register" \
  -H "content-type: application/json" -d '{"deviceType":"rpi"}')
DEV7=$(echo "$REGR" | jq -r '.device.deviceId // empty' 2>/dev/null || echo "")
KEY7=$(echo "$REGR" | jq -r '.device.deviceApiKey // empty' 2>/dev/null || echo "")
assert "Device registration works without admin token" \
  '[ -n "$DEV7" ] && [ "$DEV7" != "null" ] && [ -n "$KEY7" ]'

# Device settings read (no auth)
HTTPSR=$(curl -s -o /dev/null -w "%{http_code}" \
  "http://127.0.0.1:$PORT7/frames/device/$DEV7/settings")
assert "Device settings read works without auth ($HTTPSR)" \
  '[ "$HTTPSR" = "200" ]'

# Device pairing status (no auth)
HTTPPS=$(curl -s -o /dev/null -w "%{http_code}" \
  "http://127.0.0.1:$PORT7/frames/device/$DEV7/pairing-status")
assert "Device pairing status works without auth ($HTTPPS)" \
  '[ "$HTTPPS" = "200" ]'

# Device auth-gated endpoints require device key, not admin token
# Without device key → 401
HTTP401D=$(curl -s -o /dev/null -w "%{http_code}" \
  "http://127.0.0.1:$PORT7/frames/device/$DEV7/stream")
assert "Device stream returns 401 without device key ($HTTP401D)" \
  '[ "$HTTP401D" = "401" ]'

# With device key but unpaired → 403 (device not paired)
HTTP403U=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "x-frame-device-key: $KEY7" \
  "http://127.0.0.1:$PORT7/frames/device/$DEV7/stream")
assert "Device stream returns 403 for unpaired device ($HTTP403U)" \
  '[ "$HTTP403U" = "403" ]'

# Admin token should NOT grant device endpoint access
HTTP403A=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "x-admin-token: $TOKEN7" \
  "http://127.0.0.1:$PORT7/frames/device/$DEV7/stream")
assert "Admin token does NOT grant device endpoint access ($HTTP403A)" \
  '[ "$HTTP403A" = "401" ]'

kill "$PID7" 2>/dev/null || true; wait "$PID7" 2>/dev/null || true
rm -f "$DB7"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════════════"
if [ "$FAIL" -eq 0 ]; then
  echo "✅ ALL $CHECKS checks passed ($PASS passed, $FAIL failed)"
else
  echo "❌ $CHECKS checks: $PASS passed, $FAIL failed"
fi
echo "════════════════════════════════════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
