#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Artwork Like Endpoint Integration Check
# Validates that POST /frames/artworks/:id/like is properly wired through
# authenticateDevice → handleLikeArtwork → db.likeArtwork / db.unlikeArtwork
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

PASS=0; FAIL=0; TOTAL=0
step_n=0

p() { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "  ✅ $1"; }
f() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "  ❌ $1"; }
s() { step_n=$((step_n+1)); echo ""; echo "Step $step_n: $1"; }
die() { echo "FATAL: $1" >&2; exit 1; }

REPO="$(cd "$(dirname "$0")/.." && pwd)"
API_PORT=19831
API_PID=""
DB=""

cleanup() {
  [ -n "$API_PID" ] && kill "$API_PID" 2>/dev/null || true
  [ -n "$DB" ] && rm -f "$DB"
}
trap cleanup EXIT

# ── Step 1: Syntax validation ────────────────────────────────────────────────
s "Syntax validation"

node --check "$REPO/hosted-api/server.js" && p "hosted-api/server.js syntax OK" || f "hosted-api/server.js syntax FAIL"
node --check "$REPO/hosted-api/db.js" && p "hosted-api/db.js syntax OK" || f "hosted-api/db.js syntax FAIL"
bash -n "$REPO/scripts/artwork-like-endpoint-check.sh" && p "self syntax OK" || f "self syntax FAIL"

# ── Step 2: Static contract ──────────────────────────────────────────────────
s "Static contract — route handler calls authenticateDevice + handleLikeArtwork"

# Verify the like route handler uses authenticateDevice
if grep -q 'authenticateDevice(db, req, likeDeviceId)' "$REPO/hosted-api/server.js"; then
  p "Like route calls authenticateDevice with likeDeviceId"
else
  f "Like route does NOT call authenticateDevice"
fi

# Verify the like route handler calls handleLikeArtwork
if grep -q 'handleLikeArtwork(db, likeMatch\[1\], body, auth)' "$REPO/hosted-api/server.js"; then
  p "Like route calls handleLikeArtwork with auth"
else
  f "Like route does NOT call handleLikeArtwork"
fi

# Verify handleLikeArtwork reads auth.record.ownerUserId
if grep -q 'auth.record.ownerUserId' "$REPO/hosted-api/server.js"; then
  p "handleLikeArtwork reads auth.record.ownerUserId"
else
  f "handleLikeArtwork does NOT read ownerUserId from auth"
fi

# Verify db.likeArtwork exists
if grep -q 'likeArtwork(userId, artworkId)' "$REPO/hosted-api/db.js"; then
  p "db.likeArtwork method exists"
else
  f "db.likeArtwork method NOT found"
fi

# Verify db.unlikeArtwork exists
if grep -q 'unlikeArtwork(userId, artworkId)' "$REPO/hosted-api/db.js"; then
  p "db.unlikeArtwork method exists"
else
  f "db.unlikeArtwork method NOT found"
fi

# Verify db.getLikedArtworks exists
if grep -q 'getLikedArtworks(userId)' "$REPO/hosted-api/db.js"; then
  p "db.getLikedArtworks method exists"
else
  f "db.getLikedArtworks method NOT found"
fi

# Verify the fake-response path is gone (no more "Minimal: accept like requests")
if ! grep -q 'Minimal: accept like requests' "$REPO/hosted-api/server.js"; then
  p "Fake response path removed from like handler"
else
  f "Fake response path still present"
fi

# Verify body.deviceId is used
if grep -q 'body.deviceId' "$REPO/hosted-api/server.js"; then
  p "Like handler reads deviceId from body"
else
  f "Like handler does NOT read deviceId from body"
fi

# ── Step 3: Start hosted API ─────────────────────────────────────────────────
s "Start hosted API"

DB=$(mktemp /tmp/aos-like-test-XXXXXX.db)
export AOS_PORT="$API_PORT"
export AOS_HOST="127.0.0.1"
export AOS_DB="$DB"
export AUTOPOIESIS_FRAMES_ADMIN_TOKEN="test-admin-token"

API_OUT=$(mktemp)
node "$REPO/hosted-api/server.js" > "$API_OUT" 2>&1 &
API_PID=$!

# Wait for server to start
for i in $(seq 1 20); do
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

TABLES=$(curl -sf "http://127.0.0.1:$API_PORT/health" | python3 -c "import sys,json; print(json.load(sys.stdin)['tables'])" 2>/dev/null || echo "0")
if [ "$TABLES" -ge 10 ]; then
  p "Database has $TABLES tables"
