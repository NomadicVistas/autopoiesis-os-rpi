#!/usr/bin/env bash
# broadcast-delivery-ingestion-check.sh
# Isolated gate proving the full broadcast delivery round-trip:
# device sends broadcastDeliveries in heartbeat → mock API ingests and stores →
# admin endpoint queries aggregated delivery data.
# Also proves: upsert semantics (status transitions), multi-device isolation,
# per-broadcast detail, and empty-state handling.
set -euo pipefail

MOCK_PORT="${AUTOPOIESIS_BD_INGESTION_MOCK_PORT:-3149}"
UI_PORT="${AUTOPOIESIS_BD_INGESTION_UI_PORT:-3150}"
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MOCK_JS="$APP_DIR/scripts/mock-hosted-api/server.js"
SERVER_JS="$APP_DIR/local-ui/server.js"
MOCK_PID=""
UI_PID=""
TMPDIR_BASE=""

cleanup() {
  if [ -n "$UI_PID" ]; then kill "$UI_PID" 2>/dev/null || true; fi
  if [ -n "$MOCK_PID" ]; then kill "$MOCK_PID" 2>/dev/null || true; fi
  if [ -n "$TMPDIR_BASE" ] && [ -d "$TMPDIR_BASE" ]; then
    rm -rf "$TMPDIR_BASE"
  fi
}
trap cleanup EXIT

die() { echo "FAIL: $*" >&2; exit 1; }
step() { printf "\n=== Step %s ===\n" "$1"; }
jsval() { echo "$1" | python3 -c "import json,sys; print(json.load(sys.stdin)$2)"; }

wait_for_port() {
  local port="$1" max="${2:-30}"
  for i in $(seq 1 "$max"); do
    if curl -sf "http://127.0.0.1:$port/mock/state" >/dev/null 2>&1; then return 0; fi
    sleep 0.5
  done
  die "Port $port not responding after ${max}s"
}

# --- Step 1: Syntax validation ---
step 1
node --check "$MOCK_JS" || die "mock API syntax"
node --check "$SERVER_JS" || die "server.js syntax"
bash -n "$0" || die "self syntax"
echo "PASS: syntax validation"

# --- Step 2: Mock API function and route wiring ---
step 2
grep -q "function handleAdminBroadcastDeliveries" "$MOCK_JS" || die "handleAdminBroadcastDeliveries missing"
grep -q "function handleAdminBroadcastDeliveryDetail" "$MOCK_JS" || die "handleAdminBroadcastDeliveryDetail missing"
grep -q "broadcastDeliveries:" "$MOCK_JS" || die "broadcastDeliveries field missing in device record"
grep -q "deliveryAck" "$MOCK_JS" || die "deliveryAck missing from heartbeat response"
grep -q "/frames/admin/broadcast-deliveries" "$MOCK_JS" || die "admin broadcast-deliveries route missing"
echo "PASS: function and route wiring present"

# --- Step 3: Start mock API ---
step 3
MOCK_API_PORT="$MOCK_PORT" node "$MOCK_JS" &
MOCK_PID=$!
wait_for_port "$MOCK_PORT"
echo "PASS: mock API started on port $MOCK_PORT (PID $MOCK_PID)"

# --- Step 4: Register two devices ---
step 4
DEV_A=$(curl -sf -X POST "http://127.0.0.1:$MOCK_PORT/frames/device/register" \
  -H "content-type: application/json" \
  -d '{"deviceId":"bd-dev-a","deviceName":"Frame A","softwareVersion":"0.1.0"}') || die "register dev A"
DEV_A_KEY=$(echo "$DEV_A" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['device']['deviceApiKey'])")
DEV_A_ID=$(echo "$DEV_A" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['device']['deviceId'])")

DEV_B=$(curl -sf -X POST "http://127.0.0.1:$MOCK_PORT/frames/device/register" \
  -H "content-type: application/json" \
  -d '{"deviceId":"bd-dev-b","deviceName":"Frame B","softwareVersion":"0.1.0"}') || die "register dev B"
DEV_B_KEY=$(echo "$DEV_B" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['device']['deviceApiKey'])")
DEV_B_ID=$(echo "$DEV_B" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['device']['deviceId'])")

