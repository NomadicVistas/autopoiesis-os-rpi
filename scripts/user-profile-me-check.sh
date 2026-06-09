#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# user-profile-me-check.sh — Validation gate for /frames/me/* user-facing Profile API
#
# Validates: user authentication, profile summary, device listing, preference
# read/write with conflict resolution, liked artworks, subscription + entitlements,
# admin token pass-through, auth gates (missing/wrong token), CORS, and regression.
#
# Usage: bash scripts/user-profile-me-check.sh
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

PASS=0; FAIL=0; SKIP=0
step_n=0; check_n=0

title()  { printf "\n━━ Step %d: %s ━━\n" "$((++step_n))" "$1"; }
check()  { ((++check_n)); if "$@"; then ((++PASS)); printf "  ✅ [%d] %s\n" "$check_n" "$*"; else ((++FAIL)); printf "  ❌ [%d] %s\n" "$check_n" "$*"; fi; }
skip()   { ((++check_n)); ((++SKIP)); printf "  ⏭️  [%d] %s\n" "$check_n" "$*"; }

get_json() {
  echo "$1" | node -e "
    const d=JSON.parse(require('fs').readFileSync(0,'utf8'));
    const v='$2'.split('.').reduce((o,k)=>o?.[k],d);
    process.stdout.write(String(v ?? ''))
  " 2>/dev/null
}

jv() {
  # jv <response> <dotpath> <expected> — returns 0 if match
  local actual
  actual=$(get_json "$1" "$2")
  [[ "$actual" == "$3" ]]
}

jn() {
  # jn <response> <dotpath> — returns 0 if field is non-empty and not UNDEFINED
  local actual
  actual=$(get_json "$1" "$2")
  [[ -n "$actual" && "$actual" != "UNDEFINED" ]]
}

jgrep() {
  # jgrep <response> <substring> — returns 0 if response contains substring
  echo "$1" | grep -q "$2"
}

cleanup() {
  if [[ -n "${SRV_PID:-}" ]]; then kill "$SRV_PID" 2>/dev/null || true; fi
  if [[ -n "${SRV_PID2:-}" ]]; then kill "$SRV_PID2" 2>/dev/null || true; fi
  rm -f "${DB_FILE:-}" "${NO_TOKENS_DB:-}"
}
trap cleanup EXIT

echo "════════════════════════════════════════════════════════════════"
echo "  User Profile /frames/me/* — Validation Gate"
echo "════════════════════════════════════════════════════════════════"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DB_FILE="$(mktemp /tmp/aos-user-me-check-XXXXXX.db)"
PORT=$(( 19800 + (RANDOM % 900) ))

# ── Step 1: Syntax validation ───────────────────────────────────────────────
title "Syntax validation"
check node --check "$REPO_ROOT/hosted-api/server.js"
check node --check "$REPO_ROOT/hosted-api/db.js"
check node --check "$REPO_ROOT/local-ui/server.js"

# ── Step 2: Static contract ─────────────────────────────────────────────────
title "Static contract — handler and auth function signatures"
SRV="$REPO_ROOT/hosted-api/server.js"

check grep -q 'function authenticateUser' "$SRV"
check grep -q 'function handleMeProfile' "$SRV"
check grep -q 'function handleMeDevices' "$SRV"
check grep -q 'function handleMeGetPreferences' "$SRV"
check grep -q 'function handleMeUpdatePreferences' "$SRV"
check grep -q 'function handleMeLikedArtworks' "$SRV"
check grep -q 'function handleMeSubscription' "$SRV"
check grep -q 'pathname === "/frames/me"' "$SRV"
check grep -q 'pathname === "/frames/me/devices"' "$SRV"
check grep -q 'pathname === "/frames/me/preferences"' "$SRV"
check grep -q 'pathname === "/frames/me/liked-artworks"' "$SRV"
check grep -q 'pathname === "/frames/me/subscription"' "$SRV"
check grep -q 'AUTOPOIESIS_FRAMES_USER_TOKENS' "$SRV"
check grep -q 'x-user-token' "$SRV"
check grep -q '_parseUserTokens' "$SRV"
check grep -q 'adminAccess' "$SRV"

# ── Step 3: Server bootstrap ────────────────────────────────────────────────
title "Server bootstrap with fresh database"

USER_TOKENS='{"test-user-token-abc123":"owner-test-user"}'
ADMIN_TOKEN="admin-secret-test"

