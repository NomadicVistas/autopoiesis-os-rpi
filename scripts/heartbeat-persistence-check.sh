#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# heartbeat-persistence-check.sh
#
# Validates that the hosted API actually persists events and broadcast
# deliveries to the database through the heartbeat endpoint.
#
# Previously, handleHeartbeat stripped events/broadcastDeliveries from the
# payload before calling db.ingestHeartbeat, then built fake acks — the data
# was acknowledged but never written.  This gate proves the fix works.
#
# Steps:
#   1. Syntax validation
#   2. Static contract: heartbeatPayload includes events + broadcastDeliveries
#   3. Database bootstrap
#   4. Hosted API server startup
#   5. Device registration + pairing
#   6. Heartbeat with events — proves events land in aos_device_events
#   7. Heartbeat with broadcast deliveries — proves deliveries land in
#      aos_broadcast_deliveries
#   8. Upsert semantics — second heartbeat updates existing events/deliveries
#   9. Admin delivery endpoint returns persisted data
#  10. Full lifecycle: register → pair → heartbeat(events+deliveries) → query
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0
STEP=0

p() { PASS=$((PASS+1)); }
f() { FAIL=$((FAIL+1)); echo "  ✗ FAIL: $1"; }

step() { STEP=$((STEP+1)); echo ""; echo "Step $STEP: $1"; }

# ── Step 1: Syntax ────────────────────────────────────────────────────────
step "Syntax validation"
node --check "$BASE_DIR/hosted-api/server.js" 2>/dev/null && p || f "server.js syntax"
node --check "$BASE_DIR/hosted-api/db.js" 2>/dev/null && p || f "db.js syntax"
bash -n "$0" 2>/dev/null && p || f "self syntax"

echo "  $PASS passed, $FAIL failed"

# ── Step 2: Static contract ──────────────────────────────────────────────
step "Static contract — heartbeatPayload includes events + broadcastDeliveries"

SERVER="$BASE_DIR/hosted-api/server.js"

# Verify the heartbeatPayload object includes events and broadcastDeliveries
if grep -q 'events: body.events || null' "$SERVER"; then p; else f "heartbeatPayload missing events"; fi
if grep -q 'broadcastDeliveries: body.broadcastDeliveries || null' "$SERVER"; then p; else f "heartbeatPayload missing broadcastDeliveries"; fi

# Verify handleHeartbeat uses hbResult.eventAck and hbResult.deliveryAck
if grep -q 'hbResult.eventAck' "$SERVER"; then p; else f "not using hbResult.eventAck"; fi
if grep -q 'hbResult.deliveryAck' "$SERVER"; then p; else f "not using hbResult.deliveryAck"; fi

# Verify the fake ack blocks (acceptedCount++ loop) are gone
if ! grep -q 'acceptedCount++' "$SERVER"; then p; else f "fake ack loop still present"; fi

echo "  $PASS passed, $FAIL failed"

# ── Step 3: Database bootstrap ────────────────────────────────────────────
step "Database bootstrap"

DB_PATH="$TMPDIR/aos.db"
node -e "
const AosDb = require('$BASE_DIR/hosted-api/db');
const fs = require('fs');
const path = require('path');

// Run the schema
const schema = fs.readFileSync('$BASE_DIR/scripts/aos-schema-sqlite-validation.sql', 'utf-8');
const db = new AosDb('$DB_PATH');
for (const stmt of schema.split(';').map(s => s.trim()).filter(s => s.length > 0)) {
  db.db.prepare(stmt).run();
}
const tables = db.listTables();
if (tables.length >= 14) {
  console.log('OK: ' + tables.length + ' tables');
  db.close();
  process.exit(0);
} else {
  console.error('FAIL: only ' + tables.length + ' tables');
  db.close();
  process.exit(1);
}
" 2>&1 | tail -1

if [ $? -eq 0 ]; then p; else f "database bootstrap"; fi

echo "  $PASS passed, $FAIL failed"

# ── Step 4: Hosted API server startup ─────────────────────────────────────
step "Hosted API server startup"

AOS_DB="$DB_PATH" AOS_PORT=3199 timeout 30 node "$BASE_DIR/hosted-api/server.js" > "$TMPDIR/api.log" 2>&1 &
API_PID=$!
sleep 2

if kill -0 "$API_PID" 2>/dev/null; then
  # Check health
  HEALTH=$(curl -sf http://127.0.0.1:3199/health 2>/dev/null || echo '{"ok":false}')
  echo "$HEALTH" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('ok') else 1)" 2>/dev/null && p || f "health check"