else
  f "Database has only $TABLES tables (expected >=10)"
fi

# ── Step 4: Register device and pair it ───────────────────────────────────────
s "Register device and pair with owner"

REG=$(curl -sf -X POST "http://127.0.0.1:$API_PORT/frames/device/register" \
  -H "content-type: application/json" \
  -d '{"deviceName":"like-test-frame","deviceType":"rpi"}') || die "Registration failed"
DEVICE_ID=$(echo "$REG" | python3 -c "import sys,json; print(json.load(sys.stdin)['device']['deviceId'])")
API_KEY=$(echo "$REG" | python3 -c "import sys,json; print(json.load(sys.stdin)['device']['deviceApiKey'])")
PAIRING_CODE=$(echo "$REG" | python3 -c "import sys,json; print(json.load(sys.stdin)['pairingCode'])")

[ -n "$DEVICE_ID" ] && p "Device registered: $DEVICE_ID" || f "Device ID empty"
[ -n "$API_KEY" ] && p "API key received" || f "API key empty"
[ -n "$PAIRING_CODE" ] && p "Pairing code received: $PAIRING_CODE" || f "Pairing code empty"

# Claim the pairing code to pair the device with an owner
OWNER_ID="user-alice-001"
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

echo "$PAIR_RESULT" | grep -q '"ok":true' && p "Pairing code claimed, device paired with $OWNER_ID" || f "Pairing failed: $PAIR_RESULT"