# Pair both devices with different owners
curl -sf -X POST "http://127.0.0.1:$MOCK_PORT/mock/pair-device/$DEV_A_ID" \
  -H "content-type: application/json" \
  -d "{\"ownerUserId\":\"owner_a\"}" >/dev/null || die "pair dev A"

curl -sf -X POST "http://127.0.0.1:$MOCK_PORT/mock/pair-device/$DEV_B_ID" \
  -H "content-type: application/json" \
  -d "{\"ownerUserId\":\"owner_b\"}" >/dev/null || die "pair dev B"

echo "PASS: two devices registered and paired ($DEV_A_ID, $DEV_B_ID)"

# --- Step 5: Device A sends heartbeat with broadcast deliveries ---
step 5
NOW_TS="2026-06-08T06:00:00Z"
HB_A=$(curl -sf -X POST "http://127.0.0.1:$MOCK_PORT/frames/device/$DEV_A_ID/heartbeat" \
  -H "content-type: application/json" \
  -H "x-frame-device-key: $DEV_A_KEY" \
  -d "{
    \"softwareVersion\": \"0.1.0\",
    \"broadcastDeliveries\": {
      \"broadcastCount\": 2,
      \"statusCounts\": {\"received\": 1, \"shown\": 1},
      \"deliveries\": [
        {\"broadcastId\": \"bcast-001\", \"status\": \"shown\", \"commandId\": \"cmd-001\", \"receivedAt\": \"$NOW_TS\", \"shownAt\": \"2026-06-08T06:00:05Z\", \"eventCount\": 2},
        {\"broadcastId\": \"bcast-002\", \"status\": \"received\", \"commandId\": \"cmd-002\", \"receivedAt\": \"2026-06-08T06:00:10Z\", \"eventCount\": 1}
      ]
    }
  }") || die "heartbeat with deliveries from dev A"

echo "$HB_A" | python3 -c "
import json,sys
d = json.load(sys.stdin)
assert d['ok'], f'heartbeat not ok: {d}'
ack = d.get('deliveryAck', {})
assert ack.get('accepted'), f'deliveryAck not accepted: {ack}'
assert ack.get('acceptedCount') == 2, f'expected 2 accepted, got {ack.get(\"acceptedCount\")}'
assert ack.get('totalDeliveries') == 2, f'expected 2 total, got {ack.get(\"totalDeliveries\")}'
print('OK: deliveryAck accepted 2 deliveries')
" || die "deliveryAck validation"
echo "PASS: device A heartbeat with 2 broadcast deliveries ingested"

# --- Step 6: Device B sends heartbeat with different broadcast ---
step 6
HB_B=$(curl -sf -X POST "http://127.0.0.1:$MOCK_PORT/frames/device/$DEV_B_ID/heartbeat" \
  -H "content-type: application/json" \
  -H "x-frame-device-key: $DEV_B_KEY" \
  -d "{
    \"softwareVersion\": \"0.1.0\",
    \"broadcastDeliveries\": {
      \"broadcastCount\": 1,
      \"statusCounts\": {\"shown\": 1},
      \"deliveries\": [
        {\"broadcastId\": \"bcast-001\", \"status\": \"shown\", \"commandId\": \"cmd-001\", \"receivedAt\": \"2026-06-08T06:00:00Z\", \"shownAt\": \"2026-06-08T06:00:03Z\", \"eventCount\": 2}
      ]
    }
  }") || die "heartbeat with deliveries from dev B"

echo "$HB_B" | python3 -c "
import json,sys
d = json.load(sys.stdin)
ack = d.get('deliveryAck', {})
assert ack.get('acceptedCount') == 1, f'expected 1 accepted, got {ack.get(\"acceptedCount\")}'
print('OK: deliveryAck accepted 1 delivery for dev B')
" || die "deliveryAck dev B validation"
echo "PASS: device B heartbeat with 1 broadcast delivery ingested"

# --- Step 7: Admin list all broadcast deliveries ---
step 7
ADMIN_LIST=$(curl -sf "http://127.0.0.1:$MOCK_PORT/frames/admin/broadcast-deliveries") || die "admin list deliveries"

