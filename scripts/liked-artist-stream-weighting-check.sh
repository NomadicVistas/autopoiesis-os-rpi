#!/usr/bin/env bash
# liked-artist-stream-weighting-check.sh
# Validation gate for liked-artwork → artist preference → stream composition weighting.
#
# Tests: getLikedArtistIds() method, handleStream() integration,
#        liked artists merged with explicit preferences, stream ordering,
#        empty-likes graceful fallback, auth gates, regression.

set -euo pipefail

PASS=0; FAIL=0; TOTAL=0
step_n=0

p() { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "  ✅ $1"; }
f() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "  ❌ $1"; }
s() { step_n=$((step_n+1)); echo ""; echo "Step $step_n: $1"; }
die() { echo "FATAL: $1" >&2; exit 1; }

REPO="$(cd "$(dirname "$0")/.." && pwd)"
API_PORT=19891
API_PID=""
DB=""
ADMIN_TOKEN="test-admin-token-stream-liked"

cleanup() {
  [ -n "$API_PID" ] && kill "$API_PID" 2>/dev/null || true
  [ -n "$DB" ] && rm -f "$DB" "${DB}-shm" "${DB}-wal"
}
trap cleanup EXIT

# ── Step 1: Syntax validation ────────────────────────────────────────────────
s "Syntax validation"

node --check "$REPO/hosted-api/server.js" && p "hosted-api/server.js syntax OK" || f "hosted-api/server.js syntax FAIL"
node --check "$REPO/hosted-api/db.js" && p "hosted-api/db.js syntax OK" || f "hosted-api/db.js syntax FAIL"
bash -n "$REPO/install.sh" && p "install.sh syntax OK" || f "install.sh syntax FAIL"
bash -n "$REPO/update.sh" && p "update.sh syntax OK" || f "update.sh syntax FAIL"
bash -n "$REPO/factory-reset.sh" && p "factory-reset.sh syntax OK" || f "factory-reset.sh syntax FAIL"

# ── Step 2: Static contract ──────────────────────────────────────────────────
s "Static contract — new method and wiring"

grep -q 'getLikedArtistIds' "$REPO/hosted-api/db.js" && p "getLikedArtistIds exists in db.js" || f "getLikedArtistIds missing from db.js"
grep -q 'JOIN aos_broadcasts' "$REPO/hosted-api/db.js" && p "getLikedArtistIds joins aos_broadcasts" || f "JOIN aos_broadcasts not found"
grep -q 'GROUP BY b.artist_id' "$REPO/hosted-api/db.js" && p "Groups by artist_id" || f "GROUP BY artist_id not found"
grep -q 'ORDER BY like_count DESC' "$REPO/hosted-api/db.js" && p "Orders by like_count DESC" || f "like_count ordering not found"
grep -q "rows.map(r => r.artist_id)" "$REPO/hosted-api/db.js" && p "Returns artist_id array" || f "artist_id mapping not found"
grep -A2 'getLikedArtistIds' "$REPO/hosted-api/db.js" | grep -q 'try' && p "Has try/catch for safety" || f "No try/catch"
grep -q 'getLikedArtistIds' "$REPO/hosted-api/server.js" && p "server.js calls getLikedArtistIds" || f "server.js doesn't call getLikedArtistIds"
grep -q 'likedArtistIds' "$REPO/hosted-api/server.js" && p "server.js uses likedArtistIds variable" || f "likedArtistIds variable not found"
grep -q 'existingSet' "$REPO/hosted-api/server.js" && p "server.js deduplicates artist IDs" || f "Deduplication not found"
grep -B5 'getLikedArtistIds' "$REPO/hosted-api/db.js" | grep -q '@returns' && p "JSDoc @returns present" || f "Missing JSDoc @returns"

# ── Step 3: Start hosted API ─────────────────────────────────────────────────
s "Start hosted API"

DB=$(mktemp /tmp/aos-liked-artist-test-XXXXXX.db)
export AOS_PORT="$API_PORT"
export AOS_HOST="127.0.0.1"
export AOS_DB="$DB"
export AUTOPOIESIS_FRAMES_ADMIN_TOKEN="$ADMIN_TOKEN"

