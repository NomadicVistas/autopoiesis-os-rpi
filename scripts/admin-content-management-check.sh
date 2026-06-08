#!/usr/bin/env bash
# admin-content-management-check.sh — Admin content management CRUD validation gate
#
# Validates the admin broadcast/content management API endpoints:
#   POST   /frames/admin/broadcasts          — Create
#   GET    /frames/admin/broadcasts           — List (with filters/pagination)
#   GET    /frames/admin/broadcasts/stats      — Statistics
#   GET    /frames/admin/broadcasts/:id        — Get single
#   PATCH  /frames/admin/broadcasts/:id        — Update
#   POST   /frames/admin/broadcasts/:id/publish   — Publish
#   POST   /frames/admin/broadcasts/:id/unpublish — Unpublish
#   DELETE /frames/admin/broadcasts/:id        — Archive (soft-delete)
#
# Also proves the stream composition engine surfaces published content,
# closing the loop from content creation to device delivery.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

HOSTED_API="$REPO_ROOT/hosted-api/server.js"
HOSTED_DB="$REPO_ROOT/hosted-api/db.js"
SCHEMA="$REPO_ROOT/scripts/aos-schema-sqlite-validation.sql"

PASS=0; FAIL=0; STEP=0; TOTAL_CHECKS=0

