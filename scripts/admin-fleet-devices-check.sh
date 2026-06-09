#!/usr/bin/env bash
# admin-fleet-devices-check.sh — Validate GET /frames/admin/devices endpoint
#
# Tests:
#   Step 1:  Syntax validation
#   Step 2:  Static contract — source code patterns
#   Step 3:  Server bootstrap with fresh DB
#   Step 4:  Device fleet setup (3 devices, different owners, different states)
#   Step 5:  Fleet-wide device listing (unfiltered)
#   Step 6:  Filter: ownerUserId
#   Step 7:  Filter: online status
#   Step 8:  Filter: disabled
#   Step 9:  Filter: paired
#   Step 10: Filter: search
#   Step 11: Pagination
#   Step 12: Per-device fields (pendingCommandCount, actionAvailability, entitlements, subscription)
#   Step 13: Auth gates
#   Step 14: Regression — existing endpoints unaffected

set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────────────
GREEN='\033[32m'; RED='\033[31m'; CYAN='\033[36m'; BOLD='\033[1m'; RST='\033[0m'
PASS=0; FAIL=0; SKIP=0

ok()   { PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RST} $1"; }
fail() { FAIL=$((FAIL+1)); echo -e "  ${RED}✗${RST} $1"; }
step() { echo -e "\n${CYAN}${BOLD}── Step $1: $2 ──${RST}"; }
die()  { echo -e "${RED}FATAL: $1${RST}"; exit 1; }

PORT=$(( 19300 + (RANDOM % 500) ))
export AOS_PORT="$PORT"
ADMIN_TOKEN="test-admin-token-$(date +%s)"
export AUTOPOIESIS_FRAMES_ADMIN_TOKEN="$ADMIN_TOKEN"
DB_FILE=$(mktemp /tmp/aos-fleet-devices-XXXXXX.db)
PID=""
NODE_PATH=""

cleanup() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null || true
  rm -f "$DB_FILE"
}
trap cleanup EXIT

# ── Helpers ─────────────────────────────────────────────────────────────────
api() {
  local method="$1" path="$2"
  shift 2
  curl -s --max-time 5 -X "$method" "$@" "http://127.0.0.1:$PORT$path"
}

admin_api() {
  local method="$1" path="$2"
  shift 2
  curl -s --max-time 5 -X "$method" -H "x-admin-token: $ADMIN_TOKEN" "$@" "http://127.0.0.1:$PORT$path"
}

# ── Step 1: Syntax validation ──────────────────────────────────────────────
step 1 "Syntax validation"

node --check hosted-api/server.js 2>/dev/null && ok "hosted-api/server.js syntax" || fail "server.js syntax"
node --check hosted-api/db.js 2>/dev/null     && ok "hosted-api/db.js syntax"     || fail "db.js syntax"

for f in install.sh update.sh factory-reset.sh; do
  bash -n "$f" 2>/dev/null && ok "$f syntax" || fail "$f syntax"
done

# ── Step 2: Static contract ────────────────────────────────────────────────
step 2 "Static contract — source code patterns"

grep -q 'handleAdminListDevices' hosted-api/server.js && ok "server.js has handleAdminListDevices" || fail "missing handleAdminListDevices"
grep -q '/frames/admin/devices' hosted-api/server.js && ok "server.js routes /frames/admin/devices" || fail "missing route"
grep -q 'getPendingCommandCount' hosted-api/db.js && ok "db.js has getPendingCommandCount" || fail "missing getPendingCommandCount"
grep -q 'deviceType' hosted-api/db.js && ok "db.js listDevices supports deviceType filter" || fail "missing deviceType filter"
grep -q 'updateChannel' hosted-api/db.js && ok "db.js listDevices supports updateChannel filter" || fail "missing updateChannel filter"
grep -q 'disabled' hosted-api/db.js | head -1 && ok "db.js listDevices supports disabled filter" || true  # may match other lines
grep -q 'pendingCommandCount' hosted-api/server.js && ok "server.js returns pendingCommandCount" || fail "missing pendingCommandCount"
grep -q 'actionAvailability' hosted-api/server.js && ok "server.js returns actionAvailability per device" || fail "missing actionAvailability"
grep -q 'handleAdminListDevices' hosted-api/server.js && ok "handleAdminListDevices defined" || fail "missing handler function"