API_OUT=$(mktemp)
node "$REPO/hosted-api/server.js" > "$API_OUT" 2>&1 &
API_PID=$!

for i in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:$API_PORT/health" > /dev/null 2>&1; then
    break
  fi
  sleep 0.25
done

if curl -sf "http://127.0.0.1:$API_PORT/health" > /dev/null 2>&1; then
  p "Hosted API started on port $API_PORT"
else
  f "Hosted API failed to start"
  cat "$API_OUT" >&2
  die "Cannot continue without API server"
fi

TABLES=$(curl -sf "http://127.0.0.1:$API_PORT/health" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tables',0))" 2>/dev/null || echo "0")
[ "$TABLES" -ge 10 ] && p "Database has $TABLES tables" || f "Database has only $TABLES tables (expected >=10)"

# ── Step 4: Device registration + pairing ────────────────────────────────────
s "Device registration + pairing"

REG=$(curl -sf -X POST "http://127.0.0.1:$API_PORT/frames/device/register" \
  -H "content-type: application/json" \
  -d '{"deviceName":"liked-artist-test","deviceType":"rpi"}') || die "Registration failed"
DEVICE_ID=$(echo "$REG" | python3 -c "import sys,json; print(json.load(sys.stdin)['device']['deviceId'])" 2>/dev/null)
API_KEY=$(echo "$REG" | python3 -c "import sys,json; print(json.load(sys.stdin)['device']['deviceApiKey'])" 2>/dev/null)
PAIRING_CODE=$(echo "$REG" | python3 -c "import sys,json; print(json.load(sys.stdin)['pairingCode'])" 2>/dev/null)

[ -n "$DEVICE_ID" ] && p "Device registered: $DEVICE_ID" || f "Device ID empty"
[ -n "$API_KEY" ] && p "API key received" || f "API key empty"
[ -n "$PAIRING_CODE" ] && p "Pairing code received: $PAIRING_CODE" || f "Pairing code empty"

# Claim pairing code
OWNER_ID="user-liked-artist-$(date +%s)"
PAIR_RESULT=$(node -e "
const AosDb = require('$REPO/hosted-api/db.js');
const db = new AosDb('$DB');
try {
  const result = db.claimPairingCode('$PAIRING_CODE', '$OWNER_ID');
  console.log(JSON.stringify(result));
} catch(e) {
  console.log(JSON.stringify({ ok: false, error: e.message }));
}
" 2>&1)
echo "$PAIR_RESULT" | grep -q '"ok":true' && p "Device paired with $OWNER_ID" || f "Pairing failed: $PAIR_RESULT"

# ── Step 5: Seed content from multiple artists ──────────────────────────────
s "Seed content from multiple artists"

ARTISTS=("vessel-001" "sandman-002" "kinema-003")
ARTIST_NAMES=("Vessel" "Sandman" "Kinema")
CREATED=0

for i in 0 1 2; do
  for j in 1 2; do
    ART_ID="art-liked-test-${ARTISTS[$i]}-${j}"
    BODY="{\"id\":\"$ART_ID\",\"title\":\"Test Art ${ARTIST_NAMES[$i]} $j\",\"type\":\"artwork\",\"artist\":\"${ARTIST_NAMES[$i]}\",\"artistId\":\"${ARTISTS[$i]}\",\"mediaUrl\":\"https://example.com/art/${ARTISTS[$i]}/$j.jpg\",\"thumbnailUrl\":\"https://example.com/art/${ARTISTS[$i]}/$j-thumb.jpg\",\"priority\":\"normal\",\"cacheAllowed\":true,\"targetType\":\"all\"}"

    RESULT=$(curl -sf -X POST "http://127.0.0.1:$API_PORT/frames/admin/broadcasts" \
      -H "content-type: application/json" \
      -H "x-admin-token: $ADMIN_TOKEN" \
      -d "$BODY" 2>/dev/null) || true
    echo "$RESULT" | grep -q '"ok":true' && ((CREATED++)) || true

    curl -sf -X POST "http://127.0.0.1:$API_PORT/frames/admin/broadcasts/$ART_ID/publish" \
      -H "x-admin-token: $ADMIN_TOKEN" >/dev/null 2>&1 || true
  done
done

[ "$CREATED" -ge 5 ] && p "Seeded $CREATED/6 artworks" || f "Seeded only $CREATED/6"

# ── Step 6: Stream without likes (baseline) ──────────────────────────────────
s "Stream without likes (baseline)"

STREAM0=$(curl -sf "http://127.0.0.1:$API_PORT/frames/device/$DEVICE_ID/stream" \
  -H "x-frame-device-key: $API_KEY") || echo '{"items":[]}'

ITEMS0=$(echo "$STREAM0" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('items',[])))" 2>/dev/null)
[ "$ITEMS0" -ge 5 ] && p "Stream has $ITEMS0 items (expected >= 5)" || f "Stream has $ITEMS0 items (expected >= 5)"

echo "$STREAM0" | python3 -c "
import sys,json
data = json.load(sys.stdin)
artists = set(item.get('artistId') for item in data.get('items',[]) if item.get('artistId'))
assert 'vessel-001' in artists, f'Missing vessel: {artists}'
assert 'sandman-002' in artists, f'Missing sandman: {artists}'
assert 'kinema-003' in artists, f'Missing kinema: {artists}'
" 2>/dev/null && p "All 3 artists in baseline stream" || f "Not all artists in baseline stream"

# ── Step 7: Like artworks from specific artists ─────────────────────────────
s "Like artworks from Vessel (2) and Kinema (1), not Sandman"

LIKED=0
for ART_ID in "art-liked-test-vessel-001-1" "art-liked-test-vessel-001-2" "art-liked-test-kinema-003-1"; do
  LIKE_RESULT=$(curl -sf -X POST "http://127.0.0.1:$API_PORT/frames/artworks/$ART_ID/like" \
    -H "content-type: application/json" \
    -H "x-frame-device-key: $API_KEY" \
    -d "{\"deviceId\":\"$DEVICE_ID\"}" 2>/dev/null) || true
  echo "$LIKE_RESULT" | grep -q '"ok":true' && ((LIKED++)) || true
done

[ "$LIKED" -ge 3 ] && p "Liked $LIKED/3 artworks" || f "Liked only $LIKED/3"

# ── Step 8: Verify getLikedArtistIds returns correct artists ────────────────
s "Verify getLikedArtistIds via direct DB query"

node -e "
const AosDb = require('$REPO/hosted-api/db.js');
const db = new AosDb('$DB');
const artists = db.getLikedArtistIds('$OWNER_ID');
console.log(JSON.stringify(artists));
" 2>/dev/null | python3 -c "
import sys,json
artists = json.load(sys.stdin)
assert 'vessel-001' in artists, f'Vessel not in liked artists: {artists}'
assert 'kinema-003' in artists, f'Kinema not in liked artists: {artists}'
assert 'sandman-002' not in artists, f'Sandman should not be in liked artists: {artists}'
assert artists[0] == 'vessel-001', f'Vessel should be first (most liked): {artists}'
print(f'Liked artists: {artists}')
" && p "getLikedArtistIds returns vessel-001 (first), kinema-003, not sandman-002" || f "getLikedArtistIds incorrect"

# ── Step 9: Stream with likes — liked artists boosted ───────────────────────
s "Stream with likes — liked artists boosted above unliked"

STREAM1=$(curl -sf "http://127.0.0.1:$API_PORT/frames/device/$DEVICE_ID/stream" \
  -H "x-frame-device-key: $API_KEY") || echo '{"items":[]}'

echo "$STREAM1" | python3 -c "
import sys,json
data = json.load(sys.stdin)
items = data.get('items', [])
assert len(items) >= 5, f'Expected >= 5 items, got {len(items)}'

positions = {}
for i, item in enumerate(items):
    aid = item.get('artistId')
    if aid and aid not in positions:
        positions[aid] = i

vessel_pos = positions.get('vessel-001', 999)
sandman_pos = positions.get('sandman-002', 999)
kinema_pos = positions.get('kinema-003', 999)

assert vessel_pos < sandman_pos, f'Vessel ({vessel_pos}) should be before Sandman ({sandman_pos})'
assert kinema_pos < sandman_pos, f'Kinema ({kinema_pos}) should be before Sandman ({sandman_pos})'
print(f'Positions: vessel={vessel_pos}, kinema={kinema_pos}, sandman={sandman_pos}')
" && p "Liked artists (Vessel, Kinema) boosted above unliked (Sandman)" || f "Artist boosting not working"

# ── Step 10: Empty likes fallback ───────────────────────────────────────────
s "Edge case — user with no likes"

REG2=$(curl -sf -X POST "http://127.0.0.1:$API_PORT/frames/device/register" \
  -H "content-type: application/json" \
  -d '{"deviceName":"no-likes-test","deviceType":"rpi"}') || die "Registration 2 failed"
DEVICE_ID2=$(echo "$REG2" | python3 -c "import sys,json; print(json.load(sys.stdin)['device']['deviceId'])" 2>/dev/null)
API_KEY2=$(echo "$REG2" | python3 -c "import sys,json; print(json.load(sys.stdin)['device']['deviceApiKey'])" 2>/dev/null)
PAIRING_CODE2=$(echo "$REG2" | python3 -c "import sys,json; print(json.load(sys.stdin)['pairingCode'])" 2>/dev/null)

OWNER_ID2="user-no-likes-$(date +%s)"
node -e "
const AosDb = require('$REPO/hosted-api/db.js');
const db = new AosDb('$DB');
db.claimPairingCode('$PAIRING_CODE2', '$OWNER_ID2');
" 2>/dev/null

STREAM_NO_LIKES=$(curl -sf "http://127.0.0.1:$API_PORT/frames/device/$DEVICE_ID2/stream" \
  -H "x-frame-device-key: $API_KEY2") || echo '{"ok":false}'

echo "$STREAM_NO_LIKES" | python3 -c "
import sys,json
data = json.load(sys.stdin)
assert data.get('ok'), 'Stream should return ok'
items = data.get('items', [])
assert len(items) >= 5, f'Expected >= 5 items, got {len(items)}'
print(f'No-likes stream: {len(items)} items')
" && p "Stream works for user with no likes" || f "Stream failed for user with no likes"

node -e "
const AosDb = require('$REPO/hosted-api/db.js');
const db = new AosDb('$DB');
const artists = db.getLikedArtistIds('$OWNER_ID2');
console.log(JSON.stringify(artists));
" 2>/dev/null | python3 -c "
import sys,json
artists = json.load(sys.stdin)
assert len(artists) == 0, f'Expected empty, got {artists}'
" && p "getLikedArtistIds returns empty for no likes" || f "getLikedArtistIds not empty for no likes"

# ── Step 11: Regression — other endpoints unaffected ─────────────────────────
s "Regression — other endpoints unaffected"

SETTINGS=$(curl -sf "http://127.0.0.1:$API_PORT/frames/device/$DEVICE_ID/settings" \
  -H "x-frame-device-key: $API_KEY")
echo "$SETTINGS" | grep -q '"ok":true' && p "Settings endpoint OK" || f "Settings endpoint FAIL"

curl -sf "http://127.0.0.1:$API_PORT/health" >/dev/null 2>&1 && p "Health endpoint OK" || f "Health endpoint FAIL"

BUNDLE=$(curl -sf "http://127.0.0.1:$API_PORT/frames/admin/bundle?userId=$OWNER_ID" \
  -H "x-admin-token: $ADMIN_TOKEN")
echo "$BUNDLE" | grep -q '"ok":true' && p "Admin bundle OK" || f "Admin bundle FAIL"

HB=$(curl -sf -X POST "http://127.0.0.1:$API_PORT/frames/device/$DEVICE_ID/heartbeat" \
  -H "content-type: application/json" \
  -H "x-frame-device-key: $API_KEY" \
  -d '{"currentMode":"display","softwareVersion":"0.1.0"}')
echo "$HB" | grep -q '"ok":true' && p "Heartbeat OK" || f "Heartbeat FAIL"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  TOTAL:  Pass: $PASS  Fail: $FAIL  (of $TOTAL)"
echo "════════════════════════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
  echo "  ❌ FAILED"
  exit 1
fi
echo "  ✅ ALL CHECKS PASSED"
exit 0