else
  f "server did not start"
  cat "$TMPDIR/api.log"
fi

echo "  $PASS passed, $FAIL failed"

# ── Step 5: Device registration + pairing ─────────────────────────────────
step "Device registration + pairing"

REG=$(curl -sf -X POST http://127.0.0.1:3199/frames/device/register \
  -H "content-type: application/json" \
  -d '{"deviceId":"hp_test_001","softwareVersion":"0.2.0"}' 2>/dev/null || echo '{"ok":false}')

DEVICE_ID=$(echo "$REG" | python3 -c "import sys,json; print(json.load(sys.stdin)['device']['deviceId'])" 2>/dev/null)
DEVICE_KEY=$(echo "$REG" | python3 -c "import sys,json; print(json.load(sys.stdin)['device']['deviceApiKey'])" 2>/dev/null)
PAIRING_CODE=$(echo "$REG" | python3 -c "import sys,json; print(json.load(sys.stdin)['pairingCode'])" 2>/dev/null)

[ -n "$DEVICE_ID" ] && p || f "deviceId missing"
[ -n "$DEVICE_KEY" ] && p || f "deviceApiKey missing"
[ -n "$PAIRING_CODE" ] && p || f "pairingCode missing"

# Claim the pairing code directly via DB
node -e "
const AosDb = require('$BASE_DIR/hosted-api/db');
const db = new AosDb('$DB_PATH');
const result = db.claimPairingCode('$PAIRING_CODE', 'user_hp_001');
console.log(JSON.stringify(result));
db.close();
" > "$TMPDIR/claim.json" 2>/dev/null

CLAIM_OK=$(python3 -c "import json; print(json.load(open('$TMPDIR/claim.json')).get('ok', False))" 2>/dev/null)
[ "$CLAIM_OK" = "True" ] && p || f "pairing claim failed"

echo "  $PASS passed, $FAIL failed"

# ── Step 6: Heartbeat with events ────────────────────────────────────────
step "Heartbeat with events — persistence proof"

HB1=$(curl -sf -X POST "http://127.0.0.1:3199/frames/device/$DEVICE_ID/heartbeat" \
  -H "content-type: application/json" \
  -H "x-frame-device-key: $DEVICE_KEY" \
  -d '{
    "softwareVersion": "0.2.0",
    "currentMode": "kiosk",
    "events": [
      {"eventKey": "artwork_displayed_001", "eventType": "artwork_displayed", "observedAt": "2026-06-08T16:00:00Z", "artworkId": "art_abc123"},
      {"eventKey": "artwork_liked_002", "eventType": "artwork_liked", "observedAt": "2026-06-08T16:01:00Z", "artworkId": "art_def456"}
    ]
  }' 2>/dev/null || echo '{"ok":false}')

# Verify response shape
echo "$HB1" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('ok'), 'heartbeat not ok'; assert d.get('eventAck'), 'no eventAck'; assert d['eventAck'].get('accepted'), 'eventAck not accepted'; assert d['eventAck'].get('acceptedCount') == 2, 'wrong count: ' + str(d['eventAck'].get('acceptedCount')); print('OK')" 2>&1 | grep -q OK && p || f "heartbeat eventAck shape"

