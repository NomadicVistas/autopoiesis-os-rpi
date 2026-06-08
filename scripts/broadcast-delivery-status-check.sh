#!/usr/bin/env bash
# broadcast-delivery-status-check.sh
# Isolated gate proving broadcast delivery receipt tracking and delivery status summary.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVER="$REPO_DIR/local-ui/server.js"
MOCK_API="$REPO_DIR/scripts/mock-hosted-api/server.js"
TMP=$(mktemp -d)

# Pick random ports
pick_port() {
  node - <<'NODE'
const net = require("net");
const server = net.createServer();
server.listen(0, "127.0.0.1", () => {
  console.log(server.address().port);
  server.close();
});
NODE
}

PORT="${AUTOPOIESIS_BROADCAST_DELIVERY_STATUS_PORT:-$(pick_port)}"
MOCK_PORT="${AUTOPOIESIS_BROADCAST_DELIVERY_STATUS_API_PORT:-$(pick_port)}"
MOCK_URL="http://127.0.0.1:$MOCK_PORT"
BASE="http://127.0.0.1:$PORT"
SERVER_PID=""
MOCK_PID=""

cleanup() {
  [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

die() {
  echo "FAIL: $*" >&2
  [ -f "$TMP/server.log" ] && { echo "--- server log ---" >&2; sed -n '1,80p' "$TMP/server.log" >&2; }
  [ -f "$TMP/api.log" ] && { echo "--- api log ---" >&2; sed -n '1,80p' "$TMP/api.log" >&2; }
  exit 1
}

# ──── Step 1: Syntax validation ────
node --check "$SERVER" || die "server syntax"
bash -n "$0" || die "self syntax"
echo "step 1 passed: syntax validation"

# ──── Start mock hosted API ────
node "$MOCK_API" --port "$MOCK_PORT" > "$TMP/api.log" 2>&1 &
MOCK_PID=$!
for i in $(seq 1 30); do
  curl -sf "$MOCK_URL/mock/state" > /dev/null 2>&1 && break
  sleep 0.2
done
curl -sf "$MOCK_URL/mock/state" > /dev/null || die "mock API not reachable on port $MOCK_PORT"

# ──── Start local UI ────
mkdir -p "$TMP/data" "$TMP/logs"
AUTOPOIESIS_API_BASE_URL="$MOCK_URL" \
AUTOPOIESIS_DATA_DIR="$TMP/data" \
AUTOPOIESIS_LOG_DIR="$TMP/logs" \
AUTOPOIESIS_PORT="$PORT" \
node "$SERVER" > "$TMP/server.log" 2>&1 &
SERVER_PID=$!
for i in $(seq 1 30); do
  curl -sf "$BASE/local/health" > /dev/null 2>&1 && break
  sleep 0.2
done
curl -sf "$BASE/local/health" > /dev/null || die "local UI not reachable on port $PORT"

# ──── Step 2: Register device ────
REG=$(curl -sf -X POST "$BASE/local/pairing/start")
PAIRING_CODE=$(echo "$REG" | python3 -c "import sys,json; print(json.load(sys.stdin).get('pairingCode',''))") || die "no pairing code in response: $REG"
[ -n "$PAIRING_CODE" ] || die "empty pairing code"

# Get device ID from pairing status
PAIR_STATUS=$(curl -sf "$BASE/local/pairing/status")
DEVICE_ID=$(echo "$PAIR_STATUS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('device',{}).get('deviceId',''))") || die "no deviceId"
[ -n "$DEVICE_ID" ] || die "empty deviceId"
echo "step 2 passed: device registered with pairing code"

# ──── Step 3: Pair device via mock API ────
curl -sf -X POST "$MOCK_URL/mock/pair-device/$DEVICE_ID" \
  -H "Content-Type: application/json" \
  -d "{\"pairingCode\":\"$PAIRING_CODE\",\"ownerUserId\":\"user_delivery_test\"}" > /dev/null || die "mock pair failed"

sleep 0.3
CHECK=$(curl -sf -X POST "$BASE/local/pairing/check")
echo "$CHECK" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('paired',False), f'not paired: {d}'" || die "pairing check failed"
echo "step 3 passed: device paired"

# ──── Step 4: Queue and process broadcast command ────
BROADCAST_ID="broadcast-delivery-test-$(date +%s)"
EXPIRES=$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)
curl -sf -X POST "$MOCK_URL/mock/queue-command/$DEVICE_ID" \
  -H "Content-Type: application/json" \
  -d "{
    \"type\": \"show_broadcast\",
    \"broadcastId\": \"$BROADCAST_ID\",
    \"title\": \"Delivery Status Test Broadcast\",
    \"body\": \"Testing broadcast delivery receipt tracking\",
    \"priority\": \"high\",
    \"expiresAt\": \"$EXPIRES\",
    \"authorization\": {
      \"approved\": true,
      \"actorId\": \"admin-delivery-test\",
      \"actorRole\": \"admin\",
      \"authorizedAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
    }
  }" > /dev/null || die "queue broadcast command"