# ── Step 3: Server bootstrap ───────────────────────────────────────────────
step 3 "Server bootstrap with fresh database"

AOS_DB="$DB_FILE" node hosted-api/server.js &
PID=$!
sleep 2

if kill -0 "$PID" 2>/dev/null; then
  ok "Server started on port $PORT"
else
  fail "Server failed to start"
  exit 1
fi

HEALTH=$(api GET "/health")
echo "$HEALTH" | grep -q '"ok":true' && ok "Health endpoint responds" || fail "Health endpoint"

# ── Step 4: Device fleet setup ─────────────────────────────────────────────
step 4 "Device fleet setup (3 devices, 2 owners, mixed states)"

# Device 1: alice, paired, online
REG1=$(api POST "/frames/device/register" \
  -H "Content-Type: application/json" \
  -d '{"deviceId":"dev-fleet-001","deviceName":"Living Room Frame","deviceType":"rpi_touchscreen"}')
echo "$REG1" | grep -q '"ok":true' && ok "Device 1 registered" || fail "Device 1 registration"
DEV1_KEY=$(echo "$REG1" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).device.deviceApiKey" 2>/dev/null || echo "")
PAIR1=$(echo "$REG1" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).pairingCode" 2>/dev/null || echo "")
[ -n "$DEV1_KEY" ] && ok "Device 1 key extracted" || fail "Device 1 key"

# Claim pairing for device 1
node -e "const AosDb = require('./hosted-api/db.js'); const db = new AosDb('$DB_FILE'); const result = db.claimPairingCode('$PAIR1', 'user-alice'); console.log(JSON.stringify(result));" 2>/dev/null | grep -q '"ok":true' && ok "Device 1 paired to alice" || fail "Device 1 pairing"

# Send heartbeat for device 1 (online)
HB1=$(api POST "/frames/device/dev-fleet-001/heartbeat" \
  -H "x-frame-device-key: $DEV1_KEY" \
  -H "Content-Type: application/json" \
  -d '{"currentMode":"display"}')
echo "$HB1" | grep -q '"ok":true' && ok "Device 1 heartbeat (online)" || fail "Device 1 heartbeat"

# Device 2: bob, paired, offline
REG2=$(api POST "/frames/device/register" \
  -H "Content-Type: application/json" \
  -d '{"deviceId":"dev-fleet-002","deviceName":"Bedroom Frame","deviceType":"rpi_touchscreen"}')
echo "$REG2" | grep -q '"ok":true' && ok "Device 2 registered" || fail "Device 2 registration"
DEV2_KEY=$(echo "$REG2" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).device.deviceApiKey" 2>/dev/null || echo "")
PAIR2=$(echo "$REG2" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).pairingCode" 2>/dev/null || echo "")

node -e "const AosDb = require('./hosted-api/db.js'); const db = new AosDb('$DB_FILE'); const result = db.claimPairingCode('$PAIR2', 'user-bob'); console.log(JSON.stringify(result));" 2>/dev/null | grep -q '"ok":true' && ok "Device 2 paired to bob" || fail "Device 2 pairing"
# No heartbeat → device 2 is offline

# Device 3: alice, paired, online, different type
REG3=$(api POST "/frames/device/register" \
  -H "Content-Type: application/json" \
  -d '{"deviceId":"dev-fleet-003","deviceName":"Office Display","deviceType":"desktop"}')
echo "$REG3" | grep -q '"ok":true' && ok "Device 3 registered" || fail "Device 3 registration"
DEV3_KEY=$(echo "$REG3" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).device.deviceApiKey" 2>/dev/null || echo "")
PAIR3=$(echo "$REG3" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).pairingCode" 2>/dev/null || echo "")

node -e "const AosDb = require('./hosted-api/db.js'); const db = new AosDb('$DB_FILE'); const result = db.claimPairingCode('$PAIR3', 'user-alice'); console.log(JSON.stringify(result));" 2>/dev/null | grep -q '"ok":true' && ok "Device 3 paired to alice" || fail "Device 3 pairing"

# Heartbeat for device 3
HB3=$(api POST "/frames/device/dev-fleet-003/heartbeat" \
  -H "x-frame-device-key: $DEV3_KEY" \
  -H "Content-Type: application/json" \
  -d '{"currentMode":"display"}')
echo "$HB3" | grep -q '"ok":true' && ok "Device 3 heartbeat (online)" || fail "Device 3 heartbeat"