# Verify device has owner
DEVICE_CHECK=$(node -e "
const AosDb = require('$REPO/hosted-api/db.js');
const db = new AosDb('$DB');
const d = db.getDevice('$DEVICE_ID');
console.log(JSON.stringify({ ownerUserId: d ? d.ownerUserId : null, paired: d ? d.paired : null }));
" 2>&1)
echo "$DEVICE_CHECK" | grep -q "$OWNER_ID" && p "Device owner confirmed: $OWNER_ID" || f "Device owner not set: $DEVICE_CHECK"

# ── Step 5: Like an artwork (authenticated) ────────────────────────────────────
s "Like an artwork — authenticated request"

LIKE_RESP=$(curl -sf -X POST "http://127.0.0.1:$API_PORT/frames/artworks/artwork-vessel-001/like" \
  -H "content-type: application/json" \
  -H "x-frame-device-key: $API_KEY" \
  -d "{\"deviceId\":\"$DEVICE_ID\",\"source\":\"autopoiesis-os\",\"observedAt\":\"2026-06-08T20:00:00Z\"}") || echo "LIKE_FAILED"

echo "$LIKE_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('ok'), f'not ok: {d}'; assert d.get('liked')==True, f'not liked: {d}'; print('like-OK')" 2>/dev/null && p "Like endpoint returned ok=true, liked=true" || f "Like endpoint response unexpected: $LIKE_RESP"

# Verify the like was persisted in the database
LIKED_CHECK=$(node -e "
const AosDb = require('$REPO/hosted-api/db.js');
const db = new AosDb('$DB');
const likes = db.getLikedArtworks('$OWNER_ID');
console.log(JSON.stringify(likes));
" 2>&1)
echo "$LIKED_CHECK" | grep -q "artwork-vessel-001" && p "Like persisted in database for owner $OWNER_ID" || f "Like NOT in database: $LIKED_CHECK"

# ── Step 6: Unlike the artwork ────────────────────────────────────────────────
s "Unlike the artwork — authenticated request"

UNLIKE_RESP=$(curl -sf -X POST "http://127.0.0.1:$API_PORT/frames/artworks/artwork-vessel-001/like" \
  -H "content-type: application/json" \
  -H "x-frame-device-key: $API_KEY" \
  -d "{\"deviceId\":\"$DEVICE_ID\",\"liked\":false,\"source\":\"autopoiesis-os\"}") || echo "UNLIKE_FAILED"

echo "$UNLIKE_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('ok'), f'not ok: {d}'; assert d.get('liked')==False, f'still liked: {d}'; print('unlike-OK')" 2>/dev/null && p "Unlike endpoint returned ok=true, liked=false" || f "Unlike endpoint response unexpected: $UNLIKE_RESP"

# Verify the unlike was persisted
UNLIKED_CHECK=$(node -e "
const AosDb = require('$REPO/hosted-api/db.js');
const db = new AosDb('$DB');
const likes = db.getLikedArtworks('$OWNER_ID');
console.log(JSON.stringify(likes));
" 2>&1)
echo "$UNLIKED_CHECK" | grep -q "artwork-vessel-001" && f "Artwork still in liked list after unlike" || p "Artwork removed from liked list"

# ── Step 7: Re-like and verify multiple likes ──────────────────────────────────
s "Re-like and like multiple artworks"

# Re-like the first one
curl -sf -X POST "http://127.0.0.1:$API_PORT/frames/artworks/artwork-vessel-001/like" \
  -H "content-type: application/json" \
  -H "x-frame-device-key: $API_KEY" \
  -d "{\"deviceId\":\"$DEVICE_ID\"}" > /dev/null

# Like a second artwork
curl -sf -X POST "http://127.0.0.1:$API_PORT/frames/artworks/artwork-sandman-002/like" \
  -H "content-type: application/json" \
  -H "x-frame-device-key: $API_KEY" \
  -d "{\"deviceId\":\"$DEVICE_ID\"}" > /dev/null

# Like a third artwork
curl -sf -X POST "http://127.0.0.1:$API_PORT/frames/artworks/artwork-jessy-003/like" \
  -H "content-type: application/json" \
  -H "x-frame-device-key: $API_KEY" \
  -d "{\"deviceId\":\"$DEVICE_ID\"}" > /dev/null

MULTI_CHECK=$(node -e "
const AosDb = require('$REPO/hosted-api/db.js');
const db = new AosDb('$DB');
const likes = db.getLikedArtworks('$OWNER_ID');
console.log(JSON.stringify({ count: likes.length, ids: likes }));
" 2>&1)

MULTI_COUNT=$(echo "$MULTI_CHECK" | python3 -c "import sys,json; print(json.load(sys.stdin)['count'])" 2>/dev/null || echo "0")
if [ "$MULTI_COUNT" -ge 3 ]; then
  p "Multiple likes persisted: $MULTI_COUNT artworks"
else
  f "Expected >=3 likes, got $MULTI_COUNT: $MULTI_CHECK"
fi

echo "$MULTI_CHECK" | grep -q "artwork-vessel-001" && p "artwork-vessel-001 in liked list" || f "artwork-vessel-001 missing"
echo "$MULTI_CHECK" | grep -q "artwork-sandman-002" && p "artwork-sandman-002 in liked list" || f "artwork-sandman-002 missing"
echo "$MULTI_CHECK" | grep -q "artwork-jessy-003" && p "artwork-jessy-003 in liked list" || f "artwork-jessy-003 missing"

# ── Step 8: Auth failure cases ────────────────────────────────────────────────
s "Auth failure cases"

# 8a: No device key → 401
NO_KEY=$(curl -sf -X POST "http://127.0.0.1:$API_PORT/frames/artworks/artwork-test/like" \
  -H "content-type: application/json" \
  -d "{\"deviceId\":\"$DEVICE_ID\"}" 2>&1 || echo "CURL_FAIL_${NO_KEY:-}")
if echo "$NO_KEY" | grep -q "Missing device key\|401"; then
  p "No device key → rejected"
else
  # Check the actual HTTP status
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://127.0.0.1:$API_PORT/frames/artworks/artwork-test/like" \
    -H "content-type: application/json" \
    -d "{\"deviceId\":\"$DEVICE_ID\"}")
  if [ "$HTTP_CODE" = "401" ]; then
    p "No device key → HTTP 401"
  else
    f "No device key → expected 401, got $HTTP_CODE: $NO_KEY"
  fi
fi

# 8b: Wrong device key → 401/403
WRONG_KEY=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://127.0.0.1:$API_PORT/frames/artworks/artwork-test/like" \
  -H "content-type: application/json" \
  -H "x-frame-device-key: wrong-key-12345" \
  -d "{\"deviceId\":\"$DEVICE_ID\"}")
if [ "$WRONG_KEY" = "401" ] || [ "$WRONG_KEY" = "403" ]; then
  p "Wrong device key → HTTP $WRONG_KEY"
else
  f "Wrong device key → expected 401/403, got $WRONG_KEY"
fi

# 8c: No deviceId in body → 400
NO_DID=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://127.0.0.1:$API_PORT/frames/artworks/artwork-test/like" \
  -H "content-type: application/json" \
  -H "x-frame-device-key: $API_KEY" \
  -d '{"source":"test"}')
if [ "$NO_DID" = "400" ]; then
  p "No deviceId in body → HTTP 400"
else
  f "No deviceId in body → expected 400, got $NO_DID"
fi

# 8d: Unpaired device (no owner) → 403
REG2=$(curl -sf -X POST "http://127.0.0.1:$API_PORT/frames/device/register" \
  -H "content-type: application/json" \
  -d '{"deviceName":"unpaired-frame","deviceType":"rpi"}')
DEVICE2_ID=$(echo "$REG2" | python3 -c "import sys,json; print(json.load(sys.stdin)['device']['deviceId'])")
API_KEY2=$(echo "$REG2" | python3 -c "import sys,json; print(json.load(sys.stdin)['device']['deviceApiKey'])")

UNPAIRED=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://127.0.0.1:$API_PORT/frames/artworks/artwork-test/like" \
  -H "content-type: application/json" \
  -H "x-frame-device-key: $API_KEY2" \
  -d "{\"deviceId\":\"$DEVICE2_ID\"}")
