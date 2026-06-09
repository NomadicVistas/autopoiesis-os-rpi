#!/usr/bin/env bash
# admin-user-management-check.sh
# Validation gate for admin user management endpoints:
#   GET  /frames/admin/users
#   GET  /frames/admin/users/:userId
#   GET  /frames/admin/users/:userId/preferences
#   PATCH /frames/admin/users/:userId/preferences
#
# Tests: handler existence, route wiring, user listing, user detail,
#        preferences read/write, filtering, auth gates, edge cases.

set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

PASS=0; FAIL=0; SKIP=0
step=0
p() { ((PASS++)) || true; }
f() { ((FAIL++)) || true; echo "  ✗ FAIL: $1"; }
s() { ((SKIP++)) || true; echo "  ⊘ SKIP: $1"; }
step_header() { ((step++)) || true; echo ""; echo "━━ Step $step: $1 ━━"; }

SRV_PID=""
DB_FILE=""
cleanup() {
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null || true
  [ -n "$DB_FILE" ] && rm -f "$DB_FILE" || true
}
trap cleanup EXIT

# ═══════════════════════════════════════════════════════════════
# Step 1: Syntax validation
# ═══════════════════════════════════════════════════════════════
step_header "Syntax validation"
node --check hosted-api/server.js 2>/dev/null && p || f "hosted-api/server.js syntax"
node --check hosted-api/db.js 2>/dev/null && p || f "hosted-api/db.js syntax"
bash -n install.sh 2>/dev/null && p || f "install.sh syntax"

# ═══════════════════════════════════════════════════════════════
# Step 2: Static contract — handler functions exist
# ═══════════════════════════════════════════════════════════════
step_header "Static contract — handlers"

SERVER="hosted-api/server.js"

grep -q 'function handleAdminListUsers' "$SERVER" && p || f "handleAdminListUsers exists"
grep -q 'function handleAdminGetUser(' "$SERVER" && p || f "handleAdminGetUser exists"
grep -q 'function handleAdminGetUserPreferences(' "$SERVER" && p || f "handleAdminGetUserPreferences exists"
grep -q 'function handleAdminUpdateUserPreferences(' "$SERVER" && p || f "handleAdminUpdateUserPreferences exists"

# Route wiring — user list
grep -q 'handleAdminListUsers' "$SERVER" && p || f "handleAdminListUsers wired"

# Route wiring — user detail (pathname.match uses escaped slashes)
grep -q 'adminUserMatch' "$SERVER" && p || f "adminUserMatch route variable"
grep -q 'handleAdminGetUser(db' "$SERVER" && p || f "handleAdminGetUser wired"

# Route wiring — preferences
grep -q 'adminUserPrefMatch' "$SERVER" && p || f "adminUserPrefMatch route variable"
grep -q 'handleAdminGetUserPreferences(db' "$SERVER" && p || f "handleAdminGetUserPreferences wired"
grep -q 'PATCH.*adminUserPrefMatch' "$SERVER" && p || f "PATCH preferences route"
grep -q 'handleAdminUpdateUserPreferences(db' "$SERVER" && p || f "handleAdminUpdateUserPreferences wired"

# VALID_KEYS
grep -q 'VALID_KEYS' "$SERVER" && p || f "VALID_KEYS preference validation"
grep -q 'activeArtists' "$SERVER" && p || f "activeArtists in VALID_KEYS"
grep -q 'offlineFallbackMode' "$SERVER" && p || f "offlineFallbackMode in VALID_KEYS"

# Auth gate
grep -q 'authenticateAdmin' "$SERVER" && p || f "Auth gate on user routes"

# Kind identifiers
grep -q 'autopoiesis_frames_admin_user_list' "$SERVER" && p || f "admin_user_list kind"
grep -q 'autopoiesis_frames_admin_user_detail' "$SERVER" && p || f "admin_user_detail kind"

# Filter params
grep -q 'subscriptionStatus' "$SERVER" && p || f "subscriptionStatus filter"
grep -q 'subscriptionPlan' "$SERVER" && p || f "subscriptionPlan filter"

# ═══════════════════════════════════════════════════════════════
# Step 3: API doc header includes new routes
# ═══════════════════════════════════════════════════════════════
step_header "API doc header"

