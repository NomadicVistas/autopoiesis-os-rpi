#!/usr/bin/env bash
# stream-categories-filter-check.sh — Validate streamCategories wiring to getStreamContent
#
# Tests that user's streamCategories preference is respected in stream composition:
#   - Null/undefined streamCategories returns all content types
#   - Explicit categories filter non-matching content out
#   - Emergency/critical items bypass category filter
#   - Mixed categories return only matching types
set -uo pipefail

REPO="/data/.openclaw/workspace/autopoiesis-os-rpi"
cd "$REPO"

PASS=0; FAIL=0; STEP=0; TOTAL_CHECKS=0

check() {
  local desc="$1" actual="$2" expected="$3"
  TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  ✗ $desc: expected '$expected', got '$actual'"
  fi
}

check_gt() {
  local desc="$1" actual="$2" threshold="$3"
  TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
  if [[ "$actual" -gt "$threshold" ]] 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  ✗ $desc: expected > $threshold, got '$actual'"
  fi
}

step() { STEP=$((STEP + 1)); echo ""; echo "── Step $STEP: $1 ──"; }

# Helper: extract JSON field via node
jf() { node -e "const d=[];process.stdin.on('data',c=>d.push(c));process.stdin.on('end',()=>{$2})" <<< "$1"; }

# ── Step 1: Syntax validation ──
step "Syntax validation"
node --check hosted-api/server.js 2>&1; check "server.js syntax" $? 0
node --check hosted-api/db.js 2>&1; check "db.js syntax" $? 0

# ── Step 2: Static contract ──
step "Static contract: streamCategories wiring"
FOUND=0; grep -q "streamCategories.*ownerPrefs.preferences.streamCategories" hosted-api/server.js && FOUND=1
check "server.js extracts streamCategories" "$FOUND" 1
FOUND=0; grep -q "streamCategories," hosted-api/server.js && FOUND=1
check "server.js passes streamCategories to getStreamContent" "$FOUND" 1
FOUND=0; grep -q "categorySet" hosted-api/db.js && FOUND=1
check "db.js has categorySet filter" "$FOUND" 1
FOUND=0; grep -q "_broadcastTypeToCategory(row.type)" hosted-api/db.js && FOUND=1
check "db.js uses _broadcastTypeToCategory in category filter" "$FOUND" 1
FOUND=0; grep -q "rank >= 400" hosted-api/db.js && FOUND=1
check "db.js emergency bypass" "$FOUND" 1

# ── Step 3: Server bootstrap ──
step "Server bootstrap"
PORT=$((30000 + RANDOM % 10000))
DB_PATH="/tmp/aos-stream-cat-$$-$RANDOM.db"
ADMIN_TOKEN="test-admin-cat-$$"
export AUTOPOIESIS_FRAMES_ADMIN_TOKEN="$ADMIN_TOKEN"

AOS_DB="$DB_PATH" AOS_PORT="$PORT" node hosted-api/server.js > /tmp/aos-cat-server.log 2>&1 &
SERVER_PID=$!

READY=0
for i in $(seq 1 20); do
  if curl -s --max-time 2 "http://127.0.0.1:$PORT/health" 2>/dev/null | grep -q '"ok":true'; then
    READY=1; break
  fi
  sleep 0.5
done
check "Server health OK" "$READY" 1

cleanup() { kill "$SERVER_PID" 2>/dev/null || true; rm -f "$DB_PATH" /tmp/aos-cat-server.log; }
trap cleanup EXIT

AUTH="Authorization: Bearer $ADMIN_TOKEN"
API="http://127.0.0.1:$PORT"

# ── Step 4: Seed content with mixed types ──
step "Seed content with mixed types"

seed_broadcast() {
  curl -s -X POST "$API/frames/admin/broadcasts" -H "$AUTH" -H "Content-Type: application/json" -d "$1"
}

# Create broadcasts of different types
seed_broadcast '{"title":"Artwork 1","type":"artwork","artistId":"vessel-001","artist":"Vessel","priority":"normal","mediaUrl":"https://example.com/art1.png"}' > /dev/null
seed_broadcast '{"title":"Artwork 2","type":"artwork","artistId":"vessel-001","artist":"Vessel","priority":"normal","mediaUrl":"https://example.com/art2.png"}' > /dev/null
seed_broadcast '{"title":"Artwork 3","type":"artwork","artistId":"kinema-003","artist":"Kinema","priority":"normal","mediaUrl":"https://example.com/art3.png"}' > /dev/null
seed_broadcast '{"title":"Blog Post 1","type":"blog","priority":"normal","body":"Blog content 1"}' > /dev/null
seed_broadcast '{"title":"Blog Post 2","type":"blog","priority":"normal","body":"Blog content 2"}' > /dev/null
seed_broadcast '{"title":"Curatorial Note","type":"curatorial","priority":"normal","body":"Exhibition notes"}' > /dev/null
seed_broadcast '{"title":"News Flash","type":"news","priority":"normal"}' > /dev/null
seed_broadcast '{"title":"Emergency Alert","type":"broadcast_message","priority":"emergency"}' > /dev/null