echo "$ADMIN_LIST" | python3 -c "
import json,sys
d = json.load(sys.stdin)
assert d['ok']
assert d['totalDeliveries'] == 3, f'expected 3 total, got {d[\"totalDeliveries\"]}'
assert d['uniqueBroadcasts'] == 2, f'expected 2 unique broadcasts, got {d[\"uniqueBroadcasts\"]}'
assert d['uniqueDevices'] == 2, f'expected 2 unique devices, got {d[\"uniqueDevices\"]}'

# bcast-001 shown on both devices, bcast-002 received on dev A
sc = d['statusCounts']
assert sc.get('shown') == 2, f'expected 2 shown, got {sc.get(\"shown\")}'
assert sc.get('received') == 1, f'expected 1 received, got {sc.get(\"received\")}'

# Verify owner attribution
deliveries = d['deliveries']
dev_a_dels = [d for d in deliveries if d['deviceId'] == 'bd-dev-a']
dev_b_dels = [d for d in deliveries if d['deviceId'] == 'bd-dev-b']
assert len(dev_a_dels) == 2, f'expected 2 for dev A, got {len(dev_a_dels)}'
assert len(dev_b_dels) == 1, f'expected 1 for dev B, got {len(dev_b_dels)}'
assert dev_a_dels[0]['ownerUserId'] == 'owner_a', 'dev A owner mismatch'
assert dev_b_dels[0]['ownerUserId'] == 'owner_b', 'dev B owner mismatch'

print('OK: admin list verified 3 deliveries across 2 devices, 2 broadcasts')
" || die "admin list validation"
echo "PASS: admin list all broadcast deliveries"

# --- Step 8: Admin per-broadcast detail ---
step 8
BCAST_DETAIL=$(curl -sf "http://127.0.0.1:$MOCK_PORT/frames/admin/broadcast-deliveries/bcast-001") || die "broadcast detail"

echo "$BCAST_DETAIL" | python3 -c "
import json,sys
d = json.load(sys.stdin)
assert d['ok']
assert d['broadcastId'] == 'bcast-001'
assert d['totalDevices'] == 2, f'expected 2 devices for bcast-001, got {d[\"totalDevices\"]}'
assert d['statusCounts'].get('shown') == 2, f'expected 2 shown for bcast-001, got {d[\"statusCounts\"]}'

# Verify device names present
deliveries = d['deliveries']
names = [d['deviceName'] for d in deliveries]
assert 'Frame A' in names, 'Frame A missing from detail'
assert 'Frame B' in names, 'Frame B missing from detail'

print('OK: bcast-001 detail shows 2 devices')
" || die "broadcast detail validation"
echo "PASS: admin per-broadcast delivery detail"

# --- Step 9: Upsert — device A updates bcast-002 from received to dismissed ---
step 9
HB_A2=$(curl -sf -X POST "http://127.0.0.1:$MOCK_PORT/frames/device/$DEV_A_ID/heartbeat" \
  -H "content-type: application/json" \
  -H "x-frame-device-key: $DEV_A_KEY" \
  -d "{
    \"softwareVersion\": \"0.1.0\",
    \"broadcastDeliveries\": {
      \"broadcastCount\": 2,
      \"statusCounts\": {\"shown\": 1, \"dismissed\": 1},
      \"deliveries\": [
        {\"broadcastId\": \"bcast-001\", \"status\": \"shown\", \"commandId\": \"cmd-001\", \"receivedAt\": \"2026-06-08T06:00:00Z\", \"shownAt\": \"2026-06-08T06:00:05Z\", \"eventCount\": 2},
        {\"broadcastId\": \"bcast-002\", \"status\": \"dismissed\", \"commandId\": \"cmd-002\", \"receivedAt\": \"2026-06-08T06:00:10Z\", \"shownAt\": \"2026-06-08T06:00:15Z\", \"dismissedAt\": \"2026-06-08T06:00:20Z\", \"eventCount\": 3}
      ]
    }
  }") || die "heartbeat upsert from dev A"

echo "$HB_A2" | python3 -c "
import json,sys
d = json.load(sys.stdin)
ack = d.get('deliveryAck', {})
assert ack.get('acceptedCount') == 2, f'expected 2 upserted, got {ack.get(\"acceptedCount\")}'
assert ack.get('totalDeliveries') == 2, f'expected 2 total (no new), got {ack.get(\"totalDeliveries\")}'
print('OK: upsert accepted 2, total still 2 (no duplicates)')
" || die "upsert validation"