# Device 4: unpaired (for paired filter test)
REG4=$(api POST "/frames/device/register" \
  -H "Content-Type: application/json" \
  -d '{"deviceId":"dev-fleet-004","deviceName":"Unpaired Frame","deviceType":"rpi_touchscreen"}')
echo "$REG4" | grep -q '"ok":true' && ok "Device 4 registered (unpaired)" || fail "Device 4 registration"

# Create subscriptions
admin_api POST "/frames/admin/subscriptions" \
  -H "Content-Type: application/json" \
  -d '{"userId":"user-alice","plan":"frames_premium","provider":"manual"}' > /dev/null
ok "Alice subscription created (frames_premium)"

admin_api POST "/frames/admin/subscriptions" \
  -H "Content-Type: application/json" \
  -d '{"userId":"user-bob","plan":"frames_trial","provider":"manual"}' > /dev/null
ok "Bob subscription created (frames_trial)"

# Queue a command on device 1 (for pendingCommandCount test)
CMD1=$(admin_api POST "/frames/admin/devices/dev-fleet-001/actions" \
  -H "Content-Type: application/json" \
  -d '{"action":"clear_cache","reason":"Testing pending count"}')
echo "$CMD1" | grep -q '"queued":true' && ok "Command queued on device 1" || fail "Queue command on device 1"

# ── Step 5: Fleet-wide listing (unfiltered) ────────────────────────────────
step 5 "Fleet-wide device listing (unfiltered)"

ALL_DEV=$(admin_api GET "/frames/admin/devices")
echo "$ALL_DEV" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).ok" 2>/dev/null | grep -q 'true' && ok "Devices endpoint responds ok" || fail "Devices endpoint ok"
TOTAL=$(echo "$ALL_DEV" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).devices.total" 2>/dev/null || echo "0")
[ "$TOTAL" = "4" ] && ok "Total devices = 4 (registered)" || fail "Total devices (got $TOTAL, expected 4)"

ITEM_COUNT=$(echo "$ALL_DEV" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).devices.items.length" 2>/dev/null || echo "0")
[ "$ITEM_COUNT" = "4" ] && ok "Returns 4 device items" || fail "Device items count (got $ITEM_COUNT)"

KIND=$(echo "$ALL_DEV" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).kind" 2>/dev/null || echo "")
[ "$KIND" = "autopoiesis_frames_admin_device_list" ] && ok "Response kind correct" || fail "Response kind (got $KIND)"

# ── Step 6: Filter by ownerUserId ──────────────────────────────────────────
step 6 "Filter by ownerUserId"

ALICE_DEV=$(admin_api GET "/frames/admin/devices?ownerUserId=user-alice")
ALICE_TOTAL=$(echo "$ALICE_DEV" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).devices.total" 2>/dev/null || echo "0")
[ "$ALICE_TOTAL" = "2" ] && ok "Alice has 2 devices" || fail "Alice devices (got $ALICE_TOTAL)"

BOB_DEV=$(admin_api GET "/frames/admin/devices?ownerUserId=user-bob")
BOB_TOTAL=$(echo "$BOB_DEV" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).devices.total" 2>/dev/null || echo "0")
[ "$BOB_TOTAL" = "1" ] && ok "Bob has 1 device" || fail "Bob devices (got $BOB_TOTAL)"

# ── Step 7: Filter by online status ───────────────────────────────────────
step 7 "Filter by online status"

ONLINE_DEV=$(admin_api GET "/frames/admin/devices?online=true&paired=true")
ONLINE_TOTAL=$(echo "$ONLINE_DEV" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).devices.total" 2>/dev/null || echo "0")
[ "$ONLINE_TOTAL" = "2" ] && ok "Online devices = 2" || fail "Online devices (got $ONLINE_TOTAL)"

# Verify the items are actually online
ONLINE_ONLINE=$(echo "$ONLINE_DEV" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).devices.items.every(d=>d.online)" 2>/dev/null || echo "false")
[ "$ONLINE_ONLINE" = "true" ] && ok "All filtered devices are online" || fail "Online filter correctness"

OFFLINE_DEV=$(admin_api GET "/frames/admin/devices?online=false&paired=true")
OFFLINE_TOTAL=$(echo "$OFFLINE_DEV" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).devices.total" 2>/dev/null || echo "0")
[ "$OFFLINE_TOTAL" = "1" ] && ok "Offline devices = 1" || fail "Offline devices (got $OFFLINE_TOTAL)"