# Send heartbeat to pull commands from mock API into local state
curl -sf -X POST "$BASE/local/heartbeat" > /dev/null || true
sleep 0.3

# Rewrite commands.json as flat array (mock API stores { items: [...] }, local UI expects array)
node - "$TMP/data/commands.json" <<'NODE'
const fs = require("fs");
const f = process.argv[2];
try {
  const data = JSON.parse(fs.readFileSync(f, "utf8"));
  const items = Array.isArray(data) ? data : (data.items || []);
  fs.writeFileSync(f, JSON.stringify(items, null, 2));
} catch (e) { /* no commands file yet */ }
NODE

CMD_RESULT=$(curl -sf -X POST "$BASE/local/commands/process")
echo "$CMD_RESULT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d.get('ok'), f'command process failed: {d}'
results = d.get('results', [])
assert len(results) > 0, f'no results: {d}'
r = results[0].get('result', results[0])
assert r.get('ok'), f'broadcast command failed: {results[0]}'
bid = r.get('broadcastId', '')
assert bid == '$BROADCAST_ID', f'wrong broadcast id: {bid}'
" || die "broadcast command processing"
echo "step 4 passed: broadcast command received and accepted"

# ──── Step 5: Delivery log contains broadcast_received event ────
DELIVERY_LOG=$(curl -sf "$BASE/local/delivery-log?limit=50")
echo "$DELIVERY_LOG" | python3 -c "
import sys, json
d = json.load(sys.stdin)
entries = d.get('entries', [])
received = [e for e in entries if e.get('eventType') == 'broadcast_received' and e.get('itemId') == '$BROADCAST_ID']
assert len(received) >= 1, f'no broadcast_received event for $BROADCAST_ID in {len(entries)} entries, types: {[e.get(\"eventType\") for e in entries]}'
r = received[0]
assert r.get('source') == 'broadcast', f'wrong source: {r.get(\"source\")}'
assert r.get('priority') == 'high', f'wrong priority: {r.get(\"priority\")}'
assert r.get('status') in ('active', 'received'), f'wrong status: {r.get(\"status\")}'
assert r.get('commandId') is not None, 'missing commandId'
" || die "broadcast_received event check"
echo "step 5 passed: delivery log contains broadcast_received event with correct metadata"

# ──── Step 6: Delivery status endpoint ────
STATUS=$(curl -sf "$BASE/local/delivery-status")
echo "$STATUS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d.get('ok'), f'delivery status not ok: {d}'
assert d.get('totalItems', 0) >= 1, f'no items in status: {d}'
assert d.get('broadcastItems', 0) >= 1, f'no broadcast items: {d}'
assert isinstance(d.get('statusCounts', {}), dict), 'missing statusCounts'
items = d.get('items', [])
bcast = [i for i in items if i.get('itemId') == '$BROADCAST_ID']
assert len(bcast) >= 1, f'broadcast $BROADCAST_ID not found in items ({len(items)} items)'
b = bcast[0]
assert b.get('receivedAt') is not None, 'broadcast missing receivedAt'
assert b.get('status') in ('received', 'active'), f'wrong broadcast status: {b.get(\"status\")}'
assert b.get('source') == 'broadcast', f'wrong source: {b.get(\"source\")}'
assert b.get('eventCount', 0) >= 1, f'wrong eventCount: {b.get(\"eventCount\")}'
" || die "delivery status endpoint check"
echo "step 6 passed: delivery status endpoint returns correct per-item lifecycle"