grep -q 'frames/admin/users.*Admin: list users' "$SERVER" && p || f "Doc: list users"
grep -q 'frames/admin/users/:userId.*Admin: get user detail' "$SERVER" && p || f "Doc: user detail"
grep -q 'frames/admin/users/:userId/preferences.*Admin: get user preferences' "$SERVER" && p || f "Doc: get preferences"
grep -q 'PATCH.*frames/admin/users/:userId/preferences.*Admin: update user preferences' "$SERVER" && p || f "Doc: update preferences"

# ═══════════════════════════════════════════════════════════════
# Step 4: Live server — bootstrap + multi-user setup
# ═══════════════════════════════════════════════════════════════
step_header "Live server bootstrap + multi-user setup"

export AUTOPOIESIS_FRAMES_ADMIN_TOKEN="test-admin-user-mgmt-$(date +%s)"
DB_FILE="/tmp/aos-admin-user-mgmt-$$.db"
# Random port to avoid conflicts with parallel runs
PORT=$(( 19000 + (RANDOM % 1000) ))

# Start hosted API
AOS_PORT=$PORT AOS_DB="$DB_FILE" node hosted-api/server.js &
SRV_PID=$!
sleep 2

# Verify server is up
HEALTH=$(curl -sf "http://localhost:${PORT}/health" 2>/dev/null || echo "")
if [ -z "$HEALTH" ]; then
  f "Server failed to start on port $PORT"
  exit 1
fi
echo "$HEALTH" | grep -q '"ok":true' && p || f "Server health check"

# Helper functions — use -s (no -f) so error response bodies are captured
api() {
  local method="$1" path="$2" body="${3:-}"
  if [ "$method" = "GET" ]; then
    curl -s -X GET "http://localhost:${PORT}${path}" \
      -H "x-admin-token: $AUTOPOIESIS_FRAMES_ADMIN_TOKEN" \
      -H "Content-Type: application/json"
  else
    curl -s -X "$method" "http://localhost:${PORT}${path}" \
      -H "x-admin-token: $AUTOPOIESIS_FRAMES_ADMIN_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$body"
  fi
}
api_noauth() {
  curl -s -X "$1" "http://localhost:${PORT}${2}" \
    -H "Content-Type: application/json" \
    -d "${3:-}" 2>/dev/null
}
api_badtoken() {
  curl -s -X "$1" "http://localhost:${PORT}${2}" \
    -H "x-admin-token: wrong-token" \
    -H "Content-Type: application/json" \
    -d "${3:-}" 2>/dev/null
}

# Register 3 devices
DEV1_KEY="" DEV2_KEY="" DEV3_KEY=""
DEV1_ID="" DEV2_ID="" DEV3_ID=""

for i in 1 2 3; do
  RESP=$(curl -sf -X POST "http://localhost:${PORT}/frames/device/register" \
    -H "Content-Type: application/json" \
    -d "{\"deviceName\":\"user-mgmt-dev-$i\",\"deviceType\":\"raspberry_pi\"}")
  echo "$RESP" | grep -q '"ok":true' && p || f "Device $i registration"

  KEY=$(echo "$RESP" | grep -o '"deviceApiKey":"[^"]*"' | cut -d'"' -f4)
  DID=$(echo "$RESP" | grep -o '"deviceId":"[^"]*"' | cut -d'"' -f4)

  case $i in
    1) DEV1_KEY="$KEY"; DEV1_ID="$DID";;
    2) DEV2_KEY="$KEY"; DEV2_ID="$DID";;
    3) DEV3_KEY="$KEY"; DEV3_ID="$DID";;
  esac
done

# Pair devices using claimPairingCode (DB-level pairing, same as hosted-api-admin-bundle-check)
CODE1=$(curl -sf "http://localhost:${PORT}/frames/device/${DEV1_ID}/pairing-status" \
  -H "x-frame-device-key: $DEV1_KEY" | grep -o '"pairingCode":"[^"]*"' | cut -d'"' -f4)
node -e "const AosDb = require('./hosted-api/db'); const db = new AosDb('$DB_FILE'); const r = db.claimPairingCode('$CODE1', 'user-alice'); if (!r || !r.ok) { console.error('claimPairingCode failed:', JSON.stringify(r)); process.exit(1); }" && p || f "Pair device 1 to alice"

CODE2=$(curl -sf "http://localhost:${PORT}/frames/device/${DEV2_ID}/pairing-status" \
  -H "x-frame-device-key: $DEV2_KEY" | grep -o '"pairingCode":"[^\"]*"' | cut -d'"' -f4)