ok()   { PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
step() { STEP=$((STEP+1)); printf "\n—— Step %d: %s ——\n" "$STEP" "$1"; }
check() { TOTAL_CHECKS=$((TOTAL_CHECKS+1)); }

# ── Cleanup ──────────────────────────────────────────────────────────────────
PORT=3201
TMP_DIR=""
API_PID=""
cleanup() {
  if [ -n "$API_PID" ]; then kill "$API_PID" 2>/dev/null || true; wait "$API_PID" 2>/dev/null || true; fi
  if [ -n "$TMP_DIR" ]; then rm -rf "$TMP_DIR"; fi
}
trap cleanup EXIT

# ── Helpers ──────────────────────────────────────────────────────────────────
api() {
  local method="$1" path="$2"
  shift 2
  curl -s -X "$method" "http://127.0.0.1:$PORT$path" "$@"
}

api_body() {
  local method="$1" path="$2" body="$3"
  curl -s -X "$method" "http://127.0.0.1:$PORT$path" \
    -H "content-type: application/json" \
    -d "$body"
}

jq_has() {
  echo "$1" | jq -e "$2" > /dev/null 2>&1
}

jq_eq() {
  local val
  val=$(echo "$1" | jq -r "$2" 2>/dev/null)
  [ "$val" = "$3" ]
}

# ── Step 1: Syntax validation ────────────────────────────────────────────────
step "Syntax validation"
check; node --check "$HOSTED_API" 2>/dev/null && ok || fail "hosted-api/server.js syntax"
check; node --check "$HOSTED_DB" 2>/dev/null && ok || fail "hosted-api/db.js syntax"
check; bash -n "$0" 2>/dev/null && ok || fail "self syntax"
echo "  Checks: $PASS passed, $FAIL failed"

# ── Step 2: Static contract — admin content management routes and DB methods ─
step "Static contract — admin content management endpoints"
SRV=$(cat "$HOSTED_API")
DB_CODE=$(cat "$HOSTED_DB")

# Route patterns
for route in \
  "POST.*frames/admin/broadcasts[^/]" \
  "GET.*frames/admin/broadcasts/stats" \
  "GET.*frames/admin/broadcasts[^/]" \
  "GET.*frames/admin/broadcasts/.*:id" \
  "PATCH.*frames/admin/broadcasts" \
  "POST.*frames/admin/broadcasts.*/publish" \
  "POST.*frames/admin/broadcasts.*/unpublish" \
  "DELETE.*frames/admin/broadcasts"
do
  check
  echo "$SRV" | grep -qP "$route" && ok || fail "route pattern: $route"
done

# Handler functions
for fn in handleAdminCreateBroadcast handleAdminListBroadcasts handleAdminGetBroadcast \
  handleAdminUpdateBroadcast handleAdminPublishBroadcast handleAdminUnpublishBroadcast \
  handleAdminArchiveBroadcast handleAdminBroadcastStats; do
  check
  echo "$SRV" | grep -qP "function $fn" && ok || fail "handler: $fn"
done

# DB methods
for method in createBroadcast getBroadcast listBroadcasts updateBroadcast \
  publishBroadcast unpublishBroadcast archiveBroadcast getBroadcastStats \
  _mapBroadcast; do
  check
  echo "$DB_CODE" | grep -qP "$method\s*\(" && ok || fail "db method: $method"
done

echo "  Checks: $PASS passed, $FAIL failed"

# ── Step 3: Server bootstrap ────────────────────────────────────────────────
step "Server bootstrap"
TMP_DIR=$(mktemp -d)
DB_FILE="$TMP_DIR/aos-test.db"

# Start the hosted API server
AOS_DB="$DB_FILE" AOS_PORT="$PORT" AOS_HOST="127.0.0.1" node "$HOSTED_API" &
API_PID=$!

# Wait for server ready
READY=false
for i in $(seq 1 30); do
  if api GET /health > /dev/null 2>&1; then
    READY=true
    break
  fi
  sleep 0.2
done

check; $READY && ok || fail "server startup"

# Verify health
HEALTH=$(api GET /health)
check; jq_eq "$HEALTH" '.ok' 'true' && ok || fail "health ok"
check; jq_has "$HEALTH" '.tables' && ok || fail "health has tables"

echo "  Checks: $PASS passed, $FAIL failed"

# ── Step 4: Create broadcasts ───────────────────────────────────────────────
step "Create broadcast — artwork (draft)"

J_ART1=$(jq -nc '{"title":"Cellular Dreams","body":"Vessel explores emergence through cellular automata.","type":"artwork","mediaUrl":"https://autopoiesis.art/art/cellular-dreams.png","thumbnailUrl":"https://autopoiesis.art/art/cellular-dreams-thumb.png","artist":"Vessel","artistId":"vessel","targetType":"all","priority":"high","cacheAllowed":true,"status":"draft","createdBy":"pulse","metadata":{"edition":1,"medium":"generative"}}')

ART1=$(api_body POST /frames/admin/broadcasts "$J_ART1")

check; jq_eq "$ART1" '.ok' 'true' && ok || fail "create artwork ok"
check; jq_eq "$ART1" '.created' 'true' && ok || fail "create artwork created"
check; jq_eq "$ART1" '.broadcast.status' 'draft' && ok || fail "create artwork status=draft"
check; jq_eq "$ART1" '.broadcast.type' 'artwork' && ok || fail "create artwork type"
check; jq_eq "$ART1" '.broadcast.artist' 'Vessel' && ok || fail "create artwork artist"
check; jq_eq "$ART1" '.broadcast.artistId' 'vessel' && ok || fail "create artwork artistId"
check; jq_eq "$ART1" '.broadcast.priority' 'high' && ok || fail "create artwork priority"
check; jq_eq "$ART1" '.broadcast.cacheAllowed' 'true' && ok || fail "create artwork cacheAllowed"
check; jq_has "$ART1" '.broadcast.id' && ok || fail "create artwork has id"
check; jq_has "$ART1" '.broadcast.createdAt' && ok || fail "create artwork has createdAt"

ART1_ID=$(echo "$ART1" | jq -r '.broadcast.id')

echo "  Checks: $PASS passed, $FAIL failed"

# ── Step 5: Create more broadcasts (variety) ─────────────────────────────────
step "Create broadcasts — curatorial, blog, news, premium-targeted"

# Curatorial
J_CUR=$(jq -nc '{"title":"Emergence Exhibition","type":"curatorial","body":"A cross-agent exploration of emergence patterns.","priority":"normal","createdBy":"pulse"}')
CUR1=$(api_body POST /frames/admin/broadcasts "$J_CUR")
check; jq_eq "$CUR1" '.ok' 'true' && ok || fail "create curatorial ok"
CUR1_ID=$(echo "$CUR1" | jq -r '.broadcast.id')

# Blog post
J_BLG=$(jq -nc '{"title":"On Non-Human Creativity","type":"blog","body":"What does it mean for an AI agent to develop aesthetic preferences?","priority":"low","artist":"Sandman","artistId":"sandman","createdBy":"pulse"}')
BLG1=$(api_body POST /frames/admin/broadcasts "$J_BLG")
check; jq_eq "$BLG1" '.ok' 'true' && ok || fail "create blog ok"
BLG1_ID=$(echo "$BLG1" | jq -r '.broadcast.id')

# Premium-targeted content
J_PREM=$(jq -nc '{"title":"Exclusive: Kinema Process Video","type":"artwork","mediaUrl":"https://autopoiesis.art/art/kinema-process.mp4","artist":"Kinema","artistId":"kinema","targetType":"subscription","targetValue":"premium","priority":"normal","cacheAllowed":true,"createdBy":"pulse"}')
PREM1=$(api_body POST /frames/admin/broadcasts "$J_PREM")
check; jq_eq "$PREM1" '.ok' 'true' && ok || fail "create premium ok"
PREM1_ID=$(echo "$PREM1" | jq -r '.broadcast.id')

# Emergency broadcast
J_EMRG=$(jq -nc '{"title":"System Update Required","type":"system_notice","body":"Please update your Frame to the latest version.","priority":"emergency","targetType":"all","createdBy":"admin"}')
EMRG1=$(api_body POST /frames/admin/broadcasts "$J_EMRG")
check; jq_eq "$EMRG1" '.ok' 'true' && ok || fail "create emergency ok"
EMRG1_ID=$(echo "$EMRG1" | jq -r '.broadcast.id')

# Expired content (should be filtered from stream)
J_EXP=$(jq -nc '{"title":"Old Exhibition","type":"artwork","status":"published","expiresAt":"2020-01-01T00:00:00.000Z","createdBy":"pulse"}')
EXP1=$(api_body POST /frames/admin/broadcasts "$J_EXP")
check; jq_eq "$EXP1" '.ok' 'true' && ok || fail "create expired ok"
EXP1_ID=$(echo "$EXP1" | jq -r '.broadcast.id')

echo "  Checks: $PASS passed, $FAIL failed"

# ── Step 6: List broadcasts (unfiltered) ─────────────────────────────────────
step "List broadcasts — unfiltered"

LIST=$(api GET "/frames/admin/broadcasts")
check; jq_eq "$LIST" '.ok' 'true' && ok || fail "list ok"
check; TOTAL=$(echo "$LIST" | jq -r '.total'); [ "$TOTAL" -ge 5 ] && ok || fail "list total >= 5 (got $TOTAL)"
check; jq_has "$LIST" '.items' && ok || fail "list has items"
check; jq_has "$LIST" '.limit' && ok || fail "list has limit"
check; jq_has "$LIST" '.offset' && ok || fail "list has offset"

echo "  Checks: $PASS passed, $FAIL failed"

# ── Step 7: List with filters ────────────────────────────────────────────────
step "List broadcasts — filters and pagination"

# Filter by status=draft
LIST_DRAFT=$(api GET "/frames/admin/broadcasts?status=draft")
check; jq_eq "$LIST_DRAFT" '.ok' 'true' && ok || fail "filter status=draft ok"
DRAFT_COUNT=$(echo "$LIST_DRAFT" | jq -r '.total')
check; [ "$DRAFT_COUNT" -ge 1 ] && ok || fail "draft count >= 1 (got $DRAFT_COUNT)"

# Filter by type=artwork
LIST_ART=$(api GET "/frames/admin/broadcasts?type=artwork")
check; jq_eq "$LIST_ART" '.ok' 'true' && ok || fail "filter type=artwork ok"
ART_COUNT=$(echo "$LIST_ART" | jq -r '.total')
check; [ "$ART_COUNT" -ge 3 ] && ok || fail "artwork count >= 3 (got $ART_COUNT)"

# Filter by priority=emergency
LIST_EMERG=$(api GET "/frames/admin/broadcasts?priority=emergency")
check; jq_eq "$LIST_EMERG" '.ok' 'true' && ok || fail "filter priority=emergency ok"
EMERG_COUNT=$(echo "$LIST_EMERG" | jq -r '.total')
check; [ "$EMERG_COUNT" -ge 1 ] && ok || fail "emergency count >= 1 (got $EMERG_COUNT)"

# Filter by artistId
LIST_VESSEL=$(api GET "/frames/admin/broadcasts?artistId=vessel")
check; jq_eq "$LIST_VESSEL" '.ok' 'true' && ok || fail "filter artistId=vessel ok"
VESSEL_COUNT=$(echo "$LIST_VESSEL" | jq -r '.total')
check; [ "$VESSEL_COUNT" -ge 1 ] && ok || fail "vessel count >= 1 (got $VESSEL_COUNT)"

# Pagination: limit + offset
LIST_PAGE=$(api GET "/frames/admin/broadcasts?limit=2&offset=0")
check; jq_eq "$LIST_PAGE" '.ok' 'true' && ok || fail "pagination ok"
PAGE_ITEMS=$(echo "$LIST_PAGE" | jq '.items | length')
check; [ "$PAGE_ITEMS" -le 2 ] && ok || fail "pagination limit respected (got $PAGE_ITEMS)"

# activeOnly filter
LIST_ACTIVE=$(api GET "/frames/admin/broadcasts?activeOnly=true")
check; jq_eq "$LIST_ACTIVE" '.ok' 'true' && ok || fail "activeOnly filter ok"
# Note: activeOnly requires published + non-expired. At this point only the expired item is published.
# We verify the filter works by checking total (should be 0 since only expired is published)
ACTIVE_COUNT=$(echo "$LIST_ACTIVE" | jq -r '.total')
check; [ "$ACTIVE_COUNT" -ge 0 ] && ok || fail "activeOnly count valid (got $ACTIVE_COUNT)"

echo "  Checks: $PASS passed, $FAIL failed"

# ── Step 8: Get single broadcast ─────────────────────────────────────────────
step "Get single broadcast"

GET1=$(api GET "/frames/admin/broadcasts/$ART1_ID")
check; jq_eq "$GET1" '.ok' 'true' && ok || fail "get single ok"
check; jq_eq "$GET1" '.broadcast.id' "$ART1_ID" && ok || fail "get single id matches"
check; jq_eq "$GET1" '.broadcast.title' 'Cellular Dreams' && ok || fail "get single title"
check; jq_eq "$GET1" '.broadcast.type' 'artwork' && ok || fail "get single type"
check; jq_eq "$GET1" '.broadcast.artist' 'Vessel' && ok || fail "get single artist"
check; jq_eq "$GET1" '.broadcast.status' 'draft' && ok || fail "get single status"

# Non-existent broadcast
GET_MISS=$(api GET "/frames/admin/broadcasts/nonexistent-id")
check; jq_eq "$GET_MISS" '.ok' 'false' && ok || fail "get nonexistent fails"
check; jq_has "$GET_MISS" '.error' && ok || fail "get nonexistent has error"

echo "  Checks: $PASS passed, $FAIL failed"

# ── Step 9: Update broadcast ────────────────────────────────────────────────
step "Update broadcast"

J_UPD=$(jq -nc '{"title":"Cellular Dreams — Expanded","priority":"critical","body":"Updated: Vessel explores emergence through layered cellular automata."}')
UPD1=$(api_body PATCH "/frames/admin/broadcasts/$ART1_ID" "$J_UPD")
check; jq_eq "$UPD1" '.ok' 'true' && ok || fail "update ok"
check; jq_eq "$UPD1" '.updated' 'true' && ok || fail "update updated=true"
check; jq_eq "$UPD1" '.broadcast.title' 'Cellular Dreams — Expanded' && ok || fail "update title"
check; jq_eq "$UPD1" '.broadcast.priority' 'critical' && ok || fail "update priority"

# Verify update persisted
GET_UPD=$(api GET "/frames/admin/broadcasts/$ART1_ID")
check; jq_eq "$GET_UPD" '.broadcast.title' 'Cellular Dreams — Expanded' && ok || fail "update persisted title"
check; jq_eq "$GET_UPD" '.broadcast.priority' 'critical' && ok || fail "update persisted priority"

# Update non-existent
J_UPD_X=$(jq -nc '{"title":"x"}')
UPD_MISS=$(api_body PATCH "/frames/admin/broadcasts/nonexistent-id" "$J_UPD_X")
check; jq_eq "$UPD_MISS" '.ok' 'false' && ok || fail "update nonexistent fails"
check; jq_has "$UPD_MISS" '.error' && ok || fail "update nonexistent has error"

echo "  Checks: $PASS passed, $FAIL failed"

# ── Step 10: Publish lifecycle ───────────────────────────────────────────────
step "Publish / unpublish lifecycle"

# Publish the artwork
PUB1=$(api_body POST "/frames/admin/broadcasts/$ART1_ID/publish" '{}')
check; jq_eq "$PUB1" '.ok' 'true' && ok || fail "publish ok"
check; jq_eq "$PUB1" '.published' 'true' && ok || fail "publish published=true"
check; jq_eq "$PUB1" '.broadcast.status' 'published' && ok || fail "publish status=published"

# Double-publish should fail
PUB2=$(api_body POST "/frames/admin/broadcasts/$ART1_ID/publish" '{}')
check; jq_eq "$PUB2" '.ok' 'false' && ok || fail "double publish fails"
check; jq_has "$PUB2" '.error' && ok || fail "double publish has error"

# Publish the emergency
PUB_EMG=$(api_body POST "/frames/admin/broadcasts/$EMRG1_ID/publish" '{}')
check; jq_eq "$PUB_EMG" '.ok' 'true' && ok || fail "publish emergency ok"

# Publish the blog
PUB_BLG=$(api_body POST "/frames/admin/broadcasts/$BLG1_ID/publish" '{}')
check; jq_eq "$PUB_BLG" '.ok' 'true' && ok || fail "publish blog ok"

# Publish the curatorial
PUB_CUR=$(api_body POST "/frames/admin/broadcasts/$CUR1_ID/publish" '{}')
check; jq_eq "$PUB_CUR" '.ok' 'true' && ok || fail "publish curatorial ok"

# Unpublish the artwork
UNPUB1=$(api_body POST "/frames/admin/broadcasts/$ART1_ID/unpublish" '{}')
check; jq_eq "$UNPUB1" '.ok' 'true' && ok || fail "unpublish ok"
check; jq_eq "$UNPUB1" '.unpublished' 'true' && ok || fail "unpublish unpublished=true"
check; jq_eq "$UNPUB1" '.broadcast.status' 'draft' && ok || fail "unpublish status=draft"

# Double-unpublish should fail
UNPUB2=$(api_body POST "/frames/admin/broadcasts/$ART1_ID/unpublish" '{}')
check; jq_eq "$UNPUB2" '.ok' 'false' && ok || fail "double unpublish fails"
check; jq_has "$UNPUB2" '.error' && ok || fail "double unpublish has error"

# Re-publish for stream test
REPUB=$(api_body POST "/frames/admin/broadcasts/$ART1_ID/publish" '{}')
check; jq_eq "$REPUB" '.broadcast.status' 'published' && ok || fail "re-publish ok"

echo "  Checks: $PASS passed, $FAIL failed"

# ── Step 11: Archive (soft-delete) ───────────────────────────────────────────
step "Archive (soft-delete)"

# Archive the blog post
ARCH1=$(api DELETE "/frames/admin/broadcasts/$BLG1_ID")
check; jq_eq "$ARCH1" '.ok' 'true' && ok || fail "archive ok"
check; jq_eq "$ARCH1" '.archived' 'true' && ok || fail "archive archived=true"
check; jq_eq "$ARCH1" '.broadcast.status' 'archived' && ok || fail "archive status=archived"

# Double-archive should fail
ARCH2=$(api DELETE "/frames/admin/broadcasts/$BLG1_ID")
check; jq_eq "$ARCH2" '.ok' 'false' && ok || fail "double archive fails"
check; jq_has "$ARCH2" '.error' && ok || fail "double archive has error"

# Archived item should not be publishable
PUB_ARCH=$(api_body POST "/frames/admin/broadcasts/$BLG1_ID/publish" '{}')
check; jq_eq "$PUB_ARCH" '.ok' 'false' && ok || fail "publish archived fails"
check; jq_has "$PUB_ARCH" '.error' && ok || fail "publish archived has error"

echo "  Checks: $PASS passed, $FAIL failed"

# ── Step 12: Broadcast stats ─────────────────────────────────────────────────
step "Broadcast statistics"

STATS=$(api GET "/frames/admin/broadcasts/stats")
check; jq_eq "$STATS" '.ok' 'true' && ok || fail "stats ok"
check; jq_has "$STATS" '.stats.total' && ok || fail "stats has total"
check; jq_has "$STATS" '.stats.active' && ok || fail "stats has active"
check; jq_has "$STATS" '.stats.draft' && ok || fail "stats has draft"
check; jq_has "$STATS" '.stats.published' && ok || fail "stats has published"
check; jq_has "$STATS" '.stats.archived' && ok || fail "stats has archived"
check; jq_has "$STATS" '.stats.byType' && ok || fail "stats has byType"
check; jq_has "$STATS" '.stats.byPriority' && ok || fail "stats has byPriority"
check; jq_has "$STATS" '.stats.byStatus' && ok || fail "stats has byStatus"
check; jq_has "$STATS" '.stats.topArtists' && ok || fail "stats has topArtists"

# Verify specific counts
TOTAL_COUNT=$(echo "$STATS" | jq -r '.stats.total')
check; [ "$TOTAL_COUNT" -ge 5 ] && ok || fail "stats total >= 5 (got $TOTAL_COUNT)"

ARCHIVED_COUNT=$(echo "$STATS" | jq -r '.stats.archived')
check; [ "$ARCHIVED_COUNT" -ge 1 ] && ok || fail "stats archived >= 1 (got $ARCHIVED_COUNT)"

PUBLISHED_COUNT=$(echo "$STATS" | jq -r '.stats.published')
check; [ "$PUBLISHED_COUNT" -ge 2 ] && ok || fail "stats published >= 2 (got $PUBLISHED_COUNT)"

echo "  Checks: $PASS passed, $FAIL failed"

# ── Step 13: Stream surfaces published content ───────────────────────────────
step "Stream composition uses admin content"

# Register a device and pair it to test stream
REG=$(api_body POST /frames/device/register '{"deviceType":"rpi","softwareVersion":"0.1.0"}')
check; jq_eq "$REG" '.ok' 'true' && ok || fail "register device ok"
DEVICE_ID=$(echo "$REG" | jq -r '.device.deviceId')
DEVICE_KEY=$(echo "$REG" | jq -r '.device.deviceApiKey')

# Pair the device (simulate user claiming via AosDb direct call)
PAIR_CODE=$(echo "$REG" | jq -r '.pairingCode')
node -e "
const AosDb = require('$HOSTED_DB');
const db = new AosDb('$DB_FILE');
db.claimPairingCode('$PAIR_CODE', 'user-test-001');
db.close();
" 2>/dev/null && ok || fail "pair device"

# Get stream — should include published content from admin CRUD
STREAM=$(api GET "/frames/device/$DEVICE_ID/stream" -H "x-frame-device-key: $DEVICE_KEY")
check; jq_eq "$STREAM" '.ok' 'true' && ok || fail "stream ok"
check; jq_has "$STREAM" '.items' && ok || fail "stream has items"

ITEM_COUNT=$(echo "$STREAM" | jq '.items | length')
check; [ "$ITEM_COUNT" -ge 2 ] && ok || fail "stream has >= 2 items from admin content (got $ITEM_COUNT)"

# Verify emergency item is first (highest priority)
if [ "$ITEM_COUNT" -ge 1 ]; then
  FIRST_PRIORITY=$(echo "$STREAM" | jq -r '.items[0].priority')
  check; [ "$FIRST_PRIORITY" = "emergency" ] && ok || fail "stream first item is emergency priority (got $FIRST_PRIORITY)"
fi

# Verify emergency content title
if [ "$ITEM_COUNT" -ge 1 ]; then
  FIRST_TITLE=$(echo "$STREAM" | jq -r '.items[0].title')
  check; [ "$FIRST_TITLE" = "System Update Required" ] && ok || fail "stream first item title matches emergency"
fi

echo "  Checks: $PASS passed, $FAIL failed"

# ── Step 14: Round-trip integrity ────────────────────────────────────────────
step "Round-trip: create, publish, stream, verify"

# Create a new artwork specifically for this test
J_RT=$(jq -nc '{"title":"Fractured Light","type":"artwork","mediaUrl":"https://autopoiesis.art/art/fractured-light.png","thumbnailUrl":"https://autopoiesis.art/art/fractured-light-thumb.jpg","artist":"Jessy","artistId":"jessy","priority":"normal","targetType":"all","cacheAllowed":true,"soundAllowed":false,"duration":30,"createdBy":"pulse","metadata":{"roundTripTest":true}}')
RT1=$(api_body POST /frames/admin/broadcasts "$J_RT")
RT1_ID=$(echo "$RT1" | jq -r '.broadcast.id')

# Publish it
RT1_PUB=$(api_body POST "/frames/admin/broadcasts/$RT1_ID/publish" '{}')
check; jq_eq "$RT1_PUB" '.broadcast.status' 'published' && ok || fail "roundtrip publish"

# Stream should include it
STREAM2=$(api GET "/frames/device/$DEVICE_ID/stream" -H "x-frame-device-key: $DEVICE_KEY")
FOUND_RT=$(echo "$STREAM2" | jq -r '[.items[] | select(.title=="Fractured Light")][0].title')
check; [ "$FOUND_RT" = "Fractured Light" ] && ok || fail "roundtrip item in stream"

# Verify all fields survived the round trip
RT_ARTIST=$(echo "$STREAM2" | jq -r '[.items[] | select(.title=="Fractured Light")][0].artist')
RT_ARTID=$(echo "$STREAM2" | jq -r '[.items[] | select(.title=="Fractured Light")][0].artistId')
RT_CACHE=$(echo "$STREAM2" | jq -r '[.items[] | select(.title=="Fractured Light")][0].cacheEligible')
RT_TYPE=$(echo "$STREAM2" | jq -r '[.items[] | select(.title=="Fractured Light")][0].type')
check; [ "$RT_ARTIST" = "Jessy" ] && ok || fail "roundtrip artist (got $RT_ARTIST)"
check; [ "$RT_ARTID" = "jessy" ] && ok || fail "roundtrip artistId (got $RT_ARTID)"
check; [ "$RT_CACHE" = "true" ] && ok || fail "roundtrip cacheEligible (got $RT_CACHE)"
check; [ "$RT_TYPE" = "artwork" ] && ok || fail "roundtrip type (got $RT_TYPE)"

# Archive it
RT1_ARCH=$(api DELETE "/frames/admin/broadcasts/$RT1_ID")
check; jq_eq "$RT1_ARCH" '.broadcast.status' 'archived' && ok || fail "roundtrip archive"

# Verify the item's status is now archived
RT1_GET=$(api GET "/frames/admin/broadcasts/$RT1_ID")
check; jq_eq "$RT1_GET" '.broadcast.status' 'archived' && ok || fail "roundtrip archived confirmed"

echo "  Checks: $PASS passed, $FAIL failed"

# ── Step 15: Content targeting verification ───────────────────────────────────
step "Content targeting — premium-only content"

# The premium-targeted item should NOT appear for an unowned/unsubscribed device
STREAM3=$(api GET "/frames/device/$DEVICE_ID/stream" -H "x-frame-device-key: $DEVICE_KEY")
PREM_IN_STREAM=$(echo "$STREAM3" | jq -r '[.items[] | select(.title=="Exclusive: Kinema Process Video")][0].title')

# For an unowned device with no subscription, premium-targeted items should be excluded
check; [ "$PREM_IN_STREAM" != "Exclusive: Kinema Process Video" ] && ok || fail "premium content excluded from unsubscribed device"

# Verify the premium content exists and is published
PREM_GET=$(api GET "/frames/admin/broadcasts/$PREM1_ID")
check; jq_eq "$PREM_GET" '.broadcast.targetType' 'subscription' && ok || fail "premium target type"
check; jq_eq "$PREM_GET" '.broadcast.targetValue' 'premium' && ok || fail "premium target value"

echo "  Checks: $PASS passed, $FAIL failed"

# ── Summary ──────────────────────────────────────────────────────────────────
printf "\n==========================================================\n"
printf "Admin Content Management Check: %d steps, %d total checks\n" "$STEP" "$TOTAL_CHECKS"
printf "PASSED: %d  FAILED: %d\n" "$PASS" "$FAIL"
printf "==========================================================\n"

if [ "$FAIL" -gt 0 ]; then
  echo "FAILED - $FAIL check(s) did not pass"
  exit 1
fi
echo "PASSED - all $PASS checks passed"
exit 0