AOS_DB="$DB_FILE" \
AOS_PORT="$PORT" \
AUTOPOIESIS_FRAMES_ADMIN_TOKEN="$ADMIN_TOKEN" \
AUTOPOIESIS_FRAMES_USER_TOKENS="$USER_TOKENS" \
node "$REPO_ROOT/hosted-api/server.js" &
SRV_PID=$!

# Wait for server
for i in $(seq 1 30); do
  if curl -s "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then break; fi
  sleep 0.2
done

HEALTH=$(curl -s "http://127.0.0.1:$PORT/health")
check jv "$HEALTH" "ok" "true"
check jv "$HEALTH" "service" "aos-hosted-api"

api() {
  local method="$1" path="$2"; shift 2
  curl -s -X "$method" "http://127.0.0.1:$PORT$path" "$@"
}
api_user() {
  local method="$1" path="$2"; shift 2
  curl -s -X "$method" -H "x-user-token: test-user-token-abc123" "http://127.0.0.1:$PORT$path" "$@"
}
api_admin() {
  local method="$1" path="$2"; shift 2
  curl -s -X "$method" -H "x-admin-token: $ADMIN_TOKEN" "http://127.0.0.1:$PORT$path" "$@"
}

# ── Step 4: Device + user setup ─────────────────────────────────────────────
title "Device registration + pairing for user context"

REG=$(api POST /frames/device/register -H "Content-Type: application/json" \
  -d '{"deviceId":"dev-me-001","deviceName":"My Frame","deviceType":"rpi"}')
check jv "$REG" "ok" "true"
DEV_KEY=$(get_json "$REG" "device.deviceApiKey")
PAIRING_CODE=$(get_json "$REG" "pairingCode")
check test -n "$DEV_KEY"
check test -n "$PAIRING_CODE"