# Publish all drafts
DRAFT_JSON=$(curl -s "$API/frames/admin/broadcasts?status=draft" -H "$AUTH")
DRAFT_IDS=$(echo "$DRAFT_JSON" | node -e "const d=[];process.stdin.on('data',c=>d.push(c));process.stdin.on('end',()=>{const j=JSON.parse(d.join(''));(j.items||[]).forEach(b=>console.log(b.id))})")

PUBLISHED=0
for id in $DRAFT_IDS; do
  R=$(curl -s -X PATCH "$API/frames/admin/broadcasts/$id" -H "$AUTH" -H "Content-Type: application/json" -d '{"status":"published"}')
  if echo "$R" | grep -q '"ok":true'; then PUBLISHED=$((PUBLISHED + 1)); fi
done
check_gt "Published broadcasts" "$PUBLISHED" 5

# ── Step 5: Register and pair device ──
step "Register and pair device"

REG=$(curl -s -X POST "$API/frames/device/register" -H "Content-Type: application/json" -d '{"softwareVersion":"0.1.0"}')
DEVICE_ID=$(echo "$REG" | node -e "const d=[];process.stdin.on('data',c=>d.push(c));process.stdin.on('end',()=>console.log(JSON.parse(d.join('')).device.deviceId))")
DEVICE_KEY=$(echo "$REG" | node -e "const d=[];process.stdin.on('data',c=>d.push(c));process.stdin.on('end',()=>console.log(JSON.parse(d.join('')).device.deviceApiKey))")
PAIRING_CODE=$(echo "$REG" | node -e "const d=[];process.stdin.on('data',c=>d.push(c));process.stdin.on('end',()=>console.log(JSON.parse(d.join('')).pairingCode))")

OWNER_ID="user-cat-test-$$"

# Create subscription
curl -s -X POST "$API/frames/admin/subscriptions" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"userId\":\"$OWNER_ID\",\"plan\":\"frames_premium\"}" > /dev/null

# Pair device via direct DB call (no HTTP endpoint exists yet)
PAIR_RESULT=$(node -e "const AosDb=require('$REPO/hosted-api/db.js');const db=new AosDb('$DB_PATH');console.log(JSON.stringify(db.claimPairingCode('$PAIRING_CODE','$OWNER_ID')))")
PAIR_OK=0
if echo "$PAIR_RESULT" | grep -q '"ok":true'; then PAIR_OK=1; fi
check "Device paired to owner" "$PAIR_OK" 1

# ── Step 6: Baseline stream (no categories filter) ──
step "Baseline stream — no category filter"

stream_call() {
  curl -s "$API/frames/device/$DEVICE_ID/stream" -H "X-Frame-Device-Key: $DEVICE_KEY"
}

BASELINE=$(stream_call)
BASELINE_COUNT=$(echo "$BASELINE" | node -e "const d=[];process.stdin.on('data',c=>d.push(c));process.stdin.on('end',()=>{const j=JSON.parse(d.join(''));console.log(j.items?.length??0)})")
check_gt "Baseline has content" "$BASELINE_COUNT" 5

HAS_ARTWORK=$(echo "$BASELINE" | node -e "const d=[];process.stdin.on('data',c=>d.push(c));process.stdin.on('end',()=>{const j=JSON.parse(d.join(''));console.log(j.items?.some(i=>i.category==='artwork')?1:0)})")
check "Baseline includes artwork" "$HAS_ARTWORK" 1

HAS_BLOG=$(echo "$BASELINE" | node -e "const d=[];process.stdin.on('data',c=>d.push(c));process.stdin.on('end',()=>{const j=JSON.parse(d.join(''));console.log(j.items?.some(i=>i.category==='blog')?1:0)})")
check "Baseline includes blog" "$HAS_BLOG" 1

HAS_NEWS=$(echo "$BASELINE" | node -e "const d=[];process.stdin.on('data',c=>d.push(c));process.stdin.on('end',()=>{const j=JSON.parse(d.join(''));console.log(j.items?.some(i=>i.category==='news')?1:0)})")
check "Baseline includes news" "$HAS_NEWS" 1

# ── Step 7: Set streamCategories = [artwork] only ──
step "Set streamCategories = [artwork] — should filter out blog/news"

set_prefs() {
  curl -s -X PATCH "$API/frames/admin/users/$OWNER_ID/preferences" \
    -H "$AUTH" -H "Content-Type: application/json" -d "$1" > /dev/null
}

set_prefs '{"streamCategories":["artwork"],"activeArtists":[]}'

ARTWORK_ONLY=$(stream_call)
ALL_ART_OR_EMER=$(echo "$ARTWORK_ONLY" | node -e "const d=[];process.stdin.on('data',c=>d.push(c));process.stdin.on('end',()=>{const j=JSON.parse(d.join(''));const ok=(j.items||[]).every(i=>i.category==='artwork'||i.priority==='emergency');console.log(ok?1:0)})")
check "All items are artwork or emergency" "$ALL_ART_OR_EMER" 1