# Verify the upsert took effect in admin view
ADMIN_AFTER=$(curl -sf "http://127.0.0.1:$MOCK_PORT/frames/admin/broadcast-deliveries?deviceId=$DEV_A_ID") || die "admin list after upsert"

echo "$ADMIN_AFTER" | python3 -c "
import json,sys
d = json.load(sys.stdin)
assert d['totalDeliveries'] == 2, f'expected 2 for dev A after upsert, got {d[\"totalDeliveries\"]}'
# bcast-002 should now be dismissed
bcast002 = next((d2 for d2 in d['deliveries'] if d2['broadcastId'] == 'bcast-002'), None)
assert bcast002 is not None, 'bcast-002 not found after upsert'
assert bcast002['status'] == 'dismissed', f'expected dismissed, got {bcast002[\"status\"]}'
assert bcast002['dismissedAt'] is not None, 'dismissedAt missing after upsert'
assert bcast002['eventCount'] == 3, f'expected eventCount 3, got {bcast002[\"eventCount\"]}'
assert bcast002['updatedAt'] is not None, 'updatedAt missing'
print('OK: upsert reflected in admin view — bcast-002 now dismissed')
" || die "upsert admin view validation"
echo "PASS: upsert (bcast-002: received → dismissed)"

# --- Step 10: Admin filter by status ---
step 10
ADMIN_DISMISSED=$(curl -sf "http://127.0.0.1:$MOCK_PORT/frames/admin/broadcast-deliveries?status=dismissed") || die "admin filter dismissed"

echo "$ADMIN_DISMISSED" | python3 -c "
import json,sys
d = json.load(sys.stdin)
assert d['totalDeliveries'] == 1, f'expected 1 dismissed, got {d[\"totalDeliveries\"]}'
assert d['deliveries'][0]['broadcastId'] == 'bcast-002'
print('OK: status filter returned 1 dismissed delivery')
" || die "status filter validation"

ADMIN_SHOWN=$(curl -sf "http://127.0.0.1:$MOCK_PORT/frames/admin/broadcast-deliveries?status=shown") || die "admin filter shown"

echo "$ADMIN_SHOWN" | python3 -c "
import json,sys
d = json.load(sys.stdin)
assert d['totalDeliveries'] == 2, f'expected 2 shown, got {d[\"totalDeliveries\"]}'
print('OK: status filter returned 2 shown deliveries')
" || die "shown filter validation"
echo "PASS: admin filter by status"

# --- Step 11: Admin filter by owner ---
step 11
ADMIN_OWNER_A=$(curl -sf "http://127.0.0.1:$MOCK_PORT/frames/admin/broadcast-deliveries?ownerUserId=owner_a") || die "admin filter owner A"

echo "$ADMIN_OWNER_A" | python3 -c "
import json,sys
d = json.load(sys.stdin)
assert d['totalDeliveries'] == 2, f'expected 2 for owner A, got {d[\"totalDeliveries\"]}'
for d2 in d['deliveries']:
  assert d2['ownerUserId'] == 'owner_a', f'wrong owner: {d2[\"ownerUserId\"]}'
print('OK: owner filter returned 2 deliveries for owner_a')
" || die "owner filter validation"

ADMIN_OWNER_B=$(curl -sf "http://127.0.0.1:$MOCK_PORT/frames/admin/broadcast-deliveries?ownerUserId=owner_b") || die "admin filter owner B"

echo "$ADMIN_OWNER_B" | python3 -c "
import json,sys
d = json.load(sys.stdin)
assert d['totalDeliveries'] == 1, f'expected 1 for owner B, got {d[\"totalDeliveries\"]}'
print('OK: owner filter returned 1 delivery for owner_b')
" || die "owner B filter validation"
echo "PASS: admin filter by owner"

# --- Step 12: Empty state — no deliveries ---
step 12
DEV_C=$(curl -sf -X POST "http://127.0.0.1:$MOCK_PORT/frames/device/register" \
  -H "content-type: application/json" \
  -d '{"deviceId":"bd-dev-c","deviceName":"Frame C"}') || die "register dev C"