# Claim pairing code (direct DB, may fail with SQLITE_BUSY if server has lock)
CLAIM_RESULT=$(node -e "
  const Database = require('better-sqlite3');
  const db = new Database('$DB_FILE'); db.pragma('journal_mode=WAL');
  db.prepare('UPDATE aos_frame_devices SET paired = 1, owner_user_id = ? WHERE device_id = ?').run('owner-test-user', 'dev-me-001');
  db.prepare('DELETE FROM aos_frame_pairing_codes WHERE pairing_code = ?').run('$PAIRING_CODE');
  console.log('{\"ok\":true}');
" 2>&1) || true
check jv "$CLAIM_RESULT" "ok" "true"

# Set up subscription
SUB=$(api_admin POST /frames/admin/subscriptions -H "Content-Type: application/json" \
  -d '{"userId":"owner-test-user","plan":"frames_basic","status":"active"}')
check jv "$SUB" "ok" "true"

# ── Step 5: User profile summary ────────────────────────────────────────────
title "GET /frames/me — User profile summary"

ME=$(api_user GET /frames/me)
check jv "$ME" "ok" "true"
check jv "$ME" "kind" "autopoiesis_frames_me_profile"
check jv "$ME" "profile.userId" "owner-test-user"
check jv "$ME" "profile.deviceCount" "1"
check jn "$ME" "profile.subscription"
check jn "$ME" "profile.entitlements"
check jv "$ME" "profile.entitlements.maxDevices" "3"
check jv "$ME" "profile.likedArtworkCount" "0"
check jn "$ME" "generatedAt"

# ── Step 6: User devices ────────────────────────────────────────────────────
title "GET /frames/me/devices — User's paired devices"

DEVS=$(api_user GET /frames/me/devices)
check jv "$DEVS" "ok" "true"
check jv "$DEVS" "kind" "autopoiesis_frames_me_devices"
check jv "$DEVS" "total" "1"
check jv "$DEVS" "devices.0.deviceId" "dev-me-001"
check jv "$DEVS" "devices.0.deviceName" "Autopoiesis Frame"
check jv "$DEVS" "devices.0.deviceType" "raspberry_pi"
check jv "$DEVS" "devices.0.online" "false"
check jn "$DEVS" "devices.0.remoteEnabled"
check jv "$DEVS" "devices.0.disabled" "false"

# ── Step 7: User preferences read/write ─────────────────────────────────────
title "GET /frames/me/preferences — Read user preferences"

PREFS=$(api_user GET /frames/me/preferences)
check jv "$PREFS" "ok" "true"
check jv "$PREFS" "kind" "autopoiesis_frames_me_preferences"
check jv "$PREFS" "preferences.allowImages" "true"
check jv "$PREFS" "preferences.autoplay" "true"
check jn "$PREFS" "preferences.streamCategories"

title "PATCH /frames/me/preferences — Update user preferences"

UPD=$(api_user PATCH /frames/me/preferences -H "Content-Type: application/json" \
  -d '{"autoplay":false,"allowVideos":false}')
check jv "$UPD" "ok" "true"
check jv "$UPD" "preferences.autoplay" "false"
check jv "$UPD" "preferences.allowVideos" "false"
check jn "$UPD" "updatedAt"

# Verify persistence (GET returns defaults merged with stored)
PREFS2=$(api_user GET /frames/me/preferences)
check jv "$PREFS2" "preferences.autoplay" "false"
check jv "$PREFS2" "preferences.allowVideos" "false"

# ── Step 8: Conflict resolution ──────────────────────────────────────────────
title "PATCH /frames/me/preferences — Conflict resolution"

UPDATED_AT=$(get_json "$UPD" "updatedAt")

# Stale write
CONFLICT=$(api_user PATCH /frames/me/preferences -H "Content-Type: application/json" \
  -d "{\"autoplay\":true,\"updatedAt\":\"2020-01-01T00:00:00.000Z\"}")
check jv "$CONFLICT" "ok" "false"
check jv "$CONFLICT" "conflict" "true"
check jv "$CONFLICT" "reason" "stale_write"

# Fresh write with correct updatedAt
FRESH=$(api_user PATCH /frames/me/preferences -H "Content-Type: application/json" \
  -d "{\"soundEnabled\":true,\"updatedAt\":\"$UPDATED_AT\"}")
check jv "$FRESH" "ok" "true"
check jv "$FRESH" "preferences.soundEnabled" "true"

# ── Step 9: Liked artworks ──────────────────────────────────────────────────
title "GET /frames/me/liked-artworks — User's liked artworks (empty then populated)"

LIKED=$(api_user GET /frames/me/liked-artworks)
check jv "$LIKED" "ok" "true"
check jv "$LIKED" "kind" "autopoiesis_frames_me_liked_artworks"
check jv "$LIKED" "total" "0"

# Create broadcast content for artwork likes
BC1=$(api_admin POST /frames/admin/broadcasts -H "Content-Type: application/json" \
  -d '{"title":"Test Art 1","type":"artwork","artistId":"vessel-001","status":"published","priority":"normal"}')
BC2=$(api_admin POST /frames/admin/broadcasts -H "Content-Type: application/json" \
  -d '{"title":"Test Art 2","type":"artwork","artistId":"sandman-002","status":"published","priority":"normal"}')
BC3=$(api_admin POST /frames/admin/broadcasts -H "Content-Type: application/json" \
  -d '{"title":"Test Art 3","type":"artwork","artistId":"kinema-003","status":"published","priority":"normal"}')
ART1_ID=$(get_json "$BC1" "broadcast.id")
ART2_ID=$(get_json "$BC2" "broadcast.id")
ART3_ID=$(get_json "$BC3" "broadcast.id")
check test -n "$ART1_ID"
check test -n "$ART2_ID"
check test -n "$ART3_ID"

# Like artworks via device auth
LIKE1=$(api POST "/frames/artworks/$ART1_ID/like" -H "Content-Type: application/json" \
  -H "x-frame-device-key: $DEV_KEY" -d '{"deviceId":"dev-me-001"}')
LIKE2=$(api POST "/frames/artworks/$ART2_ID/like" -H "Content-Type: application/json" \
  -H "x-frame-device-key: $DEV_KEY" -d '{"deviceId":"dev-me-001"}')
check jv "$LIKE1" "ok" "true"
check jv "$LIKE2" "ok" "true"

# Now check liked artworks
LIKED2=$(api_user GET /frames/me/liked-artworks)
check jv "$LIKED2" "total" "2"
check jn "$LIKED2" "likedArtworks.0.artworkId"

# Pagination
LIKED_P1=$(api_user GET "/frames/me/liked-artworks?limit=1&offset=0")
check jv "$LIKED_P1" "total" "2"

# ── Step 10: Subscription + entitlements ─────────────────────────────────────
title "GET /frames/me/subscription — Subscription and entitlements"

SUB_ME=$(api_user GET /frames/me/subscription)
check jv "$SUB_ME" "ok" "true"
check jv "$SUB_ME" "kind" "autopoiesis_frames_me_subscription"
check jv "$SUB_ME" "subscription.plan" "frames_basic"
check jv "$SUB_ME" "subscription.status" "active"
check jv "$SUB_ME" "entitlements.maxDevices" "3"
check jv "$SUB_ME" "entitlements.devicesRemaining" "2"
check jv "$SUB_ME" "entitlements.offlineCache" "true"
check jv "$SUB_ME" "deviceCount" "1"

# ── Step 11: Admin token pass-through ───────────────────────────────────────
title "Admin token pass-through for /frames/me/*"

ME_ADMIN=$(api_admin GET "/frames/me?userId=owner-test-user")
check jv "$ME_ADMIN" "ok" "true"
check jv "$ME_ADMIN" "profile.userId" "owner-test-user"

DEVS_ADMIN=$(api_admin GET "/frames/me/devices?userId=owner-test-user")
check jv "$DEVS_ADMIN" "ok" "true"
check jv "$DEVS_ADMIN" "devices.0.deviceId" "dev-me-001"

PREFS_ADMIN=$(api_admin GET "/frames/me/preferences?userId=owner-test-user")
check jv "$PREFS_ADMIN" "ok" "true"

# ── Step 12: Auth gates ─────────────────────────────────────────────────────
title "Authentication gates"

# No user token configured → 503
NO_TOKENS_DB="$(mktemp /tmp/aos-user-me-notokens-XXXXXX.db)"
AOS_DB="$NO_TOKENS_DB" \
AOS_PORT=$((PORT + 1)) \
AUTOPOIESIS_FRAMES_ADMIN_TOKEN="$ADMIN_TOKEN" \
node "$REPO_ROOT/hosted-api/server.js" &
SRV_PID2=$!
for i in $(seq 1 30); do
  if curl -s "http://127.0.0.1:$((PORT + 1))/health" >/dev/null 2>&1; then break; fi
  sleep 0.2
done

NO_TOKENS_RESP=$(curl -s -H "x-user-token: test-user-token-abc123" "http://127.0.0.1:$((PORT + 1))/frames/me")
check jv "$NO_TOKENS_RESP" "ok" "false"
check jgrep "$NO_TOKENS_RESP" "not configured"
kill "$SRV_PID2" 2>/dev/null || true
rm -f "$NO_TOKENS_DB"

# Missing token → 401
NO_TOKEN=$(api GET /frames/me)
check jv "$NO_TOKEN" "ok" "false"
check jgrep "$NO_TOKEN" "Missing user token"

# Wrong token → 403
WRONG=$(api GET /frames/me -H "x-user-token: wrong-token-xyz")
check jv "$WRONG" "ok" "false"
check jgrep "$WRONG" "Invalid user token"

# Bearer token works
BEARER=$(api GET /frames/me -H "Authorization: Bearer test-user-token-abc123")
check jv "$BEARER" "ok" "true"

# ── Step 13: CORS preflight for /frames/me/* ─────────────────────────────────
title "CORS preflight for user endpoints"

PREFLIGHT_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X OPTIONS "http://127.0.0.1:$PORT/frames/me")
check test "$PREFLIGHT_STATUS" = "204"

