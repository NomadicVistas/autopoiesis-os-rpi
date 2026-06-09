#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# preferences-conflict-resolution-check.sh
#
# Validates that setUserPreferences() and the admin PATCH preferences endpoint
# correctly handle updatedAt-based conflict resolution, mirroring the pattern
# already established for device settings pushSettings().
#
# Steps:
#  1. Syntax validation
#  2. Static contract (source-level patterns)
#  3. Server bootstrap with fresh database
#  4. Baseline preference write
#  5. Newer write accepted (with client updatedAt)
#  6. Stale write rejected (conflict with stale updatedAt)
#  7. Write without updatedAt accepted (no conflict check when client has no timestamp)
#  8. Final read preserves accepted row
#  9. Regression (health, admin bundle)
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

PASS=0; FAIL=0; SKIP=0; CHECKS=0
p() { ((PASS++)); ((CHECKS++)); printf "  ✅ %s\n" "$1"; }
f() { ((FAIL++)); ((CHECKS++)); printf "  ❌ %s\n" "$1"; }
s() { ((SKIP++)); printf "  ⏭️  %s\n" "$1"; }
section() { printf "\n── Step %s ──\n" "$1"; }

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_JS="$ROOT_DIR/hosted-api/server.js"
DB_JS="$ROOT_DIR/hosted-api/db.js"
TMP_DIR=$(mktemp -d)
SERVER_PID=""
trap 'rm -rf "$TMP_DIR"; if [ -n "${SERVER_PID:-}" ] && kill -0 "$SERVER_PID" 2>/dev/null; then kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; fi' EXIT

jq_val() { echo "$1" | jq -r "$2" 2>/dev/null; }

# ── Step 1: Syntax validation ──────────────────────────────────────────────
section "1: Syntax validation"
node --check "$SERVER_JS" 2>/dev/null && p "server.js syntax" || f "server.js syntax"
node --check "$DB_JS" 2>/dev/null && p "db.js syntax" || f "db.js syntax"

# ── Step 2: Static contract ────────────────────────────────────────────────
section "2: Static contract"

grep -q 'setUserPreferences(userId, preferences, incomingUpdatedAt)' "$DB_JS" \
  && p "db.setUserPreferences accepts incomingUpdatedAt parameter" \
  || f "db.setUserPreferences accepts incomingUpdatedAt parameter"

grep -q 'reason: "stale_write"' "$DB_JS" \
  && p "db.setUserPreferences returns stale_write on conflict" \
  || f "db.setUserPreferences returns stale_write on conflict"

grep -q 'conflict: true' "$DB_JS" \
  && p "db.setUserPreferences sets conflict:true" \
  || f "db.setUserPreferences sets conflict:true"

grep -q 'jsonParse(row.preferences_json' "$DB_JS" \
  && p "db merges existing preferences before overwrite" \
  || f "db merges existing preferences before overwrite"

grep -q '...preferences' "$DB_JS" \
  && p "db spreads incoming preferences over existing" \
  || f "db spreads incoming preferences over existing"

grep -q 'clientUpdatedAt' "$SERVER_JS" \
  && p "server extracts clientUpdatedAt from request body" \
  || f "server extracts clientUpdatedAt from request body"

grep -q 'delete patch.updatedAt' "$SERVER_JS" \
  && p "server strips updatedAt from preference patch" \
  || f "server strips updatedAt from preference patch"

grep -q 'preferences conflict' "$SERVER_JS" \
  && p "server returns preferences conflict response" \
  || f "server returns preferences conflict response"

grep -q '"updatedAt"' "$SERVER_JS" \
  && p "updatedAt in VALID_KEYS set" \
  || f "updatedAt in VALID_KEYS set"

# ── Step 3: Server bootstrap ───────────────────────────────────────────────
section "3: Server bootstrap"

PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")
BASE_URL="http://127.0.0.1:$PORT"
DB_PATH="$TMP_DIR/aos-test.db"
ADMIN_TOKEN="test-admin-pref-$(date +%s)"

AOS_DB="$DB_PATH" AOS_PORT="$PORT" AOS_HOST="127.0.0.1" \
  AUTOPOIESIS_FRAMES_ADMIN_TOKEN="$ADMIN_TOKEN" \
  node "$SERVER_JS" >"$TMP_DIR/server.log" 2>&1 &
SERVER_PID="$!"

for _ in {1..60}; do
  if curl -fsS "$BASE_URL/health" >/dev/null 2>&1; then break; fi
  sleep 0.1
done

if ! curl -fsS "$BASE_URL/health" >/dev/null 2>&1; then
  f "Server bootstrap failed"
  echo "--- server log ---" >&2
  cat "$TMP_DIR/server.log" >&2
  exit 1
fi
p "Server started with fresh DB (port $PORT)"

# ── Step 4: Baseline preference write ──────────────────────────────────────
section "4: Baseline preference write"

OWNER_ID="owner-$(date +%s)"

# Create a user subscription first so the user exists in the system
curl -fsS -X POST "$BASE_URL/frames/admin/subscriptions" \
  -H "Content-Type: application/json" \
  -H "x-admin-token: $ADMIN_TOKEN" \
  -d "{\"userId\":\"$OWNER_ID\",\"plan\":\"frames_basic\",\"status\":\"active\"}" >/dev/null 2>&1 || true

# Write initial preferences (no updatedAt → no conflict check)
PREFS_V1=$(curl -fsS -X PATCH "$BASE_URL/frames/admin/users/$OWNER_ID/preferences" \
  -H "Content-Type: application/json" \
  -H "x-admin-token: $ADMIN_TOKEN" \
  -d '{"autoplay":true,"soundEnabled":false,"offlineFallbackMode":"cached","streamCategories":["artwork","curatorial"]}' || echo '{}')

V1_OK=$(jq_val "$PREFS_V1" '.ok')
V1_UPDATED=$(jq_val "$PREFS_V1" '.updatedAt')
V1_AUTOPLAY=$(jq_val "$PREFS_V1" '.preferences.autoplay')
V1_OFFLINE=$(jq_val "$PREFS_V1" '.preferences.offlineFallbackMode')
V1_CATEGORIES=$(jq_val "$PREFS_V1" '.preferences.streamCategories | length')

[ "$V1_OK" = "true" ] && p "Initial preferences accepted (ok=true)" || f "Initial preferences accepted (ok=$V1_OK)"
[ "$V1_AUTOPLAY" = "true" ] && p "autoplay=true stored correctly" || f "autoplay stored (got $V1_AUTOPLAY)"
[ "$V1_OFFLINE" = "cached" ] && p "offlineFallbackMode=cached stored correctly" || f "offlineFallbackMode stored (got $V1_OFFLINE)"
[ "$V1_CATEGORIES" = "2" ] && p "streamCategories array preserved" || f "streamCategories (got $V1_CATEGORIES items)"
[ -n "$V1_UPDATED" ] && [ "$V1_UPDATED" != "null" ] && p "updatedAt returned: $V1_UPDATED" || f "updatedAt returned"

# ── Step 5: Newer write accepted ───────────────────────────────────────────
section "5: Newer write accepted"

# Send with the v1 updatedAt — should be accepted since it matches the current row
PREFS_V2=$(curl -fsS -X PATCH "$BASE_URL/frames/admin/users/$OWNER_ID/preferences" \
  -H "Content-Type: application/json" \
  -H "x-admin-token: $ADMIN_TOKEN" \
  -d "{\"updatedAt\":\"$V1_UPDATED\",\"autoplay\":false,\"soundEnabled\":true}" || echo '{}')

