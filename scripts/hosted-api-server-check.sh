#!/usr/bin/env bash
# hosted-api-server-check.sh — 12-step isolated validation gate for hosted-api/server.js
#
# Proves the database-backed API server responds correctly to the core device
# lifecycle: registration, pairing, auth, settings, heartbeat, stream, commands,
# release, and admin endpoints.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

HOSTED_API="$REPO_ROOT/hosted-api/server.js"
HOSTED_DB="$REPO_ROOT/hosted-api/db.js"
SCHEMA="$REPO_ROOT/scripts/aos-schema-sqlite-validation.sql"

PASS=0; FAIL=0; STEP=0

ok()   { PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
step() { STEP=$((STEP+1)); printf "\n── Step %d: %s ──\n" "$STEP" "$1"; }

# ── Cleanup ──────────────────────────────────────────────────────────────────
PORT=3199
TMP_DIR=""
API_PID=""
cleanup() {
  if [ -n "$API_PID" ]; then kill "$API_PID" 2>/dev/null || true; wait "$API_PID" 2>/dev/null || true; fi
  if [ -n "$TMP_DIR" ]; then rm -rf "$TMP_DIR"; fi
}
trap cleanup EXIT

# ── Step 1: Syntax validation ────────────────────────────────────────────────
step "Syntax validation"
node --check "$HOSTED_API" 2>/dev/null && ok || fail "hosted-api/server.js syntax"
node --check "$HOSTED_DB" 2>/dev/null && ok || fail "hosted-api/db.js syntax"
bash -n "$0" 2>/dev/null && ok || fail "self syntax"
echo "  Checks: $PASS passed, $FAIL failed"

# ── Step 2: Static contract — routes and methods present ─────────────────────
step "Static contract — routes and handlers"
SRV=$(cat "$HOSTED_API")

for route in \
  "POST.*frames/device/register" \
  "GET.*frames/device/:id/pairing-status" \
  "GET.*frames/device/:id/settings" \
  "POST.*frames/device/:id/settings" \
  "POST.*frames/device/:id/heartbeat" \
  "GET.*frames/device/:id/stream" \
  "GET.*frames/device/:id/feed" \
  "POST.*frames/device/:id/commands/:cmdId/ack" \
  "GET.*frames/device/:id/release" \
  "POST.*frames/artworks/:id/like" \
  "GET.*frames/admin/broadcast-deliveries" \
  "GET.*/health"
do
  echo "$SRV" | grep -qP "$route" && ok || fail "route: $route"
done

# Functions
for fn in handleRegister handlePairingStatus handleGetSettings handlePushSettings \
  handleHeartbeat handleStream handleFeed handleCommandAck handleRelease \
  handleLikeArtwork handleAdminBroadcastDeliveries handleAdminBroadcastDeliveryDetail \
  authenticateDevice; do
  echo "$SRV" | grep -qP "function $fn" && ok || fail "function: $fn"
done

# DB methods for stream composition
DB_CODE=$(cat "$HOSTED_DB")
for method in getStreamContent getActiveBroadcastCount; do
  echo "$DB_CODE" | grep -qP "$method\\s*\\(" && ok || fail "db method: $method"
done

echo "  Checks: $PASS passed, $FAIL failed"

# ── Step 3: Database bootstrap ───────────────────────────────────────────────
step "Database bootstrap"
TMP_DIR=$(mktemp -d)
DB_FILE="$TMP_DIR/aos-test.db"

node -e "
const AosDb = require('$HOSTED_DB');
const fs = require('fs');
const sql = fs.readFileSync('$SCHEMA', 'utf-8');
const db = new AosDb('$DB_FILE');
for (const stmt of sql.split(';').map(s => s.trim()).filter(s => s.length > 0)) {
  db.db.prepare(stmt).run();
}
const tables = db.listTables();
if (tables.length < 14) { process.stderr.write('Too few tables: ' + tables.length + '\n'); process.exit(1); }
db.close();
console.log('Tables: ' + tables.length);
" 2>/dev/null && ok || fail "database bootstrap"

TABLES=$(node -e "
const AosDb = require('$HOSTED_DB');
const db = new AosDb('$DB_FILE');
console.log(db.listTables().length);
db.close();
" 2>/dev/null)
[ "$TABLES" -ge 14 ] 2>/dev/null && ok || fail "14+ tables ($TABLES)"
echo "  Tables: $TABLES"

echo "  Checks: $PASS passed, $FAIL failed"

# ── Step 4: Server startup ──────────────────────────────────────────────────
step "Server startup"
# Re-create database for clean server test + seed content
rm -f "$DB_FILE"
node -e "
const AosDb = require('$HOSTED_DB');
const fs = require('fs');
const sql = fs.readFileSync('$SCHEMA', 'utf-8');
const db = new AosDb('$DB_FILE');
for (const stmt of sql.split(';').map(s => s.trim()).filter(s => s.length > 0)) {
  db.db.prepare(stmt).run();
}
// Seed content for stream composition testing
const items = [
  { id: 'seed-art-001', title: 'Test Artwork', type: 'artwork', media_url: 'https://autopoiesis.art/test.jpg', thumbnail_url: 'https://autopoiesis.art/test-thumb.jpg', artist: 'Vessel', artist_id: 'vessel', priority: 'normal', cache_allowed: 1, status: 'published', created_by: 'seed' },
  { id: 'seed-news-001', title: 'Test News', type: 'news', body: 'News body', priority: 'high', cache_allowed: 0, status: 'published', created_by: 'seed' },
  { id: 'seed-blog-001', title: 'Test Blog', type: 'blog_post', body: 'Blog body', priority: 'normal', cache_allowed: 0, status: 'published', created_by: 'seed' },
  { id: 'seed-cur-001', title: 'Test Curatorial', type: 'curatorial', body: 'Curatorial body', priority: 'normal', cache_allowed: 0, status: 'published', created_by: 'seed' },
  { id: 'seed-expired-001', title: 'Expired', type: 'artwork', media_url: 'https://autopoiesis.art/exp.jpg', priority: 'normal', cache_allowed: 1, status: 'published', created_by: 'seed', expires_at: new Date(Date.now() - 86400000).toISOString() },
  { id: 'seed-draft-001', title: 'Draft', type: 'artwork', priority: 'normal', cache_allowed: 1, status: 'draft', created_by: 'seed' },
];
const stmt = db.db.prepare('INSERT OR IGNORE INTO aos_broadcasts (id, title, body, type, media_url, thumbnail_url, artist, artist_id, priority, cache_allowed, status, created_by, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)');
for (const item of items) { stmt.run(item.id, item.title, item.body || null, item.type, item.media_url || null, item.thumbnail_url || null, item.artist || null, item.artist_id || null, item.priority, item.cache_allowed, item.status, item.created_by, item.expires_at || null); }
db.close();
" 2>/dev/null

AOS_DB="$DB_FILE" AOS_PORT="$PORT" node "$HOSTED_API" &
API_PID=$!

# Wait for server to start
for i in $(seq 1 20); do
  if curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done

HEALTH=$(curl -sf "http://127.0.0.1:$PORT/health" 2>/dev/null)
echo "$HEALTH" | grep -q '"ok":true' && ok || fail "health endpoint"
echo "$HEALTH" | grep -q '"service":"aos-hosted-api"' && ok || fail "service name"
echo "$HEALTH" | grep -q '"tables":1[4-9]' && ok || fail "tables count in health"
echo "  Health: $HEALTH"
echo "  Checks: $PASS passed, $FAIL failed"

# ── Step 5: Device registration ──────────────────────────────────────────────
step "Device registration"
REG=$(curl -sf -X POST "http://127.0.0.1:$PORT/frames/device/register" \
  -H "content-type: application/json" \
  -d '{"deviceId":"test-device-001","softwareVersion":"0.1.0"}')

echo "$REG" | grep -q '"ok":true' && ok || fail "registration ok"
echo "$REG" | grep -q '"deviceId":"test-device-001"' && ok || fail "deviceId returned"
echo "$REG" | grep -q '"deviceApiKey"' && ok || fail "deviceApiKey returned"
echo "$REG" | grep -q '"pairingCode"' && ok || fail "pairingCode returned"
echo "$REG" | grep -q '"expiresAt"' && ok || fail "expiresAt returned"

# Extract device key and pairing code
DEV_KEY=$(echo "$REG" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf-8')).device.deviceApiKey")
PAIR_CODE=$(echo "$REG" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf-8')).pairingCode")
echo "  Device key: ${DEV_KEY:0:16}..."
echo "  Pairing code: $PAIR_CODE"
echo "  Checks: $PASS passed, $FAIL failed"

# ── Step 6: Pairing status (pre-pair) ────────────────────────────────────────
step "Pairing status (pre-pair)"
PS=$(curl -sf "http://127.0.0.1:$PORT/frames/device/test-device-001/pairing-status")
echo "$PS" | grep -q '"paired":false' && ok || fail "paired=false before pairing"
echo "$PS" | grep -q '"status":"pending"' && ok || fail "status=pending"
echo "$PS" | grep -q '"pairingCode"' && ok || fail "pairingCode in status"
echo "  Checks: $PASS passed, $FAIL failed"

# ── Step 7: Auth-gated endpoints reject without device key ──────────────────
step "Auth enforcement"
for endpoint in \
  "POST /frames/device/test-device-001/settings" \
  "POST /frames/device/test-device-001/heartbeat" \
  "GET  /frames/device/test-device-001/stream"
do
  METHOD=$(echo "$endpoint" | awk '{print $1}')
  PATH_PART=$(echo "$endpoint" | awk '{print $2}')
  STATUS=$(curl -sf -o /dev/null -w '%{http_code}' -X "$METHOD" "http://127.0.0.1:$PORT$PATH_PART" \
    -H "content-type: application/json" \
    -d '{}' 2>/dev/null || true)
  [ "$STATUS" = "401" ] && ok || fail "auth required for $PATH_PART (got $STATUS)"
done
echo "  Checks: $PASS passed, $FAIL failed"

# ── Step 8: Pair the device via AosDb direct ─────────────────────────────────
step "Pair device via database"
PAIR_RESULT=$(node -e "
const AosDb = require('$HOSTED_DB');
const db = new AosDb('$DB_FILE');
const result = db.claimPairingCode('$PAIR_CODE', 'user-test-001');
console.log(JSON.stringify(result));
db.close();
" 2>/dev/null)
echo "$PAIR_RESULT" | grep -q '"ok":true' && ok || fail "pairing claim succeeded"

# Verify pairing status now shows completed
PS2=$(curl -sf "http://127.0.0.1:$PORT/frames/device/test-device-001/pairing-status")
echo "$PS2" | grep -q '"paired":true' && ok || fail "paired=true after pairing"
echo "$PS2" | grep -q '"status":"completed"' && ok || fail "status=completed"
echo "$PS2" | grep -q '"ownerUserId":"user-test-001"' && ok || fail "ownerUserId set"
echo "  Checks: $PASS passed, $FAIL failed"

# ── Step 9: Settings sync with conflict resolution ──────────────────────────
step "Settings sync"

# Read settings (no auth required for GET)
SETTINGS_GET=$(curl -sf "http://127.0.0.1:$PORT/frames/device/test-device-001/settings")
echo "$SETTINGS_GET" | grep -q '"ok":true' && ok || fail "settings read ok"

# Push newer settings (with device key)
PUSH_RESULT=$(curl -sf -X POST "http://127.0.0.1:$PORT/frames/device/test-device-001/settings" \
  -H "content-type: application/json" \
  -H "x-frame-device-key: $DEV_KEY" \
  -d "{\"settings\":{\"brightness\":70,\"updatedAt\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\"}}")
echo "$PUSH_RESULT" | grep -q '"ok":true' && ok || fail "settings push ok"
echo "$PUSH_RESULT" | grep -q '"brightness":70' && ok || fail "brightness saved"

# Push stale settings (should conflict)
STALE_TS="2020-01-01T00:00:00.000Z"
CONFLICT=$(curl -sf -X POST "http://127.0.0.1:$PORT/frames/device/test-device-001/settings" \
  -H "content-type: application/json" \
  -H "x-frame-device-key: $DEV_KEY" \
  -d "{\"settings\":{\"brightness\":10,\"updatedAt\":\"$STALE_TS\"}}")
echo "$CONFLICT" | grep -q '"conflict":true' && ok || fail "stale write conflict"
echo "$CONFLICT" | grep -q '"reason":"stale_write"' && ok || fail "stale_write reason"
echo "  Checks: $PASS passed, $FAIL failed"

# ── Step 10: Heartbeat with event ingestion ──────────────────────────────────
step "Heartbeat with event ingestion"
HB=$(curl -sf -X POST "http://127.0.0.1:$PORT/frames/device/test-device-001/heartbeat" \
  -H "content-type: application/json" \
  -H "x-frame-device-key: $DEV_KEY" \
  -d "{\"softwareVersion\":\"0.1.0\",\"currentMode\":\"kiosk\",\"events\":[{\"eventKey\":\"cmd_ack_001\",\"eventType\":\"command_acknowledged\",\"observedAt\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\"}]}")
echo "$HB" | grep -q '"ok":true' && ok || fail "heartbeat ok"
echo "$HB" | grep -q '"eventAck"' && ok || fail "eventAck present"
echo "$HB" | grep -q '"heartbeatAt"' && ok || fail "heartbeatAt present"
echo "  Checks: $PASS passed, $FAIL failed"

# ── Step 11: Stream endpoint returns correct contract shape ──────────────────
step "Stream endpoint contract"
STREAM=$(curl -sf "http://127.0.0.1:$PORT/frames/device/test-device-001/stream" \
  -H "x-frame-device-key: $DEV_KEY")
echo "$STREAM" | grep -q '"ok":true' && ok || fail "stream ok"
echo "$STREAM" | grep -q '"generatedAt"' && ok || fail "generatedAt"
echo "$STREAM" | grep -q '"items"' && ok || fail "items present"
# Items should be non-empty now that content is seeded
ITEM_COUNT=$(echo "$STREAM" | node -e "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')); process.stdout.write(String(d.items.length))" 2>/dev/null)
[ "$ITEM_COUNT" -ge 4 ] && ok || fail "stream has 4+ items (got $ITEM_COUNT)"
# High-priority items should come first
FIRST_PRIO=$(echo "$STREAM" | node -e "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')); process.stdout.write(d.items[0] ? d.items[0].priority : 'none')" 2>/dev/null)
[ "$FIRST_PRIO" = "high" ] && ok || fail "first item is high priority (got $FIRST_PRIO)"
# Expired items should be filtered
EXPIRED=$(echo "$STREAM" | node -e "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')); process.stdout.write(String(d.items.filter(i=>i.id==='seed-expired-001').length))" 2>/dev/null)
[ "$EXPIRED" = "0" ] && ok || fail "expired item filtered"
# Draft items should be filtered
DRAFTS=$(echo "$STREAM" | node -e "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')); process.stdout.write(String(d.items.filter(i=>i.id==='seed-draft-001').length))" 2>/dev/null)
[ "$DRAFTS" = "0" ] && ok || fail "draft item filtered"
echo "$STREAM" | grep -q '"polling"' && ok || fail "polling present"
echo "$STREAM" | grep -q '"displayMode"' && ok || fail "displayMode in settings"
echo "  Items: $ITEM_COUNT, first priority: $FIRST_PRIO"
echo "  Checks: $PASS passed, $FAIL failed"

# ── Step 12: Full lifecycle integration ──────────────────────────────────────
step "Full lifecycle integration"

# Second device
REG2=$(curl -sf -X POST "http://127.0.0.1:$PORT/frames/device/register" \
  -H "content-type: application/json" \
  -d '{"deviceId":"test-device-002","softwareVersion":"0.1.0"}')
echo "$REG2" | grep -q '"ok":true' && ok || fail "second device registration"
DEV_KEY2=$(echo "$REG2" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf-8')).device.deviceApiKey")
PAIR_CODE2=$(echo "$REG2" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf-8')).pairingCode")

# Pair second device
node -e "
const AosDb = require('$HOSTED_DB');
const db = new AosDb('$DB_FILE');
db.claimPairingCode('$PAIR_CODE2', 'user-test-002');
db.close();
" 2>/dev/null && ok || fail "second device paired"

# Command ack
CMD_RESULT=$(node -e "
const AosDb = require('$HOSTED_DB');
const db = new AosDb('$DB_FILE');
const cmd = db.queueCommand('test-device-002', 'sync_settings', { source: 'admin' }, 'low');
console.log(JSON.stringify(cmd));
db.close();
" 2>/dev/null)
CMD_ID=$(echo "$CMD_RESULT" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf-8')).commandId")

# Ack command via API
ACK=$(curl -sf -X POST "http://127.0.0.1:$PORT/frames/device/test-device-002/commands/$CMD_ID/ack" \
  -H "content-type: application/json" \
  -H "x-frame-device-key: $DEV_KEY2" \
  -d '{"status":"acknowledged"}')
echo "$ACK" | grep -q '"ok":true' && ok || fail "command ack ok"
echo "$ACK" | grep -q '"commandId"' && ok || fail "commandId in ack"

# Release check
REL=$(curl -sf "http://127.0.0.1:$PORT/frames/device/test-device-002/release" \
  -H "x-frame-device-key: $DEV_KEY2")
echo "$REL" | grep -q '"ok":true' && ok || fail "release ok"
echo "$REL" | grep -q '"currentVersion"' && ok || fail "currentVersion"

# Admin broadcast deliveries (empty)
AD_BD=$(curl -sf "http://127.0.0.1:$PORT/frames/admin/broadcast-deliveries")
echo "$AD_BD" | grep -q '"ok":true' && ok || fail "admin broadcast deliveries ok"

echo "  Checks: $PASS passed, $FAIL failed"

# ── Summary ──────────────────────────────────────────────────────────────────
printf "\n═══ Summary: %d passed, %d failed (12 steps) ═══\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