DEV_C_ID=$(echo "$DEV_C" | python3 -c "import json,sys; print(json.load(sys.stdin)['device']['deviceId'])")
curl -sf -X POST "http://127.0.0.1:$MOCK_PORT/mock/pair-device/$DEV_C_ID" \
  -H "content-type: application/json" \
  -d '{"ownerUserId":"owner_c"}' >/dev/null || die "pair dev C"

# Send heartbeat without broadcastDeliveries
curl -sf -X POST "http://127.0.0.1:$MOCK_PORT/frames/device/$DEV_C_ID/heartbeat" \
  -H "content-type: application/json" \
  -H "x-frame-device-key: $(echo "$DEV_C" | python3 -c "import json,sys; print(json.load(sys.stdin)['device']['deviceApiKey'])")" \
  -d '{"softwareVersion":"0.1.0"}' >/dev/null || die "heartbeat dev C"

ADMIN_EMPTY=$(curl -sf "http://127.0.0.1:$MOCK_PORT/frames/admin/broadcast-deliveries?deviceId=$DEV_C_ID") || die "admin filter dev C"

echo "$ADMIN_EMPTY" | python3 -c "
import json,sys
d = json.load(sys.stdin)
assert d['totalDeliveries'] == 0, f'expected 0 for dev C, got {d[\"totalDeliveries\"]}'
assert len(d['deliveries']) == 0
print('OK: device with no broadcast deliveries returns empty')
" || die "empty state validation"
echo "PASS: empty state for device with no deliveries"

# --- Step 13: Schema field mapping to aos_broadcast_deliveries ---
step 13
ADMIN_FULL=$(curl -sf "http://127.0.0.1:$MOCK_PORT/frames/admin/broadcast-deliveries") || die "admin full list"

echo "$ADMIN_FULL" | python3 -c "
import json,sys
d = json.load(sys.stdin)
# Pick bcast-001 on dev A — should be shown
bcast001a = next((d2 for d2 in d['deliveries'] if d2['broadcastId'] == 'bcast-001' and d2['deviceId'] == 'bd-dev-a'), None)
assert bcast001a is not None, 'bcast-001/dev-a not found'
assert bcast001a['broadcastId'] == 'bcast-001', 'broadcastId'
assert bcast001a['deviceId'] == 'bd-dev-a', 'deviceId'
assert bcast001a['commandId'] == 'cmd-001', 'commandId'
assert bcast001a['status'] == 'shown', f'status: {bcast001a[\"status\"]}'
assert bcast001a['receivedAt'] is not None, 'receivedAt'
assert bcast001a['shownAt'] is not None, 'shownAt'
assert bcast001a['dismissedAt'] is None, 'dismissedAt should be None'
assert bcast001a['expiredAt'] is None, 'expiredAt should be None'
assert bcast001a['skippedAt'] is None, 'skippedAt should be None'
assert bcast001a['eventCount'] == 2, f'eventCount: {bcast001a[\"eventCount\"]}'
assert bcast001a['createdAt'] is not None, 'createdAt'
assert bcast001a['updatedAt'] is not None, 'updatedAt'
assert bcast001a['ownerUserId'] == 'owner_a', 'ownerUserId'
print('OK: aos_broadcast_deliveries field mapping verified')
" || die "schema field mapping validation"
echo "PASS: hosted schema field mapping (aos_broadcast_deliveries compatible)"

# --- Step 14: heartbeat response does not include deliveryAck when no deliveries ---
step 14
HB_NO_DELIVERY=$(curl -sf -X POST "http://127.0.0.1:$MOCK_PORT/frames/device/$DEV_C_ID/heartbeat" \
  -H "content-type: application/json" \
  -H "x-frame-device-key: $(echo "$DEV_C" | python3 -c "import json,sys; print(json.load(sys.stdin)['device']['deviceApiKey'])")" \
  -d '{"softwareVersion":"0.1.0"}') || die "heartbeat no deliveries"

echo "$HB_NO_DELIVERY" | python3 -c "
import json,sys
d = json.load(sys.stdin)
assert d['ok']
ack = d.get('deliveryAck')
assert ack is None, f'expected no deliveryAck, got {ack}'
print('OK: no deliveryAck when no broadcastDeliveries in body')
" || die "no deliveryAck validation"
echo "PASS: deliveryAck absent when no deliveries in heartbeat"

printf "\n========================================\n"
echo "ALL 14 STEPS PASSED"
echo "========================================"