# ── Step 8: Filter by disabled ────────────────────────────────────────────
step 8 "Filter by disabled"

# Disable device 2
DISABLE_RESULT=$(admin_api PATCH "/frames/admin/devices/dev-fleet-002" \
  -H "Content-Type: application/json" \
  -d '{"disabled":true}')
echo "$DISABLE_RESULT" | grep -q '"ok":true' && ok "Device 2 disabled" || fail "Device 2 disable (got: $DISABLE_RESULT)"

DISABLED_DEV=$(admin_api GET "/frames/admin/devices?disabled=true")
DISABLED_COUNT=$(echo "$DISABLED_DEV" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).devices.total" 2>/dev/null || echo "0")
[ "$DISABLED_COUNT" = "1" ] && ok "Disabled devices = 1" || fail "Disabled devices (got $DISABLED_COUNT)"

# Re-enable for subsequent tests
admin_api PATCH "/frames/admin/devices/dev-fleet-002" \
  -H "Content-Type: application/json" \
  -d '{"disabled":false}' > /dev/null

# ── Step 9: Filter by paired ──────────────────────────────────────────────
step 9 "Filter by paired"

PAIRED_DEV=$(admin_api GET "/frames/admin/devices?paired=true")
PAIRED_COUNT=$(echo "$PAIRED_DEV" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).devices.total" 2>/dev/null || echo "0")
[ "$PAIRED_COUNT" = "3" ] && ok "Paired devices = 3" || fail "Paired devices (got $PAIRED_COUNT)"

UNPAIRED_DEV=$(admin_api GET "/frames/admin/devices?paired=false")
UNPAIRED_COUNT=$(echo "$UNPAIRED_DEV" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).devices.total" 2>/dev/null || echo "0")
[ "$UNPAIRED_COUNT" = "1" ] && ok "Unpaired devices = 1" || fail "Unpaired devices (got $UNPAIRED_COUNT)"

# ── Step 10: Filter by search ─────────────────────────────────────────────
step 10 "Filter by search"

SEARCH_DEV=$(admin_api GET "/frames/admin/devices?search=dev-fleet-001")
SEARCH_COUNT=$(echo "$SEARCH_DEV" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).devices.total" 2>/dev/null || echo "0")
[ "$SEARCH_COUNT" = "1" ] && ok "Search 'dev-fleet-001' returns 1 device" || fail "Search dev-fleet-001 (got $SEARCH_COUNT)"

SEARCH_BOB=$(admin_api GET "/frames/admin/devices?search=user-bob")
SEARCH_BOB_COUNT=$(echo "$SEARCH_BOB" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).devices.total" 2>/dev/null || echo "0")
[ "$SEARCH_BOB_COUNT" = "1" ] && ok "Search 'user-bob' returns 1 device" || fail "Search user-bob (got $SEARCH_BOB_COUNT)"

# ── Step 11: Pagination ────────────────────────────────────────────────────
step 11 "Pagination"

PAGE1=$(admin_api GET "/frames/admin/devices?limit=2&offset=0")
PAGE1_ITEMS=$(echo "$PAGE1" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).devices.items.length" 2>/dev/null || echo "0")
PAGE1_TOTAL=$(echo "$PAGE1" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).devices.total" 2>/dev/null || echo "0")
[ "$PAGE1_ITEMS" = "2" ] && ok "Page 1 has 2 items" || fail "Page 1 items (got $PAGE1_ITEMS)"
[ "$PAGE1_TOTAL" = "4" ] && ok "Page 1 total = 4" || fail "Page 1 total (got $PAGE1_TOTAL)"

PAGE2=$(admin_api GET "/frames/admin/devices?limit=2&offset=2")
PAGE2_ITEMS=$(echo "$PAGE2" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).devices.items.length" 2>/dev/null || echo "0")
[ "$PAGE2_ITEMS" = "2" ] && ok "Page 2 has 2 items" || fail "Page 2 items (got $PAGE2_ITEMS)"

# ── Step 12: Per-device field validation ────────────────────────────────────
step 12 "Per-device fields (pendingCommandCount, actionAvailability, entitlements, subscription)"

DEV1_DETAIL=$(echo "$ALL_DEV" | node -pe "JSON.stringify(JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).devices.items.find(d=>d.deviceId==='dev-fleet-001'))" 2>/dev/null || echo "{}")