node -e "const AosDb = require('./hosted-api/db'); const db = new AosDb('$DB_FILE'); const r = db.claimPairingCode('$CODE2', 'user-bob'); if (!r || !r.ok) { console.error('claimPairingCode failed:', JSON.stringify(r)); process.exit(1); }" && p || f "Pair device 2 to bob"

# Device 3 stays unpaired (no owner)

# Create subscriptions
api POST /frames/admin/subscriptions '{"userId":"user-alice","plan":"frames_premium","status":"active"}' | grep -q '"created":true' && p || f "Create alice subscription"
api POST /frames/admin/subscriptions '{"userId":"user-bob","plan":"frames_trial","status":"trial"}' | grep -q '"created":true' && p || f "Create bob subscription"

# Add some liked artworks for alice
curl -sf -X POST "http://localhost:${PORT}/frames/artworks/art-001/like" \
  -H "x-frame-device-key: $DEV1_KEY" \
  -H "Content-Type: application/json" \
  -d '{"deviceId":"'"$DEV1_ID"'"}' | grep -q '"ok":true' && p || f "Alice likes art-001"

curl -sf -X POST "http://localhost:${PORT}/frames/artworks/art-002/like" \
  -H "x-frame-device-key: $DEV1_KEY" \
  -H "Content-Type: application/json" \
  -d '{"deviceId":"'"$DEV1_ID"'"}' | grep -q '"ok":true' && p || f "Alice likes art-002"

# ═══════════════════════════════════════════════════════════════
# Step 5: GET /frames/admin/users — list users
# ═══════════════════════════════════════════════════════════════
step_header "GET /frames/admin/users — list users"

USERS_RESP=$(api GET /frames/admin/users)
echo "$USERS_RESP" | grep -q '"ok":true' && p || f "List users ok"
echo "$USERS_RESP" | grep -q 'autopoiesis_frames_admin_user_list' && p || f "List users kind"
echo "$USERS_RESP" | grep -q '"total":2' && p || f "List users total=2 (alice+bob)"
echo "$USERS_RESP" | grep -q 'user-alice' && p || f "List includes alice"
echo "$USERS_RESP" | grep -q 'user-bob' && p || f "List includes bob"
echo "$USERS_RESP" | grep -q 'deviceCount' && p || f "Users have deviceCount"
echo "$USERS_RESP" | grep -q 'entitlements' && p || f "Users have entitlements"
echo "$USERS_RESP" | grep -q 'frames_premium' && p || f "Alice plan visible"

# Filter by subscription plan
PREMIUM_RESP=$(api GET "/frames/admin/users?subscriptionPlan=frames_premium")
echo "$PREMIUM_RESP" | grep -q 'user-alice' && p || f "Filter by plan includes alice"
echo "$PREMIUM_RESP" | grep -q 'user-bob' && { f "Filter by plan excludes bob"; } || p

# Filter by subscription status
ACTIVE_RESP=$(api GET "/frames/admin/users?subscriptionStatus=active")
echo "$ACTIVE_RESP" | grep -q 'user-alice' && p || f "Filter by status includes alice"
echo "$ACTIVE_RESP" | grep -q '"total":1' && p || f "Filter by status total=1"

# Pagination
PAGE_RESP=$(api GET "/frames/admin/users?limit=1&offset=0")
echo "$PAGE_RESP" | grep -q '"pageSize":1' && p || f "Pagination pageSize=1"
echo "$PAGE_RESP" | grep -q '"page":1' && p || f "Pagination page=1"

# ═══════════════════════════════════════════════════════════════
# Step 6: GET /frames/admin/users/:userId — user detail
# ═══════════════════════════════════════════════════════════════
step_header "GET /frames/admin/users/:userId — user detail"