HAS_BLOG_F=$(echo "$ARTWORK_ONLY" | node -e "const d=[];process.stdin.on('data',c=>d.push(c));process.stdin.on('end',()=>{const j=JSON.parse(d.join(''));console.log(j.items?.some(i=>i.category==='blog')?1:0)})")
check "Blog excluded when filtered to artwork" "$HAS_BLOG_F" 0

HAS_NEWS_F=$(echo "$ARTWORK_ONLY" | node -e "const d=[];process.stdin.on('data',c=>d.push(c));process.stdin.on('end',()=>{const j=JSON.parse(d.join(''));console.log(j.items?.some(i=>i.category==='news')?1:0)})")
check "News excluded when filtered to artwork" "$HAS_NEWS_F" 0

HAS_EMER=$(echo "$ARTWORK_ONLY" | node -e "const d=[];process.stdin.on('data',c=>d.push(c));process.stdin.on('end',()=>{const j=JSON.parse(d.join(''));console.log(j.items?.some(i=>i.priority==='emergency')?1:0)})")
check "Emergency bypasses category filter" "$HAS_EMER" 1

# ── Step 8: Set streamCategories = [artwork, blog] ──
step "Set streamCategories = [artwork, blog] — mixed categories"

set_prefs '{"streamCategories":["artwork","blog"],"activeArtists":[]}'

MIXED=$(stream_call)
HAS_ART_M=$(echo "$MIXED" | node -e "const d=[];process.stdin.on('data',c=>d.push(c));process.stdin.on('end',()=>{const j=JSON.parse(d.join(''));console.log(j.items?.some(i=>i.category==='artwork')?1:0)})")
check "Mixed stream includes artwork" "$HAS_ART_M" 1

HAS_BLOG_M=$(echo "$MIXED" | node -e "const d=[];process.stdin.on('data',c=>d.push(c));process.stdin.on('end',()=>{const j=JSON.parse(d.join(''));console.log(j.items?.some(i=>i.category==='blog')?1:0)})")
check "Mixed stream includes blog" "$HAS_BLOG_M" 1

HAS_NEWS_M=$(echo "$MIXED" | node -e "const d=[];process.stdin.on('data',c=>d.push(c));process.stdin.on('end',()=>{const j=JSON.parse(d.join(''));console.log(j.items?.some(i=>i.category==='news')?1:0)})")
check "Mixed stream excludes news" "$HAS_NEWS_M" 0

# ── Step 9: Empty categories array = all categories ──
step "Empty streamCategories array — should return all"

set_prefs '{"streamCategories":[],"activeArtists":[]}'

ALL_STREAM=$(stream_call)
ALL_COUNT=$(echo "$ALL_STREAM" | node -e "const d=[];process.stdin.on('data',c=>d.push(c));process.stdin.on('end',()=>{const j=JSON.parse(d.join(''));console.log(j.items?.length??0)})")
check "Empty categories returns all content" "$ALL_COUNT" "$BASELINE_COUNT"

# ── Step 10: Unpaired device (no owner) — returns all ──
step "Unpaired device — no preferences, returns all"

REG2=$(curl -s -X POST "$API/frames/device/register" -H "Content-Type: application/json" -d '{"softwareVersion":"0.1.0"}')
DEVICE_ID_2=$(echo "$REG2" | node -e "const d=[];process.stdin.on('data',c=>d.push(c));process.stdin.on('end',()=>console.log(JSON.parse(d.join('')).device.deviceId))")
DEVICE_KEY_2=$(echo "$REG2" | node -e "const d=[];process.stdin.on('data',c=>d.push(c));process.stdin.on('end',()=>console.log(JSON.parse(d.join('')).device.deviceApiKey))")

# Unpaired devices can't call stream (auth requires paired)
# So we test by removing the owner and calling with the original device
# Actually: let's just verify the device is unpaired and stream still works
NO_OWNER=$(curl -s "$API/frames/device/$DEVICE_ID_2/stream" -H "X-Frame-Device-Key: $DEVICE_KEY_2")
NO_OWNER_OK=$(echo "$NO_OWNER" | node -e "const d=[];process.stdin.on('data',c=>d.push(c));process.stdin.on('end',()=>{const j=JSON.parse(d.join(''));console.log(j.ok===false?'blocked':'ok')})")
check "Unpaired device stream returns error (auth)" "$NO_OWNER_OK" "blocked"

# ── Step 11: Regression ──
step "Regression — settings and admin bundle"

SETTINGS=$(curl -s "$API/frames/device/$DEVICE_ID/settings" -H "X-Frame-Device-Key: $DEVICE_KEY")
S_OK=0; echo "$SETTINGS" | grep -q '"ok":true' && S_OK=1
check "Settings endpoint OK" "$S_OK" 1

BUNDLE=$(curl -s "$API/frames/admin/bundle?userId=$OWNER_ID" -H "$AUTH")
B_OK=0; echo "$BUNDLE" | grep -q '"ok":true' && B_OK=1
check "Admin bundle OK" "$B_OK" 1

# ── Summary ──
echo ""
echo "══════════════════════════════════════════════════════"
echo "  stream-categories-filter-check: $PASS passed, $FAIL failed ($TOTAL_CHECKS checks, $STEP steps)"
echo "══════════════════════════════════════════════════════"

[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