# ── Step 14: Input validation ───────────────────────────────────────────────
title "Input validation"

# Unknown preference key
BAD_KEY=$(api_user PATCH /frames/me/preferences -H "Content-Type: application/json" \
  -d '{"unknownKeyHere":true}')
check jv "$BAD_KEY" "ok" "false"
check jgrep "$BAD_KEY" "Unknown preference keys"

# Empty body
EMPTY=$(api_user PATCH /frames/me/preferences -H "Content-Type: application/json" \
  -d '{}')
check jv "$EMPTY" "ok" "false"

# ── Step 15: Regression ─────────────────────────────────────────────────────
title "Regression — existing endpoints unaffected"

H=$(api GET /health)
check jv "$H" "ok" "true"

BUNDLE=$(api_admin GET /frames/admin/bundle)
check jv "$BUNDLE" "ok" "true"

SETTINGS=$(api GET /frames/device/dev-me-001/settings)
check jv "$SETTINGS" "ok" "true"

HB=$(api POST /frames/device/dev-me-001/heartbeat -H "Content-Type: application/json" \
  -H "x-frame-device-key: $DEV_KEY" \
  -d '{"softwareVersion":"1.0.0"}')
check jv "$HB" "ok" "true"

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "  Steps:   $step_n"
echo "  Checks:  $check_n"
echo "════════════════════════════════════════════════════════════════"

if [[ "$FAIL" -gt 0 ]]; then
  echo "  ❌ FAILED"
  exit 1
fi
echo "  ✅ ALL CHECKS PASSED"