# ──── Step 7: Feed sync preserves delivery status ────
curl -sf -X POST "$BASE/local/feed/sync" > /dev/null 2>&1 || true

FEED_STATUS=$(curl -sf "$BASE/local/delivery-status")
echo "$FEED_STATUS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d.get('ok'), f'delivery status not ok: {d}'
assert d.get('totalItems', 0) >= 1, f'no items after feed sync'
items = d.get('items', [])
bcast = [i for i in items if i.get('itemId') == '$BROADCAST_ID']
assert len(bcast) >= 1, 'broadcast lost after feed sync'
" || die "feed sync + delivery status check"
echo "step 7 passed: delivery status persists across feed sync"

# ──── Step 8: Dismiss broadcast updates delivery status ────
curl -sf -X POST "$BASE/local/broadcast/dismiss" > /dev/null || die "dismiss broadcast"

STATUS_AFTER=$(curl -sf "$BASE/local/delivery-status")
echo "$STATUS_AFTER" | python3 -c "
import sys, json
d = json.load(sys.stdin)
items = d.get('items', [])
bcast = [i for i in items if i.get('itemId') == '$BROADCAST_ID']
assert len(bcast) >= 1, 'broadcast lost after dismiss'
b = bcast[0]
assert b.get('status') == 'dismissed', f'broadcast not dismissed: {b.get(\"status\")}'
assert b.get('dismissedAt') is not None, 'missing dismissedAt'
assert b.get('eventCount', 0) >= 2, f'eventCount too low: {b.get(\"eventCount\")} (expected >=2: received + dismissed)'
" || die "broadcast dismiss status check"
echo "step 8 passed: dismiss updates delivery status to dismissed with event count"

# ──── Step 9: Delivery status summary in diagnostics ────
DIAG=$(curl -sf "$BASE/local/diagnostics")
echo "$DIAG" | python3 -c "
import sys, json
d = json.load(sys.stdin)
# /local/diagnostics wraps in { ok, diagnostics: {...} }
diag = d.get('diagnostics', d)
ds = diag.get('deliveryStatus', {})
assert ds.get('totalItems', 0) >= 1, f'diagnostics missing deliveryStatus items: {ds}'
assert ds.get('broadcastItems', 0) >= 1, f'diagnostics missing broadcast items: {ds}'
assert isinstance(ds.get('statusCounts', {}), dict), 'diagnostics missing statusCounts'
" || die "diagnostics delivery status check"
echo "step 9 passed: delivery status summary in diagnostics"

# ──── Step 10: Delivery status summary in support bundle ────
BUNDLE=$(curl -sf "$BASE/local/support-bundle")
echo "$BUNDLE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
summary = d.get('summary', {})
ds = summary.get('deliveryStatus', {})
assert ds.get('totalItems', 0) >= 1, f'support bundle missing deliveryStatus: {ds}'
assert ds.get('broadcastItems', 0) >= 1, f'support bundle missing broadcast items: {ds}'
" || die "support bundle delivery status check"
echo "step 10 passed: delivery status summary in support bundle"