V2_OK=$(jq_val "$PREFS_V2" '.ok')
V2_CONFLICT=$(jq_val "$PREFS_V2" '.conflict // "none"')
V2_AUTOPLAY=$(jq_val "$PREFS_V2" '.preferences.autoplay')
V2_SOUND=$(jq_val "$PREFS_V2" '.preferences.soundEnabled')
V2_OFFLINE=$(jq_val "$PREFS_V2" '.preferences.offlineFallbackMode')
V2_UPDATED=$(jq_val "$PREFS_V2" '.updatedAt')

[ "$V2_OK" = "true" ] && p "Newer write accepted (ok=true)" || f "Newer write accepted (ok=$V2_OK)"
[ "$V2_CONFLICT" = "none" ] && p "No conflict flag on newer write" || f "No conflict flag (got $V2_CONFLICT)"
[ "$V2_AUTOPLAY" = "false" ] && p "autoplay updated to false" || f "autoplay updated (got $V2_AUTOPLAY)"
[ "$V2_SOUND" = "true" ] && p "soundEnabled updated to true" || f "soundEnabled updated (got $V2_SOUND)"
[ "$V2_OFFLINE" = "cached" ] && p "offlineFallbackMode preserved from v1 (merge)" || f "offlineFallbackMode preserved (got $V2_OFFLINE)"
[ "$V2_UPDATED" != "$V1_UPDATED" ] && p "updatedAt advanced to new timestamp" || f "updatedAt advanced (v1=$V1_UPDATED v2=$V2_UPDATED)"

# ── Step 6: Stale write rejected ───────────────────────────────────────────
section "6: Stale write rejected"

# Send with the old v1 timestamp — should be rejected as stale
PREFS_STALE=$(curl -fsS -X PATCH "$BASE_URL/frames/admin/users/$OWNER_ID/preferences" \
  -H "Content-Type: application/json" \
  -H "x-admin-token: $ADMIN_TOKEN" \
  -d "{\"updatedAt\":\"$V1_UPDATED\",\"autoplay\":true,\"offlineFallbackMode\":\"black\"}" || echo '{}')

STALE_OK=$(jq_val "$PREFS_STALE" '.ok')
STALE_CONFLICT=$(jq_val "$PREFS_STALE" '.conflict')
STALE_REASON=$(jq_val "$PREFS_STALE" '.reason')
STALE_AUTOPLAY=$(jq_val "$PREFS_STALE" '.preferences.autoplay')
STALE_OFFLINE=$(jq_val "$PREFS_STALE" '.preferences.offlineFallbackMode')
STALE_UPDATED=$(jq_val "$PREFS_STALE" '.updatedAt')

[ "$STALE_OK" = "false" ] && p "Stale write rejected (ok=false)" || f "Stale write rejected (ok=$STALE_OK)"
[ "$STALE_CONFLICT" = "true" ] && p "Conflict flag set" || f "Conflict flag (got $STALE_CONFLICT)"
[ "$STALE_REASON" = "stale_write" ] && p "Reason: stale_write" || f "Reason (got $STALE_REASON)"
[ "$STALE_AUTOPLAY" = "false" ] && p "Returned autoplay=false (v2 preserved)" || f "Returned autoplay (got $STALE_AUTOPLAY)"
[ "$STALE_OFFLINE" = "cached" ] && p "Returned offlineFallbackMode=cached (v1 preserved)" || f "Returned offlineFallbackMode (got $STALE_OFFLINE)"
[ "$STALE_UPDATED" = "$V2_UPDATED" ] && p "Returned updatedAt matches v2" || f "Returned updatedAt (got $STALE_UPDATED, expected $V2_UPDATED)"

# ── Step 7: Write without updatedAt accepted ───────────────────────────────
section "7: Write without updatedAt accepted (no conflict check)"

# A write without updatedAt should bypass conflict detection and always succeed
PREFS_V3=$(curl -fsS -X PATCH "$BASE_URL/frames/admin/users/$OWNER_ID/preferences" \
  -H "Content-Type: application/json" \
  -H "x-admin-token: $ADMIN_TOKEN" \
  -d '{"allowVideos":false}' || echo '{}')