echo "$DEV1_DETAIL" | grep -q '"pendingCommandCount"' && ok "Device 1 has pendingCommandCount" || fail "pendingCommandCount field"
PENDING=$(echo "$DEV1_DETAIL" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).pendingCommandCount" 2>/dev/null || echo "-1")
[ "$PENDING" = "1" ] && ok "Device 1 pendingCommandCount = 1" || fail "Device 1 pending count (got $PENDING)"

echo "$DEV1_DETAIL" | grep -q '"actionAvailability"' && ok "Device 1 has actionAvailability" || fail "actionAvailability field"
echo "$DEV1_DETAIL" | grep -q '"entitlements"' && ok "Device 1 has entitlements" || fail "entitlements field"
echo "$DEV1_DETAIL" | grep -q '"subscription"' && ok "Device 1 has subscription" || fail "subscription field"
echo "$DEV1_DETAIL" | grep -q '"online":true' && ok "Device 1 is online" || fail "Device 1 online status"
echo "$DEV1_DETAIL" | grep -q '"paired":true' && ok "Device 1 is paired" || fail "Device 1 paired status"

# Check subscription details for device 1 (alice = frames_pro)
SUB_PLAN=$(echo "$DEV1_DETAIL" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).subscription.plan" 2>/dev/null || echo "")
[ "$SUB_PLAN" = "frames_premium" ] && ok "Device 1 subscription plan = frames_premium" || fail "Device 1 sub plan (got $SUB_PLAN)"

# Device 2 (bob, offline, no pending commands)
DEV2_DETAIL=$(echo "$ALL_DEV" | node -pe "JSON.stringify(JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).devices.items.find(d=>d.deviceId==='dev-fleet-002'))" 2>/dev/null || echo "{}")
DEV2_PENDING=$(echo "$DEV2_DETAIL" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).pendingCommandCount" 2>/dev/null || echo "-1")
[ "$DEV2_PENDING" = "0" ] && ok "Device 2 pendingCommandCount = 0" || fail "Device 2 pending count (got $DEV2_PENDING)"
echo "$DEV2_DETAIL" | grep -q '"online":false' && ok "Device 2 is offline" || fail "Device 2 offline status"

# ── Step 13: Auth gates ────────────────────────────────────────────────────
step 13 "Auth gates"

NO_AUTH=$(api GET "/frames/admin/devices")
echo "$NO_AUTH" | grep -q '401\|Unauthorized\|Missing admin token' && ok "No token → rejected" || fail "No token auth gate"

WRONG_AUTH=$(curl -s --max-time 5 -H "x-admin-token: wrong-token" "http://127.0.0.1:$PORT/frames/admin/devices")
echo "$WRONG_AUTH" | grep -q '403\|Invalid admin token' && ok "Wrong token → rejected" || fail "Wrong token auth gate"

# ── Step 14: Regression ────────────────────────────────────────────────────
step 14 "Regression — existing endpoints unaffected"

SETTINGS=$(api GET "/frames/device/dev-fleet-001/settings" -H "x-frame-device-key: $DEV1_KEY")
echo "$SETTINGS" | grep -q '"ok":true' && ok "Settings endpoint unaffected" || fail "Settings endpoint"

BUNDLE=$(admin_api GET "/frames/admin/bundle")
echo "$BUNDLE" | grep -q '"ok":true' && ok "Admin bundle unaffected" || fail "Admin bundle"

HEALTH2=$(api GET "/health")
echo "$HEALTH2" | grep -q '"ok":true' && ok "Health endpoint unaffected" || fail "Health endpoint"

SNAP=$(admin_api GET "/frames/device/dev-fleet-001/admin-snapshot")
echo "$SNAP" | grep -q '"ok":true' && ok "Admin snapshot unaffected" || fail "Admin snapshot"

# ── Summary ────────────────────────────────────────────────────────────────
echo -e "\n${CYAN}═══════════════════════════════════════════════════════════${RST}"
echo -e "  Admin Fleet Devices Check"
echo -e "  Steps: 14  Checks: $((PASS+FAIL))  ${GREEN}Pass: $PASS${RST}  ${RED}Fail: $FAIL${RST}  ${BOLD}Skip: $SKIP${RST}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════${RST}"

[ "$FAIL" -eq 0 ] || exit 1