# ──── Step 11: Expired broadcast rejected at receipt ────
EXPIRED_ID="broadcast-expired-test-$(date +%s)"
curl -sf -X POST "$MOCK_URL/mock/queue-command/$DEVICE_ID" \
  -H "Content-Type: application/json" \
  -d "{
    \"type\": \"show_broadcast\",
    \"broadcastId\": \"$EXPIRED_ID\",
    \"title\": \"Already Expired\",
    \"expiresAt\": \"2020-01-01T00:00:00Z\",
    \"authorization\": {
      \"approved\": true,
      \"actorId\": \"admin-delivery-test\",
      \"actorRole\": \"admin\",
      \"authorizedAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
    }
  }" > /dev/null || die "queue expired broadcast"

curl -sf -X POST "$BASE/local/heartbeat" > /dev/null || true
sleep 0.3
node - "$TMP/data/commands.json" <<'NODE'
const fs = require("fs");
const f = process.argv[2];
try {
  const data = JSON.parse(fs.readFileSync(f, "utf8"));
  const items = Array.isArray(data) ? data : (data.items || []);
  fs.writeFileSync(f, JSON.stringify(items, null, 2));
} catch (e) {}
NODE

curl -sf -X POST "$BASE/local/commands/process" > /dev/null

EXPIRED_STATUS=$(curl -sf "$BASE/local/delivery-status")
echo "$EXPIRED_STATUS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
items = d.get('items', [])
bcast = [i for i in items if i.get('itemId') == '$EXPIRED_ID']
assert len(bcast) == 0, f'expired broadcast should not appear in delivery status, found: {bcast}'
" || die "expired broadcast rejection check"
echo "step 11 passed: expired broadcast rejected at receipt, no delivery status entry"

# ──── Step 12: Scheduled broadcast gets scheduled status ────
SCHEDULED_ID="broadcast-scheduled-test-$(date +%s)"
FUTURE_START=$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)
FUTURE_EXPIRES=$(date -u -d '+2 hours' +%Y-%m-%dT%H:%M:%SZ)
curl -sf -X POST "$MOCK_URL/mock/queue-command/$DEVICE_ID" \
  -H "Content-Type: application/json" \
  -d "{
    \"type\": \"show_broadcast\",
    \"broadcastId\": \"$SCHEDULED_ID\",
    \"title\": \"Scheduled Broadcast\",
    \"startsAt\": \"$FUTURE_START\",
    \"expiresAt\": \"$FUTURE_EXPIRES\",
    \"authorization\": {
      \"approved\": true,
      \"actorId\": \"admin-delivery-test\",
      \"actorRole\": \"admin\",
      \"authorizedAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
    }
  }" > /dev/null || die "queue scheduled broadcast"

curl -sf -X POST "$BASE/local/heartbeat" > /dev/null || true
sleep 0.3
node - "$TMP/data/commands.json" <<'NODE'
const fs = require("fs");
const f = process.argv[2];
try {
  const data = JSON.parse(fs.readFileSync(f, "utf8"));
  const items = Array.isArray(data) ? data : (data.items || []);
  fs.writeFileSync(f, JSON.stringify(items, null, 2));
} catch (e) {}
NODE

SCHED_RESULT=$(curl -sf -X POST "$BASE/local/commands/process")
echo "$SCHED_RESULT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
results = d.get('results', [])
assert len(results) > 0, 'no results'
r = results[0].get('result', results[0])
assert r.get('scheduled'), f'broadcast should be scheduled: {r}'
" || die "scheduled broadcast result"

SCHED_STATUS=$(curl -sf "$BASE/local/delivery-status")
echo "$SCHED_STATUS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
items = d.get('items', [])
bcast = [i for i in items if i.get('itemId') == '$SCHEDULED_ID']
assert len(bcast) >= 1, f'scheduled broadcast not found in delivery status'
b = bcast[0]
assert b.get('status') == 'scheduled', f'expected scheduled, got: {b.get(\"status\")}'
assert b.get('receivedAt') is not None, 'scheduled broadcast missing receivedAt'
" || die "scheduled broadcast status check"
echo "step 12 passed: scheduled broadcast gets 'scheduled' delivery status"

echo "broadcast delivery status check passed: receipt tracking, delivery status summary, per-item lifecycle, diagnostics, support bundle, expiry rejection, and scheduled status"