V3_OK=$(jq_val "$PREFS_V3" '.ok')
V3_CONFLICT=$(jq_val "$PREFS_V3" '.conflict // "none"')
V3_VIDEOS=$(jq_val "$PREFS_V3" '.preferences.allowVideos')
V3_AUTOPLAY=$(jq_val "$PREFS_V3" '.preferences.autoplay')

[ "$V3_OK" = "true" ] && p "Write without updatedAt accepted" || f "Write without updatedAt accepted (ok=$V3_OK)"
[ "$V3_CONFLICT" = "none" ] && p "No conflict on write without updatedAt" || f "No conflict (got $V3_CONFLICT)"
[ "$V3_VIDEOS" = "false" ] && p "allowVideos updated to false" || f "allowVideos (got $V3_VIDEOS)"
[ "$V3_AUTOPLAY" = "false" ] && p "autoplay=false preserved from v2 (merge)" || f "autoplay preserved (got $V3_AUTOPLAY)"

# ── Step 8: Final read preserves accepted row ──────────────────────────────
section "8: Final read preserves accepted row"

FINAL_PREFS=$(curl -fsS "$BASE_URL/frames/admin/users/$OWNER_ID/preferences" \
  -H "x-admin-token: $ADMIN_TOKEN" || echo '{}')

FINAL_AUTOPLAY=$(jq_val "$FINAL_PREFS" '.preferences.autoplay')
FINAL_SOUND=$(jq_val "$FINAL_PREFS" '.preferences.soundEnabled')
FINAL_VIDEOS=$(jq_val "$FINAL_PREFS" '.preferences.allowVideos')
FINAL_OFFLINE=$(jq_val "$FINAL_PREFS" '.preferences.offlineFallbackMode')
FINAL_UPDATED=$(jq_val "$FINAL_PREFS" '.updatedAt')

[ "$FINAL_AUTOPLAY" = "false" ] && p "Final: autoplay=false (v2)" || f "Final: autoplay (got $FINAL_AUTOPLAY)"
[ "$FINAL_SOUND" = "true" ] && p "Final: soundEnabled=true (v2)" || f "Final: soundEnabled (got $FINAL_SOUND)"
[ "$FINAL_VIDEOS" = "false" ] && p "Final: allowVideos=false (v3)" || f "Final: allowVideos (got $FINAL_VIDEOS)"
[ "$FINAL_OFFLINE" = "cached" ] && p "Final: offlineFallbackMode=cached (v1, never overwritten)" || f "Final: offlineFallbackMode (got $FINAL_OFFLINE)"
[ -n "$FINAL_UPDATED" ] && [ "$FINAL_UPDATED" != "null" ] && p "Final: updatedAt present and recent" || f "Final: updatedAt present"

# ── Step 9: Regression ─────────────────────────────────────────────────────
section "9: Regression"

curl -fsS "$BASE_URL/health" >/dev/null 2>&1 && p "Health endpoint works" || f "Health endpoint"

BUNDLE=$(curl -fsS "$BASE_URL/frames/admin/bundle?userId=$OWNER_ID" \
  -H "x-admin-token: $ADMIN_TOKEN" || echo '{}')
BUNDLE_OK=$(jq_val "$BUNDLE" '.ok')
[ "$BUNDLE_OK" = "true" ] && p "Admin bundle works" || f "Admin bundle (ok=$BUNDLE_OK)"

# ── Summary ────────────────────────────────────────────────────────────────
printf "\n════════════════════════════════════════════════════════════\n"
printf "  Preferences Conflict Resolution Check\n"
printf "  ✅ %d   ❌ %d   ⏭️ %d   (%d checks)\n" "$PASS" "$FAIL" "$SKIP" "$CHECKS"
printf "════════════════════════════════════════════════════════════\n"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
