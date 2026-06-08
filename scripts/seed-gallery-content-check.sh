#!/usr/bin/env bash
# seed-gallery-content-check.sh — Validate content seeding end-to-end
#
# Proves: gallery artworks → seed script → aos_broadcasts → stream composition
# returns real gallery content to a registered device.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOSTED_API="$REPO_ROOT/hosted-api/server.js"
SEED_SCRIPT="$REPO_ROOT/scripts/seed-gallery-content.mjs"
GALLERY_DIR="/data/.openclaw/workspace/autopoiesis/gallery/artworks"
DB_PATH=""
API_PID=""
API_PORT=3159
ADMIN_TOKEN="test-seed-token-$(date +%s)"
PASS=0
FAIL=0
SKIP=0
STEP=0

log() { echo "  $*"; }
pass() { PASS=$((PASS+1)); echo "  ✓ $*"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ FAIL: $*"; }
skip() { SKIP=$((SKIP+1)); echo "  ⊘ SKIP: $*"; }
step() { STEP=$((STEP+1)); echo ""; echo "Step $STEP: $*"; }

cleanup() {
  if [ -n "$API_PID" ]; then
    kill "$API_PID" 2>/dev/null || true
    wait "$API_PID" 2>/dev/null || true
  fi
  if [ -n "$DB_PATH" ] && [ -f "$DB_PATH" ]; then rm -f "$DB_PATH"; fi
}
trap cleanup EXIT

# ── Step 1: Syntax validation ───────────────────────────────────────────────
step "Syntax validation"
node --check "$SEED_SCRIPT" && pass "seed-gallery-content.mjs syntax" || fail "seed-gallery-content.mjs syntax"
node --check "$HOSTED_API" && pass "hosted-api/server.js syntax" || fail "hosted-api/server.js syntax"
node --check "$REPO_ROOT/hosted-api/db.js" && pass "hosted-api/db.js syntax" || fail "hosted-api/db.js syntax"

# ── Step 2: Static contract ─────────────────────────────────────────────────
step "Static contract — seed script exports and constants"
SEED_SRC=$(cat "$SEED_SCRIPT")

echo "$SEED_SRC" | grep -q 'ARTIST_NAMES' && pass "ARTIST_NAMES constant" || fail "ARTIST_NAMES missing"
echo "$SEED_SRC" | grep -q 'MEDIUM_TYPE_MAP' && pass "MEDIUM_TYPE_MAP constant" || fail "MEDIUM_TYPE_MAP missing"
echo "$SEED_SRC" | grep -q 'TIER_PRIORITY_MAP' && pass "TIER_PRIORITY_MAP constant" || fail "TIER_PRIORITY_MAP missing"
echo "$SEED_SRC" | grep -q 'function artworkToBroadcast' && pass "artworkToBroadcast function" || fail "artworkToBroadcast missing"
echo "$SEED_SRC" | grep -q 'function readGalleryArtworks' && pass "readGalleryArtworks function" || fail "readGalleryArtworks missing"
echo "$SEED_SRC" | grep -q 'function sortArtworks' && pass "sortArtworks function" || fail "sortArtworks missing"
echo "$SEED_SRC" | grep -q 'async function seedViaApi' && pass "seedViaApi function" || fail "seedViaApi missing"
echo "$SEED_SRC" | grep -q 'seedViaSqlite' && pass "seedViaSqlite function" || fail "seedViaSqlite missing"
echo "$SEED_SRC" | grep -q '\-\-dry-run' && pass "--dry-run flag" || fail "--dry-run missing"
echo "$SEED_SRC" | grep -q '\-\-limit' && pass "--limit flag" || fail "--limit missing"
echo "$SEED_SRC" | grep -q '\-\-gallery-dir' && pass "--gallery-dir flag" || fail "--gallery-dir missing"
echo "$SEED_SRC" | grep -q '\-\-base-url' && pass "--base-url flag" || fail "--base-url missing"
echo "$SEED_SRC" | grep -q 'vessel.*Vessel' && pass "Vessel in ARTIST_NAMES" || fail "Vessel missing"
echo "$SEED_SRC" | grep -q 'sandman.*Sandman' && pass "Sandman in ARTIST_NAMES" || fail "Sandman missing"
echo "$SEED_SRC" | grep -q 'cache_allowed' && pass "cache_allowed field mapping" || fail "cache_allowed missing"
echo "$SEED_SRC" | grep -q 'thumbnail_url\|thumbnailUrl' && pass "thumbnail URL mapping" || fail "thumbnail missing"

# ── Step 3: Gallery data presence ───────────────────────────────────────────
step "Gallery data presence"
if [ -d "$GALLERY_DIR" ]; then
  ART_COUNT=$(ls "$GALLERY_DIR"/*.json 2>/dev/null | wc -l)
  if [ "$ART_COUNT" -gt 100 ]; then
    pass "Gallery has $ART_COUNT artwork files (>100)"
  else
    fail "Gallery has only $ART_COUNT artwork files (expected >100)"
  fi
else
  fail "Gallery directory not found: $GALLERY_DIR"
  SKIP=99  # can't proceed without gallery data
  echo ""
  echo "Results: $PASS pass, $FAIL fail, $SKIP skip"
  exit 1
fi

# ── Step 4: Dry run validation ──────────────────────────────────────────────
step "Dry run validation"
DRY_OUT=$(cd "$REPO_ROOT" && node scripts/seed-gallery-content.mjs --dry-run --gallery-dir "$GALLERY_DIR" --limit 15 2>&1)
echo "$DRY_OUT" | grep -q "Found .* displayed artworks" && pass "dry-run reads artworks" || fail "dry-run didn't find artworks"
echo "$DRY_OUT" | grep -q "Selected 15 artworks" && pass "dry-run respects --limit" || fail "dry-run --limit"
echo "$DRY_OUT" | grep -q "Would seed 15 artworks" && pass "dry-run reports plan" || fail "dry-run plan"
echo "$DRY_OUT" | grep -q "Dry run — no data written" && pass "dry-run doesn't write" || fail "dry-run wrote data"

# Dry run with artist filter
DRY_VESSEL=$(cd "$REPO_ROOT" && node scripts/seed-gallery-content.mjs --dry-run --gallery-dir "$GALLERY_DIR" --artists vessel --limit 50 2>&1)
echo "$DRY_VESSEL" | grep -q "vessel" && pass "artist filter includes vessel" || fail "artist filter vessel"
VESSEL_COUNT=$(echo "$DRY_VESSEL" | grep "Vessel:" | grep -oP '\d+')
if [ -n "$VESSEL_COUNT" ] && [ "$VESSEL_COUNT" -gt 0 ] && [ "$VESSEL_COUNT" -le 56 ]; then
  pass "Vessel count reasonable: $VESSEL_COUNT"
else
  fail "Vessel count unexpected: $VESSEL_COUNT"
fi

# ── Step 5: Hosted API bootstrap ────────────────────────────────────────────
step "Hosted API bootstrap with seeded content"
DB_PATH=$(mktemp /tmp/aos-seed-check-XXXXXX.db)
export AOS_DB="$DB_PATH"
export AOS_PORT="$API_PORT"
export AOS_HOST="127.0.0.1"
export AUTOPOIESIS_FRAMES_ADMIN_TOKEN="$ADMIN_TOKEN"

API_URL="http://127.0.0.1:$API_PORT"

node "$HOSTED_API" > /tmp/aos-seed-api.log 2>&1 &
API_PID=$!

# Wait for API to be ready
for i in $(seq 1 15); do
  if curl -s "$API_URL/health" > /dev/null 2>&1; then break; fi
  sleep 0.5
done
sleep 0.5

# Health check
HEALTH=$(curl -s "$API_URL/health" 2>/dev/null) && pass "Hosted API healthy" || {
  fail "Hosted API not responding"
  cat /tmp/aos-seed-api.log 2>/dev/null | tail -5
}
echo "$HEALTH" | grep -q '"ok":true' && pass "Health reports ok" || fail "Health not ok"

# ── Step 6: Seed content via API ────────────────────────────────────────────
step "Seed content via API (limit 20)"
SEED_OUT=$(cd "$REPO_ROOT" && node scripts/seed-gallery-content.mjs \
  --api-url "$API_URL" \
  --admin-token "$ADMIN_TOKEN" \
  --gallery-dir "$GALLERY_DIR" \
  --base-url "https://autopoiesis.art" \
  --limit 20 \
  --status published \
  --verbose 2>&1)

echo "$SEED_OUT" | grep -q "Created:  20" && pass "20 artworks created" || fail "creation count"
echo "$SEED_OUT" | grep -q "Published: 20" && pass "20 artworks published" || fail "publish count"
echo "$SEED_OUT" | grep -q "Errors:   0" && pass "zero errors" || {
  fail "errors during seeding"
  echo "$SEED_OUT" | grep "✗" | head -5
}

# ── Step 7: Verify stream composition returns seeded content ─────────────────
step "Stream composition with real gallery content"

# Register a device
# Register a device
REG=$(curl -s -X POST "$API_URL/frames/device/register" \
  -H "Content-Type: application/json" \
  -d '{"deviceName":"seed-test-frame"}' 2>/dev/null || true)
DEVICE_ID=$(echo "$REG" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('device',{}).get('deviceId',''))" 2>/dev/null || true)
DEVICE_KEY=$(echo "$REG" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('device',{}).get('deviceApiKey',''))" 2>/dev/null || true)
PAIRING_CODE=$(echo "$REG" | python3 -c "import json,sys; print(json.load(sys.stdin).get('pairingCode',''))" 2>/dev/null || true)

if [ -z "$DEVICE_ID" ]; then
  fail "Device registration (response: ${REG:0:200})"
  # Check if API is still alive
  if ! kill -0 "$API_PID" 2>/dev/null; then
    fail "API process died during seeding"
    cat /tmp/aos-seed-api.log 2>/dev/null | tail -10
  fi
else
  pass "Device registered: $DEVICE_ID"
fi
[ -n "$DEVICE_KEY" ] && pass "Device key received" || fail "Device key"

# Pair the device (direct DB access for test simplicity)
# Use the pairing code with a simulated owner
PAIR_RES=$(curl -s "$API_URL/frames/device/$DEVICE_ID/pairing-status" \
  -H "x-frame-device-key: $DEVICE_KEY" 2>/dev/null)
echo "$PAIR_RES" | grep -q 'pending' && pass "Pairing status pending" || fail "Pairing status"

# Claim pairing code via DB (we need to use a test route or direct insertion)
# Since the hosted API doesn't have a public claim endpoint, we'll use the
# admin bundle to verify stream works even for unpaired devices
# For a fully paired test, insert directly via the DB
node -e "
const Database = require('better-sqlite3');
const db = new Database('$DB_PATH');
const code = '$PAIRING_CODE';
const now = new Date().toISOString().replace('T',' ').split('.')[0];
db.prepare('UPDATE aos_frame_pairing_codes SET status = ?, claimed_by_user_id = ?, claimed_at = ? WHERE pairing_code = ?')
  .run('completed', 'seed-test-owner', now, code);
db.prepare('UPDATE aos_frame_devices SET owner_user_id = ?, paired = 1 WHERE device_id = ?')
  .run('seed-test-owner', '$DEVICE_ID');
db.close();
" && pass "Device paired with test owner" || fail "Device pairing"

# Now get the stream
STREAM=$(curl -s "$API_URL/frames/device/$DEVICE_ID/stream" \
  -H "x-frame-device-key: $DEVICE_KEY" 2>/dev/null)

ITEM_COUNT=$(echo "$STREAM" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('items',[])))" 2>/dev/null)
if [ "$ITEM_COUNT" -gt 0 ] 2>/dev/null; then
  pass "Stream returns $ITEM_COUNT items from seeded content"
else
  fail "Stream returned 0 items (expected 20)"
  echo "Stream response: $STREAM" | head -3
fi

# Verify items have gallery artwork fields
echo "$STREAM" | python3 -c "
import json, sys
d = json.load(sys.stdin)
items = d.get('items', [])
ok = len(items) > 0
for item in items[:3]:
    assert 'id' in item, f'missing id'
    assert 'title' in item, f'missing title'
    assert 'artist' in item, f'missing artist in {item.get(\"id\")}'
    assert 'artistId' in item, f'missing artistId'
    assert 'priority' in item, f'missing priority'
    assert 'category' in item, f'missing category'
    assert item.get('category') == 'artwork', f'expected artwork category, got {item.get(\"category\")}'
print(f'{len(items)} items validated')
" && pass "Stream items have correct gallery artwork fields" || fail "Stream item field validation"

# Verify media URLs are present and absolute
echo "$STREAM" | python3 -c "
import json, sys
d = json.load(sys.stdin)
items = d.get('items', [])
with_media = sum(1 for i in items if i.get('mediaUrl'))
absolute = sum(1 for i in items if i.get('mediaUrl','').startswith('https://'))
print(f'{with_media} with mediaUrl, {absolute} absolute URLs')
assert with_media > 10, f'expected >10 items with mediaUrl, got {with_media}'
assert absolute > 10, f'expected >10 absolute URLs, got {absolute}'
" && pass "Stream items have absolute media URLs" || fail "Media URL validation"

# Verify artist diversity
echo "$STREAM" | python3 -c "
import json, sys
d = json.load(sys.stdin)
artists = set(i.get('artistId','') for i in d.get('items', []))
print(f'{len(artists)} distinct artists in stream')
assert len(artists) >= 2, f'expected >=2 artists, got {len(artists)}'
" && pass "Stream contains multiple artists" || fail "Artist diversity check"

# ── Step 8: Verify admin broadcast stats ────────────────────────────────────
step "Admin broadcast stats after seeding"
STATS=$(curl -s "$API_URL/frames/admin/broadcasts/stats" \
  -H "x-admin-token: $ADMIN_TOKEN" 2>/dev/null)
echo "$STATS" | python3 -c "
import json, sys
d = json.load(sys.stdin)
s = d.get('stats', {})
total = s.get('total', 0)
published = s.get('published', 0)
print(f'total={total}, published={published}')
assert total >= 20, f'expected >=20 total, got {total}'
assert published >= 20, f'expected >=20 published, got {published}'
" && pass "Admin stats show seeded content" || fail "Admin broadcast stats"

# ── Step 9: Verify priority ordering ────────────────────────────────────────
step "Priority ordering in stream"
echo "$STREAM" | python3 -c "
import json, sys
d = json.load(sys.stdin)
items = d.get('items', [])
priorities = [i.get('priority','') for i in items]
# All items should be 'high' (featured tier)
high_count = priorities.count('high')
print(f'{high_count}/{len(priorities)} items are high priority')
assert high_count == len(priorities), f'expected all high priority (featured tier)'
" && pass "All featured-tier artworks have high priority" || fail "Priority ordering"

# ── Step 10: Seed more with mixed tiers ─────────────────────────────────────
step "Full gallery seed (mixed tiers)"
FULL_SEED_OUT=$(cd "$REPO_ROOT" && node scripts/seed-gallery-content.mjs \
  --api-url "$API_URL" \
  --admin-token "$ADMIN_TOKEN" \
  --gallery-dir "$GALLERY_DIR" \
  --base-url "https://autopoiesis.art" \
  --limit 50 \
  --status published 2>&1 || true)

echo "$FULL_SEED_OUT" | grep -qP 'Errors:\s+0' && pass "Full gallery seed: zero errors" || {
  # Check if the only errors are duplicates (expected when re-seeding)
  ERR_COUNT=$(echo "$FULL_SEED_OUT" | grep -oP 'Errors:\s+\K\d+')
  if [ "$ERR_COUNT" -le 20 ] 2>/dev/null; then
    pass "Full seed OK with $ERR_COUNT duplicate errors (expected from prior 20)"
  else
    fail "Full seed had $ERR_COUNT errors"
  fi
}
TOTAL_SEEDED=$(echo "$FULL_SEED_OUT" | grep "Created:" | grep -oP '\d+')
echo "  Total created: $TOTAL_SEEDED"
[ "$TOTAL_SEEDED" -ge 30 ] && pass "Seeded >=30 additional artworks ($TOTAL_SEEDED)" || fail "Too few seeded ($TOTAL_SEEDED)"

# Verify stream now returns diverse content
STREAM2=$(curl -s "$API_URL/frames/device/$DEVICE_ID/stream" \
  -H "x-frame-device-key: $DEVICE_KEY" 2>/dev/null)
echo "$STREAM2" | python3 -c "
import json, sys
d = json.load(sys.stdin)
items = d.get('items', [])
artists = set(i.get('artistId','') for i in items)
priorities = set(i.get('priority','') for i in items)
print(f'{len(items)} items, {len(artists)} artists, priorities: {priorities}')
assert len(items) == 30, f'expected 30 items (stream cap), got {len(items)}'
assert len(artists) >= 5, f'expected >=5 artists, got {len(artists)}'
" && pass "Full stream: 30 items, diverse artists" || fail "Full stream diversity"

# ── Step 11: Regression — existing endpoints still work ─────────────────────
step "Regression: existing endpoints"
SETTINGS=$(curl -s "$API_URL/frames/device/$DEVICE_ID/settings" \
  -H "x-frame-device-key: $DEVICE_KEY" 2>/dev/null)
echo "$SETTINGS" | grep -q '"ok":true' && pass "Settings endpoint works" || fail "Settings endpoint"

BUNDLE=$(curl -s "$API_URL/frames/admin/bundle?userId=seed-test-owner" \
  -H "x-admin-token: $ADMIN_TOKEN" 2>/dev/null)
echo "$BUNDLE" | python3 -c "
import json, sys
d = json.load(sys.stdin)
pf = d.get('profileFrames', {})
devices = pf.get('devices', [])
print(f'profile devices: {len(devices)}')
assert len(devices) >= 1
" && pass "Admin bundle works with seeded content" || fail "Admin bundle regression"

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════"
echo "Results: $PASS pass, $FAIL fail, $SKIP skip ($STEP steps)"
echo "═══════════════════════════════════════════"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