if [ "$UNPAIRED" = "403" ]; then
  p "Unpaired device (no owner) → HTTP 403"
else
  # Check the actual response body
  UNPAIRED_BODY=$(curl -sf -X POST "http://127.0.0.1:$API_PORT/frames/artworks/artwork-test/like" \
    -H "content-type: application/json" \
    -H "x-frame-device-key: $API_KEY2" \
    -d "{\"deviceId\":\"$DEVICE2_ID\"}" 2>&1 || echo "")
  if echo "$UNPAIRED_BODY" | grep -q "no owner\|has no owner"; then
    p "Unpaired device → 'Device has no owner' error"
  else
    f "Unpaired device → expected 403, got $UNPAIRED: $UNPAIRED_BODY"
  fi
fi

# ── Step 9: Idempotent like (like same artwork twice) ──────────────────────────
s "Idempotent like"

# Like artwork-vessel-001 again (already liked)
LIKE_AGAIN=$(curl -sf -X POST "http://127.0.0.1:$API_PORT/frames/artworks/artwork-vessel-001/like" \
  -H "content-type: application/json" \
  -H "x-frame-device-key: $API_KEY" \
  -d "{\"deviceId\":\"$DEVICE_ID\"}")
echo "$LIKE_AGAIN" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('ok'), f'not ok: {d}'; print('idempotent-OK')" 2>/dev/null && p "Re-liking already-liked artwork returns ok" || f "Re-like response unexpected: $LIKE_AGAIN"

# Count should still be 3 (INSERT OR IGNORE)
COUNT_CHECK=$(node -e "
const AosDb = require('$REPO/hosted-api/db.js');
const db = new AosDb('$DB');
const likes = db.getLikedArtworks('$OWNER_ID');
console.log(likes.length);
" 2>&1)
[ "$COUNT_CHECK" = "3" ] && p "Like count unchanged (INSERT OR IGNORE): $COUNT_CHECK" || f "Like count changed after idempotent like: $COUNT_CHECK"

# ── Step 10: Admin bundle includes liked artworks ─────────────────────────────
s "Admin bundle includes liked artworks for owner"

BUNDLE=$(curl -sf "http://127.0.0.1:$API_PORT/frames/admin/bundle?userId=$OWNER_ID" \
  -H "x-admin-token: test-admin-token") || echo "BUNDLE_FAIL"

echo "$BUNDLE" | python3 -c "
import sys,json
d = json.load(sys.stdin)
pf = d.get('profileFrames', {})
likes = pf.get('likedArtworks', [])
# likedArtworks may be array of strings or array of objects with artworkId
ids = [x if isinstance(x, str) else x.get('artworkId') for x in likes]
assert len(ids) >= 3, f'expected >=3 likes, got {len(ids)}: {ids}'
assert 'artwork-vessel-001' in ids, f'missing vessel: {ids}'
assert 'artwork-sandman-002' in ids, f'missing sandman: {ids}'
print('bundle-likes-OK')
" 2>/dev/null && p "Admin bundle profileFrames.likedArtworks has all 3 liked artworks" || f "Admin bundle likedArtworks unexpected: $BUNDLE"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════"
echo "  Artwork Like Endpoint Check: $PASS passed, $FAIL failed ($TOTAL total)"
echo "══════════════════════════════════════════════════════════"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