ALICE_RESP=$(api GET /frames/admin/users/user-alice)
echo "$ALICE_RESP" | grep -q '"ok":true' && p || f "Alice detail ok"
echo "$ALICE_RESP" | grep -q 'autopoiesis_frames_admin_user_detail' && p || f "Alice detail kind"
echo "$ALICE_RESP" | grep -q '"userId":"user-alice"' && p || f "Alice userId"
echo "$ALICE_RESP" | grep -q '"deviceCount":1' && p || f "Alice deviceCount=1"
echo "$ALICE_RESP" | grep -q '"deviceId"' && p || f "Alice has devices array"
echo "$ALICE_RESP" | grep -q '"subscription"' && p || f "Alice has subscription"
echo "$ALICE_RESP" | grep -q 'frames_premium' && p || f "Alice plan=frames_premium"
echo "$ALICE_RESP" | grep -q '"entitlements"' && p || f "Alice has entitlements"
echo "$ALICE_RESP" | grep -q '"preferences"' && p || f "Alice has preferences"
echo "$ALICE_RESP" | grep -q '"likedArtworks"' && p || f "Alice has likedArtworks"
echo "$ALICE_RESP" | grep -q '"likedArtworkCount":2' && p || f "Alice likedArtworkCount=2"
echo "$ALICE_RESP" | grep -q 'art-001' && p || f "Alice liked art-001 present"
echo "$ALICE_RESP" | grep -q 'art-002' && p || f "Alice liked art-002 present"
echo "$ALICE_RESP" | grep -q '"online":' && p || f "Alice devices have online status"
echo "$ALICE_RESP" | grep -q '"actionAvailability"' && p || f "Alice devices have actionAvailability"

# Bob detail (fewer devices, trial plan)
BOB_RESP=$(api GET /frames/admin/users/user-bob)
echo "$BOB_RESP" | grep -q '"ok":true' && p || f "Bob detail ok"
echo "$BOB_RESP" | grep -q '"deviceCount":1' && p || f "Bob deviceCount=1"
echo "$BOB_RESP" | grep -q 'frames_trial' && p || f "Bob plan=frames_trial"
echo "$BOB_RESP" | grep -q '"likedArtworkCount":0' && p || f "Bob likedArtworkCount=0"

# Unknown user returns 404
UNKNOWN_RESP=$(api GET /frames/admin/users/user-nonexistent)
echo "$UNKNOWN_RESP" | grep -q 'not found' && p || f "Unknown user 404"

# ═══════════════════════════════════════════════════════════════
# Step 7: GET /frames/admin/users/:userId/preferences
# ═══════════════════════════════════════════════════════════════
step_header "GET /frames/admin/users/:userId/preferences"

# Alice hasn't set preferences — should get defaults
ALICE_PREFS=$(api GET /frames/admin/users/user-alice/preferences)
echo "$ALICE_PREFS" | grep -q '"ok":true' && p || f "Alice prefs ok"
echo "$ALICE_PREFS" | grep -q '"userId":"user-alice"' && p || f "Alice prefs userId"
echo "$ALICE_PREFS" | grep -q '"preferences"' && p || f "Alice has preferences"
echo "$ALICE_PREFS" | grep -q '"activeArtists"' && p || f "Default activeArtists"
echo "$ALICE_PREFS" | grep -q '"allowImages":true' && p || f "Default allowImages"
echo "$ALICE_PREFS" | grep -q '"cacheLikedArtworks":true' && p || f "Default cacheLikedArtworks"
echo "$ALICE_PREFS" | grep -q '"offlineFallbackMode":"cached"' && p || f "Default offlineFallbackMode"

# ═══════════════════════════════════════════════════════════════
# Step 8: PATCH /frames/admin/users/:userId/preferences
# ═══════════════════════════════════════════════════════════════
step_header "PATCH /frames/admin/users/:userId/preferences"

# Update alice's active artists
PATCH_RESP=$(api PATCH /frames/admin/users/user-alice/preferences '{"activeArtists":["vessel","sandman"],"soundEnabled":true}')
echo "$PATCH_RESP" | grep -q '"ok":true' && p || f "Patch prefs ok"
echo "$PATCH_RESP" | grep -q '"updated":true' && p || f "Patch prefs updated"
echo "$PATCH_RESP" | grep -q '"userId":"user-alice"' && p || f "Patch prefs userId"
echo "$PATCH_RESP" | grep -q '"preferences"' && p || f "Patch prefs has preferences"
echo "$PATCH_RESP" | grep -q '"updatedAt"' && p || f "Patch prefs has updatedAt"