# Verify events were actually persisted in the database
EVENT_COUNT=$(node -e "
const AosDb = require('$BASE_DIR/hosted-api/db');
const db = new AosDb('$DB_PATH', { readonly: true });
const row = db.db.prepare(\"SELECT count(*) as cnt FROM aos_device_events WHERE device_id = '$DEVICE_ID'\").get();
console.log(row.cnt);
db.close();
" 2>/dev/null)

[ "$EVENT_COUNT" = "2" ] && p || f "expected 2 events in DB, got $EVENT_COUNT"

# Verify event content
EVT1=$(node -e "
const AosDb = require('$BASE_DIR/hosted-api/db');
const db = new AosDb('$DB_PATH', { readonly: true });
const row = db.db.prepare(\"SELECT event_type, status FROM aos_device_events WHERE device_id = '$DEVICE_ID' AND event_key = 'artwork_displayed_001'\").get();
console.log(row ? row.event_type + '|' + row.status : 'NOT_FOUND');
db.close();
" 2>/dev/null)

[ "$EVT1" = "artwork_displayed|observed" ] && p || f "event 1 content wrong: $EVT1"

EVT2=$(node -e "
const AosDb = require('$BASE_DIR/hosted-api/db');
const db = new AosDb('$DB_PATH', { readonly: true });
const row = db.db.prepare(\"SELECT event_type, status FROM aos_device_events WHERE device_id = '$DEVICE_ID' AND event_key = 'artwork_liked_002'\").get();
console.log(row ? row.event_type + '|' + row.status : 'NOT_FOUND');
db.close();
" 2>/dev/null)

[ "$EVT2" = "artwork_liked|observed" ] && p || f "event 2 content wrong: $EVT2"

echo "  $PASS passed, $FAIL failed"

# ── Step 7: Heartbeat with broadcast deliveries ──────────────────────────
step "Heartbeat with broadcast deliveries — persistence proof"

# First create a broadcast to deliver
BC_CREATE=$(curl -sf -X POST http://127.0.0.1:3199/frames/admin/broadcasts \
  -H "content-type: application/json" \
  -d '{
    "title": "Test Broadcast for Delivery Persistence",
    "type": "system_notice",
    "priority": "high",
    "status": "published",
    "body": "Testing delivery persistence through heartbeat"
  }' 2>/dev/null || echo '{"ok":false}')

BC_ID=$(echo "$BC_CREATE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('broadcast',{}).get('id',''))" 2>/dev/null)
[ -n "$BC_ID" ] && p || f "broadcast creation failed"

HB2=$(curl -sf -X POST "http://127.0.0.1:3199/frames/device/$DEVICE_ID/heartbeat" \
  -H "content-type: application/json" \
  -H "x-frame-device-key: $DEVICE_KEY" \
  -d "{
    \"softwareVersion\": \"0.2.0\",
    \"currentMode\": \"kiosk\",
    \"broadcastDeliveries\": {
      \"deliveries\": [
        {
          \"broadcastId\": \"$BC_ID\",
          \"status\": \"received\",
          \"receivedAt\": \"2026-06-08T16:05:00Z\"
        }
      ]
    }
  }" 2>/dev/null || echo '{"ok":false}')

# Verify response shape
echo "$HB2" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('ok'), 'heartbeat not ok'; assert d.get('deliveryAck'), 'no deliveryAck'; assert d['deliveryAck'].get('accepted'), 'deliveryAck not accepted'; assert d['deliveryAck'].get('acceptedCount') == 1, 'wrong count'; print('OK')" 2>&1 | grep -q OK && p || f "heartbeat deliveryAck shape"

# Verify delivery was actually persisted
DEL_COUNT=$(node -e "
const AosDb = require('$BASE_DIR/hosted-api/db');
const db = new AosDb('$DB_PATH', { readonly: true });
const row = db.db.prepare(\"SELECT count(*) as cnt FROM aos_broadcast_deliveries WHERE device_id = '$DEVICE_ID'\").get();
console.log(row.cnt);
db.close();
" 2>/dev/null)

[ "$DEL_COUNT" = "1" ] && p || f "expected 1 delivery in DB, got $DEL_COUNT"

# Verify delivery content
DEL_STATUS=$(node -e "
const AosDb = require('$BASE_DIR/hosted-api/db');
const db = new AosDb('$DB_PATH', { readonly: true });
const row = db.db.prepare(\"SELECT status, broadcast_id FROM aos_broadcast_deliveries WHERE device_id = '$DEVICE_ID' AND broadcast_id = '$BC_ID'\").get();
console.log(row ? row.status + '|' + row.broadcast_id : 'NOT_FOUND');
db.close();
" 2>/dev/null)

[ "$DEL_STATUS" = "received|$BC_ID" ] && p || f "delivery content wrong: $DEL_STATUS"

echo "  $PASS passed, $FAIL failed"

# ── Step 8: Upsert semantics ──────────────────────────────────────────────
step "Upsert semantics — second heartbeat updates existing records"

HB3=$(curl -sf -X POST "http://127.0.0.1:3199/frames/device/$DEVICE_ID/heartbeat" \
  -H "content-type: application/json" \
  -H "x-frame-device-key: $DEVICE_KEY" \
  -d "{
    \"softwareVersion\": \"0.2.0\",
    \"currentMode\": \"kiosk\",
    \"events\": [
      {\"eventKey\": \"artwork_displayed_001\", \"eventType\": \"artwork_displayed\", \"observedAt\": \"2026-06-08T16:10:00Z\", \"status\": \"confirmed\", \"artworkId\": \"art_abc123\"}
    ],
    \"broadcastDeliveries\": {
      \"deliveries\": [
        {
          \"broadcastId\": \"$BC_ID\",
          \"status\": \"displayed\",
          \"receivedAt\": \"2026-06-08T16:05:00Z\",
          \"displayedAt\": \"2026-06-08T16:10:00Z\"
        }
      ]
    }
  }" 2>/dev/null || echo '{"ok":false}')

# Verify event was updated (not duplicated)
EVENT_COUNT_AFTER=$(node -e "
const AosDb = require('$BASE_DIR/hosted-api/db');
const db = new AosDb('$DB_PATH', { readonly: true });
const row = db.db.prepare(\"SELECT count(*) as cnt FROM aos_device_events WHERE device_id = '$DEVICE_ID'\").get();
console.log(row.cnt);
db.close();
" 2>/dev/null)

[ "$EVENT_COUNT_AFTER" = "2" ] && p || f "expected 2 events after upsert (not 3), got $EVENT_COUNT_AFTER"

# Verify event status was updated
EVT1_UPDATED=$(node -e "
const AosDb = require('$BASE_DIR/hosted-api/db');
const db = new AosDb('$DB_PATH', { readonly: true });
const row = db.db.prepare(\"SELECT status FROM aos_device_events WHERE device_id = '$DEVICE_ID' AND event_key = 'artwork_displayed_001'\").get();
console.log(row ? row.status : 'NOT_FOUND');
db.close();
" 2>/dev/null)

[ "$EVT1_UPDATED" = "confirmed" ] && p || f "event upsert status wrong: $EVT1_UPDATED (expected confirmed)"

# Verify delivery was updated (not duplicated)
DEL_COUNT_AFTER=$(node -e "
const AosDb = require('$BASE_DIR/hosted-api/db');
const db = new AosDb('$DB_PATH', { readonly: true });
const row = db.db.prepare(\"SELECT count(*) as cnt FROM aos_broadcast_deliveries WHERE device_id = '$DEVICE_ID'\").get();
console.log(row.cnt);
db.close();
" 2>/dev/null)

[ "$DEL_COUNT_AFTER" = "1" ] && p || f "expected 1 delivery after upsert (not 2), got $DEL_COUNT_AFTER"

# Verify delivery status was updated
DEL_UPDATED=$(node -e "
const AosDb = require('$BASE_DIR/hosted-api/db');
const db = new AosDb('$DB_PATH', { readonly: true });
const row = db.db.prepare(\"SELECT status FROM aos_broadcast_deliveries WHERE device_id = '$DEVICE_ID' AND broadcast_id = '$BC_ID'\").get();
console.log(row ? row.status : 'NOT_FOUND');
db.close();
" 2>/dev/null)

[ "$DEL_UPDATED" = "displayed" ] && p || f "delivery upsert status wrong: $DEL_UPDATED (expected displayed)"

echo "  $PASS passed, $FAIL failed"

# ── Step 9: Admin delivery endpoint returns persisted data ────────────────
step "Admin delivery endpoint returns persisted data"

ADMIN_DEL=$(curl -sf "http://127.0.0.1:3199/frames/admin/broadcast-deliveries" 2>/dev/null || echo '{"ok":false}')

echo "$ADMIN_DEL" | python3 -c "
import sys,json
d = json.load(sys.stdin)
assert d.get('ok'), 'not ok: ' + str(d)
assert d.get('total', 0) >= 1, 'total should be >= 1, got: ' + str(d.get('total'))
# Find the delivery for our device
found = False
for delivery in d.get('deliveries', []):
    if delivery.get('device_id') == '$DEVICE_ID' or delivery.get('deviceId') == '$DEVICE_ID':
        assert delivery.get('status') == 'displayed', 'wrong status: ' + str(delivery.get('status'))
        found = True
assert found, 'delivery not found in admin list'
print('OK')
" 2>&1 | grep -q OK && p || f "admin delivery list"

# Per-broadcast detail
BC_DETAIL=$(curl -sf "http://127.0.0.1:3199/frames/admin/broadcast-deliveries/$BC_ID" 2>/dev/null || echo '{"ok":false}')

echo "$BC_DETAIL" | python3 -c "
import sys,json
d = json.load(sys.stdin)
assert d.get('ok'), 'not ok'
assert d.get('total', 0) >= 1, 'detail total should be >= 1'
print('OK')
" 2>&1 | grep -q OK && p || f "admin broadcast detail"

echo "  $PASS passed, $FAIL failed"

# ── Step 10: Full lifecycle — heartbeat with both events and deliveries ───
step "Full lifecycle — combined events + deliveries in single heartbeat"

HB4=$(curl -sf -X POST "http://127.0.0.1:3199/frames/device/$DEVICE_ID/heartbeat" \
  -H "content-type: application/json" \
  -H "x-frame-device-key: $DEVICE_KEY" \
  -d "{
    \"softwareVersion\": \"0.2.0\",
    \"currentMode\": \"kiosk\",
    \"events\": [
      {\"eventKey\": \"feed_sync_003\", \"eventType\": \"feed_synced\", \"observedAt\": \"2026-06-08T16:15:00Z\"},
      {\"eventKey\": \"cache_prune_004\", \"eventType\": \"cache_pruned\", \"observedAt\": \"2026-06-08T16:15:01Z\"},
      {\"eventKey\": \"artwork_displayed_001\", \"eventType\": \"artwork_displayed\", \"observedAt\": \"2026-06-08T16:16:00Z\", \"status\": \"completed\"}
    ],
    \"broadcastDeliveries\": {
      \"deliveries\": [
        {
          \"broadcastId\": \"$BC_ID\",
          \"status\": \"dismissed\",
          \"receivedAt\": \"2026-06-08T16:05:00Z\",
          \"displayedAt\": \"2026-06-08T16:10:00Z\",
          \"dismissedAt\": \"2026-06-08T16:17:00Z\"
        }
      ]
    }
  }" 2>/dev/null || echo '{"ok":false}')

# Verify response has both acks
echo "$HB4" | python3 -c "
import sys,json
d = json.load(sys.stdin)
assert d.get('ok'), 'not ok'
assert d.get('eventAck'), 'missing eventAck'
assert d.get('deliveryAck'), 'missing deliveryAck'
assert d['eventAck'].get('acceptedCount') == 3, 'wrong event count: ' + str(d['eventAck'].get('acceptedCount'))
assert d['deliveryAck'].get('acceptedCount') == 1, 'wrong delivery count'
print('OK')
" 2>&1 | grep -q OK && p || f "combined heartbeat response"

# Verify final counts
FINAL_EVENTS=$(node -e "
const AosDb = require('$BASE_DIR/hosted-api/db');
const db = new AosDb('$DB_PATH', { readonly: true });
const row = db.db.prepare(\"SELECT count(*) as cnt FROM aos_device_events WHERE device_id = '$DEVICE_ID'\").get();
console.log(row.cnt);
db.close();
" 2>/dev/null)

# 4 total unique event_keys: artwork_displayed_001, artwork_liked_002, feed_sync_003, cache_prune_004
[ "$FINAL_EVENTS" = "4" ] && p || f "expected 4 unique events, got $FINAL_EVENTS"

FINAL_DELIVERIES=$(node -e "
const AosDb = require('$BASE_DIR/hosted-api/db');
const db = new AosDb('$DB_PATH', { readonly: true });
const row = db.db.prepare(\"SELECT count(*) as cnt FROM aos_broadcast_deliveries WHERE device_id = '$DEVICE_ID'\").get();
console.log(row.cnt);
db.close();
" 2>/dev/null)

[ "$FINAL_DELIVERIES" = "1" ] && p || f "expected 1 delivery (upserted 3 times), got $FINAL_DELIVERIES"

# Verify final event status (artwork_displayed_001 should be 'completed' after 3 upserts)
FINAL_EVT_STATUS=$(node -e "
const AosDb = require('$BASE_DIR/hosted-api/db');
const db = new AosDb('$DB_PATH', { readonly: true });
const row = db.db.prepare(\"SELECT status FROM aos_device_events WHERE device_id = '$DEVICE_ID' AND event_key = 'artwork_displayed_001'\").get();
console.log(row ? row.status : 'NOT_FOUND');
db.close();
" 2>/dev/null)

[ "$FINAL_EVT_STATUS" = "completed" ] && p || f "final event status wrong: $FINAL_EVT_STATUS (expected completed)"

# Verify final delivery status
FINAL_DEL_STATUS=$(node -e "
const AosDb = require('$BASE_DIR/hosted-api/db');
const db = new AosDb('$DB_PATH', { readonly: true });
const row = db.db.prepare(\"SELECT status FROM aos_broadcast_deliveries WHERE device_id = '$DEVICE_ID' AND broadcast_id = '$BC_ID'\").get();
console.log(row ? row.status : 'NOT_FOUND');
db.close();
" 2>/dev/null)

[ "$FINAL_DEL_STATUS" = "dismissed" ] && p || f "final delivery status wrong: $FINAL_DEL_STATUS (expected dismissed)"

echo "  $PASS passed, $FAIL failed"

# ── Cleanup ────────────────────────────────────────────────────────────────
kill "$API_PID" 2>/dev/null || true
wait "$API_PID" 2>/dev/null || true

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Heartbeat Persistence Gate: $PASS passed, $FAIL failed ($STEP steps)"
echo "══════════════════════════════════════════════════════════════"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