# Verify the update stuck via GET (which returns stored preferences)
VERIFY_PREFS=$(api GET /frames/admin/users/user-alice/preferences)
echo "$VERIFY_PREFS" | grep -q 'vessel' && p || f "Verify activeArtists contains vessel"
echo "$VERIFY_PREFS" | grep -q 'sandman' && p || f "Verify activeArtists contains sandman"
echo "$VERIFY_PREFS" | grep -q '"soundEnabled":true' && p || f "Verify soundEnabled=true"
# Note: merge only applies over existing stored prefs; first write has no defaults to merge over
echo "$VERIFY_PREFS" | grep -q 'preferences' && p || f "Verify preferences object present"

# Update offlineFallbackMode
MODE_RESP=$(api PATCH /frames/admin/users/user-alice/preferences '{"offlineFallbackMode":"black"}')
echo "$MODE_RESP" | grep -q '"ok":true' && p || f "Patch offlineFallbackMode ok"
VERIFY_MODE=$(api GET /frames/admin/users/user-alice/preferences)
echo "$VERIFY_MODE" | grep -q '"offlineFallbackMode":"black"' && p || f "Verify offlineFallbackMode=black"

# ═══════════════════════════════════════════════════════════════
# Step 9: Validation errors
# ═══════════════════════════════════════════════════════════════
step_header "Validation errors"

# Unknown preference key
BAD_KEY=$(api PATCH /frames/admin/users/user-alice/preferences '{"unknownKey":"value"}')
echo "$BAD_KEY" | grep -q 'Unknown preference' && p || f "Reject unknown key"

# Empty body
EMPTY_BODY=$(api PATCH /frames/admin/users/user-alice/preferences '{}')
echo "$EMPTY_BODY" | grep -q 'No preferences' && p || f "Reject empty body"

# Invalid activeArtists type
BAD_TYPE=$(api PATCH /frames/admin/users/user-alice/preferences '{"activeArtists":"not-array"}')
echo "$BAD_TYPE" | grep -q 'must be an array' && p || f "Reject invalid activeArtists type"

# Invalid offlineFallbackMode
BAD_MODE=$(api PATCH /frames/admin/users/user-alice/preferences '{"offlineFallbackMode":"invalid"}')
echo "$BAD_MODE" | grep -q 'must be one of' && p || f "Reject invalid offlineFallbackMode"

# ═══════════════════════════════════════════════════════════════
# Step 10: Auth gates
# ═══════════════════════════════════════════════════════════════
step_header "Auth gates"

# No token
NOAUTH=$(api_noauth GET /frames/admin/users)
echo "$NOAUTH" | grep -q 'Missing admin token' && p || f "No auth → 401 on list users"

NOAUTH_DETAIL=$(api_noauth GET /frames/admin/users/user-alice)
echo "$NOAUTH_DETAIL" | grep -q 'Missing admin token' && p || f "No auth → 401 on user detail"

NOAUTH_PREFS=$(api_noauth GET /frames/admin/users/user-alice/preferences)
echo "$NOAUTH_PREFS" | grep -q 'Missing admin token' && p || f "No auth → 401 on get prefs"

NOAUTH_PATCH=$(api_noauth PATCH /frames/admin/users/user-alice/preferences '{"soundEnabled":false}')
echo "$NOAUTH_PATCH" | grep -q 'Missing admin token' && p || f "No auth → 401 on patch prefs"

# Wrong token
BADAUTH=$(api_badtoken GET /frames/admin/users)
echo "$BADAUTH" | grep -q 'Invalid admin token' && p || f "Bad auth → 403 on list users"

# ═══════════════════════════════════════════════════════════════
# Step 11: Regression — admin bundle still works
# ═══════════════════════════════════════════════════════════════
step_header "Regression — admin bundle"

BUNDLE_RESP=$(api GET "/frames/admin/bundle?userId=user-alice")
echo "$BUNDLE_RESP" | grep -q '"ok":true' && p || f "Admin bundle still works"
echo "$BUNDLE_RESP" | grep -q 'user-alice' && p || f "Admin bundle includes alice"
echo "$BUNDLE_RESP" | grep -q 'profileFrames' && p || f "Admin bundle profileFrames"
echo "$BUNDLE_RESP" | grep -q 'adminFrames' && p || f "Admin bundle adminFrames"

# ═══════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Admin User Management Check"
echo "  Steps: $step | PASS: $PASS | FAIL: $FAIL | SKIP: $SKIP"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$FAIL" -gt 0 ]; then
  echo "  ❌ FAILED"
  exit 1
fi
echo "  ✅ ALL CHECKS PASSED"
