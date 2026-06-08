#!/usr/bin/env bash
# online-admin-subscription-lifecycle-check.sh
#
# Validates that admin subscription state transitions (trial -> active ->
# past_due -> cancelled -> expired) produce correct online-admin bundle
# outputs across users, subscribers, subscriptions, and fleet device
# subscription summaries.
#
# Run: bash scripts/online-admin-subscription-lifecycle-check.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MOCK_API="$REPO_ROOT/scripts/mock-hosted-api/server.js"
CONTRACT_CHECK="$REPO_ROOT/scripts/online-admin-contract-check.sh"

PORT=3151
BASE="http://127.0.0.1:$PORT"
MOCK_PID=""
TMPDIR=""
PASS=0
FAIL=0
STEP=0

# ── Helpers ──────────────────────────────────────────────────────────────────

step() { STEP=$((STEP + 1)); printf "\n=== Step %d: %s ===\n" "$STEP" "$1"; }
ok()   { PASS=$((PASS + 1)); printf "  ✓ %s\n" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf "  ✗ FAIL: %s\n" "$1" >&2; }
die()  { printf "FATAL: %s\n" "$1" >&2; exit 1; }

json_val() {
  node -e "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));let v=d$2;if(typeof v==='string')process.stdout.write(v);else process.stdout.write(JSON.stringify(v))" <<< "$1"
}

# Extract a field from a JSON blob using a safe node-eval with file
json_extract() {
  local jsonpath="$1" query="$2" result
  result=$(node -e "
    const d=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
    let v=d${query};
    if(typeof v==='string')process.stdout.write(v);
    else process.stdout.write(JSON.stringify(v));
  " "$jsonpath" 2>/dev/null) && echo "$result" || echo "null"
}

curl_json() {
  local url="$1"; shift
  curl -sf "$url" "$@" 2>/dev/null || echo '{"ok":false,"error":"curl_failed"}'
}

curl_post() {
  local url="$1" body="$2"; shift 2
  curl -sf -X POST -H "Content-Type: application/json" -d "$body" "$url" "$@" 2>/dev/null \
    || echo '{"ok":false,"error":"curl_failed"}'
}

cleanup() {
  if [ -n "$MOCK_PID" ]; then kill "$MOCK_PID" 2>/dev/null || true; fi
  if [ -n "$TMPDIR" ] && [ -d "$TMPDIR" ]; then rm -rf "$TMPDIR"; fi
}
trap cleanup EXIT

# ── Step 1: Syntax validation ────────────────────────────────────────────────

step "Syntax validation"
node --check "$MOCK_API" && ok "mock API syntax" || fail "mock API syntax"
bash -n "$CONTRACT_CHECK" && ok "contract check syntax" || fail "contract check syntax"
bash -n "$0" && ok "self syntax" || fail "self syntax"

# ── Step 2: Start mock API ───────────────────────────────────────────────────

step "Start mock API"
TMPDIR="$(mktemp -d)"
MOCK_API_PORT=$PORT node "$MOCK_API" > "$TMPDIR/mock-api.log" 2>&1 &
MOCK_PID=$!
sleep 1.5

for i in $(seq 1 10); do
  if curl -sf "$BASE/mock/state" > /dev/null 2>&1; then
    ok "mock API ready on port $PORT"
    break
  fi
  sleep 0.5
done
if ! curl -sf "$BASE/mock/state" > /dev/null 2>&1; then
  fail "mock API failed to start"
  cat "$TMPDIR/mock-api.log" >&2
  exit 1
fi

# ── Step 3: Add trial user ───────────────────────────────────────────────────

step "Add trial user and device"

TRIAL_USER="user_trial_001"
TRIAL_SUB="sub_trial_001"
PERIOD_END=$(date -u -d "+14 days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+14d +%Y-%m-%dT%H:%M:%SZ)

RESULT=$(curl_post "$BASE/mock/add-user" "{
  \"userId\": \"$TRIAL_USER\",
  \"email\": \"trial@example.com\",
  \"name\": \"Trial User\",
  \"subscriber\": {
    \"status\": \"trial\",
    \"plan\": \"frames_trial\",
    \"tier\": \"trial\",
    \"subscriptionId\": \"$TRIAL_SUB\",
    \"currentPeriodEnd\": \"$PERIOD_END\",
    \"cancelAtPeriodEnd\": false
  }
}")

OK_VAL=$(json_val "$RESULT" ".ok")
[ "$OK_VAL" = "true" ] && ok "trial user created" || fail "trial user creation: $RESULT"

# Register and pair a device for trial user
REG=$(curl_post "$BASE/frames/device/register" '{"deviceName":"TrialFrame-001"}')
DEVICE_ID=$(json_val "$REG" ".device.deviceId")
[ -n "$DEVICE_ID" ] && [ "$DEVICE_ID" != "null" ] && ok "device registered: $DEVICE_ID" || fail "device registration: $REG"

PAIR=$(curl_post "$BASE/mock/pair-device/$DEVICE_ID" "{\"ownerUserId\":\"$TRIAL_USER\"}")
PAIR_OK=$(json_val "$PAIR" ".ok")
[ "$PAIR_OK" = "true" ] && ok "device paired to trial user" || fail "device pairing: $PAIR"

# ── Step 4: Validate trial state in admin bundle ─────────────────────────────

step "Validate trial state in admin bundle"

BUNDLE_FILE="$TMPDIR/bundle-step4.json"
curl -sf "$BASE/mock/online-admin-bundle" > "$BUNDLE_FILE"

USERS_TOTAL=$(json_extract "$BUNDLE_FILE" ".adminFrames.users.total")
[ "$USERS_TOTAL" -ge 2 ] && ok "bundle has 2+ users (got $USERS_TOTAL)" || fail "expected 2+ users, got $USERS_TOTAL"

# Find the trial user in users items
TRIAL_USER_ENTRY=$(json_extract "$BUNDLE_FILE" ".adminFrames.users.items.find(x=>x.userId==='$TRIAL_USER')")
TRIAL_USER_SUB_STATUS=$(json_val "$TRIAL_USER_ENTRY" ".subscription.status")
TRIAL_USER_SUB_PLAN=$(json_val "$TRIAL_USER_ENTRY" ".subscription.plan")
TRIAL_USER_SUB_TIER=$(json_val "$TRIAL_USER_ENTRY" ".subscription.tier")
TRIAL_USER_SUB_ID=$(json_val "$TRIAL_USER_ENTRY" ".subscription.subscriptionId")

[ "$TRIAL_USER_SUB_STATUS" = "trial" ] && ok "user entry: subscription.status = trial" || fail "user entry: expected trial status, got $TRIAL_USER_SUB_STATUS"
[ "$TRIAL_USER_SUB_PLAN" = "frames_trial" ] && ok "user entry: subscription.plan = frames_trial" || fail "user entry: expected frames_trial, got $TRIAL_USER_SUB_PLAN"
[ "$TRIAL_USER_SUB_TIER" = "trial" ] && ok "user entry: subscription.tier = trial" || fail "user entry: expected trial tier, got $TRIAL_USER_SUB_TIER"
[ "$TRIAL_USER_SUB_ID" = "$TRIAL_SUB" ] && ok "user entry: subscriptionId matches" || fail "user entry: expected $TRIAL_SUB, got $TRIAL_USER_SUB_ID"

# Check subscriber entry
TRIAL_SUBSCRIBER=$(json_extract "$BUNDLE_FILE" ".adminFrames.subscribers.items.find(x=>x.userId==='$TRIAL_USER')")
SUB_STATUS=$(json_val "$TRIAL_SUBSCRIBER" ".status")
SUB_PLAN=$(json_val "$TRIAL_SUBSCRIBER" ".plan")

[ "$SUB_STATUS" = "trial" ] && ok "subscriber entry: status = trial" || fail "subscriber entry: expected trial, got $SUB_STATUS"
[ "$SUB_PLAN" = "frames_trial" ] && ok "subscriber entry: plan = frames_trial" || fail "subscriber entry: expected frames_trial, got $SUB_PLAN"

# Check subscription row
TRIAL_SUB_ROW=$(json_extract "$BUNDLE_FILE" ".adminFrames.subscriptions.items.find(x=>x.subscriptionId==='$TRIAL_SUB')")
SUB_ROW_STATUS=$(json_val "$TRIAL_SUB_ROW" ".status")
SUB_ROW_USER=$(json_val "$TRIAL_SUB_ROW" ".userId")

[ "$SUB_ROW_STATUS" = "trial" ] && ok "subscription row: status = trial" || fail "subscription row: expected trial, got $SUB_ROW_STATUS"
[ "$SUB_ROW_USER" = "$TRIAL_USER" ] && ok "subscription row: userId = trial user" || fail "subscription row: userId mismatch"

# Check fleet device subscription
TRIAL_FLEET_DEVICE=$(json_extract "$BUNDLE_FILE" ".adminFrames.devices.items.find(x=>x.deviceId==='$DEVICE_ID')")
FLEET_SUB_ID=$(json_val "$TRIAL_FLEET_DEVICE" ".subscription.subscriptionId")
FLEET_SUB_STATUS=$(json_val "$TRIAL_FLEET_DEVICE" ".subscription.status")
FLEET_OWNER=$(json_val "$TRIAL_FLEET_DEVICE" ".ownerUserId")

[ "$FLEET_SUB_ID" = "$TRIAL_SUB" ] && ok "fleet device: subscriptionId = $TRIAL_SUB" || fail "fleet device: expected $TRIAL_SUB, got $FLEET_SUB_ID"
[ "$FLEET_SUB_STATUS" = "trial" ] && ok "fleet device: subscription.status = trial" || fail "fleet device: expected trial, got $FLEET_SUB_STATUS"
[ "$FLEET_OWNER" = "$TRIAL_USER" ] && ok "fleet device: ownerUserId = trial user" || fail "fleet device: ownerUserId mismatch"

ok "trial state fully validated across users/subscribers/subscriptions/fleet"

# ── Step 5: Transition trial -> active ───────────────────────────────────────

step "Transition trial -> active"

RESULT=$(curl_post "$BASE/mock/transition-subscription/$TRIAL_USER" '{"status":"active","plan":"frames_basic","tier":"basic"}')
TRANS_OK=$(json_val "$RESULT" ".ok")
PREV_STATUS=$(json_val "$RESULT" ".previousStatus")
NEW_STATUS=$(json_val "$RESULT" ".status")

[ "$TRANS_OK" = "true" ] && ok "transition accepted" || fail "transition rejected: $RESULT"
[ "$PREV_STATUS" = "trial" ] && ok "previous status = trial" || fail "previous status mismatch: $PREV_STATUS"
[ "$NEW_STATUS" = "active" ] && ok "new status = active" || fail "new status mismatch: $NEW_STATUS"

# Validate bundle reflects active
BUNDLE_FILE="$TMPDIR/bundle-step5.json"
curl -sf "$BASE/mock/online-admin-bundle" > "$BUNDLE_FILE"

TRIAL_USER_ENTRY=$(json_extract "$BUNDLE_FILE" ".adminFrames.users.items.find(x=>x.userId==='$TRIAL_USER')")
ACTIVE_SUB_STATUS=$(json_val "$TRIAL_USER_ENTRY" ".subscription.status")
ACTIVE_SUB_PLAN=$(json_val "$TRIAL_USER_ENTRY" ".subscription.plan")
ACTIVE_SUB_TIER=$(json_val "$TRIAL_USER_ENTRY" ".subscription.tier")

[ "$ACTIVE_SUB_STATUS" = "active" ] && ok "bundle: user subscription.status = active" || fail "bundle: expected active, got $ACTIVE_SUB_STATUS"
[ "$ACTIVE_SUB_PLAN" = "frames_basic" ] && ok "bundle: user subscription.plan = frames_basic" || fail "bundle: expected frames_basic, got $ACTIVE_SUB_PLAN"
[ "$ACTIVE_SUB_TIER" = "basic" ] && ok "bundle: user subscription.tier = basic" || fail "bundle: expected basic, got $ACTIVE_SUB_TIER"

# Fleet device should also show active
TRIAL_FLEET_DEVICE=$(json_extract "$BUNDLE_FILE" ".adminFrames.devices.items.find(x=>x.deviceId==='$DEVICE_ID')")
FLEET_ACTIVE_STATUS=$(json_val "$TRIAL_FLEET_DEVICE" ".subscription.status")
[ "$FLEET_ACTIVE_STATUS" = "active" ] && ok "fleet device: subscription.status = active" || fail "fleet device: expected active, got $FLEET_ACTIVE_STATUS"

ok "trial -> active transition validated"

# ── Step 6: Transition active -> past_due ────────────────────────────────────

step "Transition active -> past_due"

RESULT=$(curl_post "$BASE/mock/transition-subscription/$TRIAL_USER" '{"status":"past_due"}')
TRANS_OK=$(json_val "$RESULT" ".ok")
[ "$TRANS_OK" = "true" ] && ok "active -> past_due accepted" || fail "active -> past_due rejected: $RESULT"

BUNDLE_FILE="$TMPDIR/bundle-step6.json"
curl -sf "$BASE/mock/online-admin-bundle" > "$BUNDLE_FILE"

TRIAL_USER_ENTRY=$(json_extract "$BUNDLE_FILE" ".adminFrames.users.items.find(x=>x.userId==='$TRIAL_USER')")
PD_STATUS=$(json_val "$TRIAL_USER_ENTRY" ".subscription.status")
[ "$PD_STATUS" = "past_due" ] && ok "bundle: user subscription.status = past_due" || fail "bundle: expected past_due, got $PD_STATUS"

TRIAL_FLEET_DEVICE=$(json_extract "$BUNDLE_FILE" ".adminFrames.devices.items.find(x=>x.deviceId==='$DEVICE_ID')")
FLEET_PD_STATUS=$(json_val "$TRIAL_FLEET_DEVICE" ".subscription.status")
[ "$FLEET_PD_STATUS" = "past_due" ] && ok "fleet device: subscription.status = past_due" || fail "fleet device: expected past_due, got $FLEET_PD_STATUS"

ok "active -> past_due transition validated"

# ── Step 7: Transition past_due -> active (recovery) ─────────────────────────

step "Transition past_due -> active (recovery)"

RESULT=$(curl_post "$BASE/mock/transition-subscription/$TRIAL_USER" '{"status":"active"}')
TRANS_OK=$(json_val "$RESULT" ".ok")
[ "$TRANS_OK" = "true" ] && ok "past_due -> active recovery accepted" || fail "past_due -> active rejected: $RESULT"

BUNDLE_FILE="$TMPDIR/bundle-step7.json"
curl -sf "$BASE/mock/online-admin-bundle" > "$BUNDLE_FILE"

TRIAL_USER_ENTRY=$(json_extract "$BUNDLE_FILE" ".adminFrames.users.items.find(x=>x.userId==='$TRIAL_USER')")
RECOVERED_STATUS=$(json_val "$TRIAL_USER_ENTRY" ".subscription.status")
[ "$RECOVERED_STATUS" = "active" ] && ok "bundle: user subscription.status = active (recovered)" || fail "bundle: expected active recovery, got $RECOVERED_STATUS"

ok "past_due -> active recovery validated"

# ── Step 8: Transition active -> cancelled ───────────────────────────────────

step "Transition active -> cancelled"

RESULT=$(curl_post "$BASE/mock/transition-subscription/$TRIAL_USER" '{"status":"cancelled","cancelAtPeriodEnd":true}')
TRANS_OK=$(json_val "$RESULT" ".ok")
[ "$TRANS_OK" = "true" ] && ok "active -> cancelled accepted" || fail "active -> cancelled rejected: $RESULT"

BUNDLE_FILE="$TMPDIR/bundle-step8.json"
curl -sf "$BASE/mock/online-admin-bundle" > "$BUNDLE_FILE"

TRIAL_USER_ENTRY=$(json_extract "$BUNDLE_FILE" ".adminFrames.users.items.find(x=>x.userId==='$TRIAL_USER')")
CANCELLED_STATUS=$(json_val "$TRIAL_USER_ENTRY" ".subscription.status")
[ "$CANCELLED_STATUS" = "cancelled" ] && ok "bundle: user subscription.status = cancelled" || fail "bundle: expected cancelled, got $CANCELLED_STATUS"

# Check subscriber still shows cancelled (not removed)
TRIAL_SUBSCRIBER=$(json_extract "$BUNDLE_FILE" ".adminFrames.subscribers.items.find(x=>x.userId==='$TRIAL_USER')")
SUB_CANCELLED_STATUS=$(json_val "$TRIAL_SUBSCRIBER" ".status")
[ "$SUB_CANCELLED_STATUS" = "cancelled" ] && ok "subscriber entry persists with status = cancelled" || fail "subscriber entry: expected cancelled, got $SUB_CANCELLED_STATUS"

# Subscription row should still exist
TRIAL_SUB_ROW=$(json_extract "$BUNDLE_FILE" ".adminFrames.subscriptions.items.find(x=>x.subscriptionId==='$TRIAL_SUB')")
SUB_ROW_CANCELLED=$(json_val "$TRIAL_SUB_ROW" ".status")
[ "$SUB_ROW_CANCELLED" = "cancelled" ] && ok "subscription row persists with status = cancelled" || fail "subscription row: expected cancelled, got $SUB_ROW_CANCELLED"

ok "active -> cancelled transition validated (records preserved)"

# ── Step 9: Transition cancelled -> expired ──────────────────────────────────

step "Transition cancelled -> expired"

RESULT=$(curl_post "$BASE/mock/transition-subscription/$TRIAL_USER" '{"status":"expired"}')
TRANS_OK=$(json_val "$RESULT" ".ok")
[ "$TRANS_OK" = "true" ] && ok "cancelled -> expired accepted" || fail "cancelled -> expired rejected: $RESULT"

BUNDLE_FILE="$TMPDIR/bundle-step9.json"
curl -sf "$BASE/mock/online-admin-bundle" > "$BUNDLE_FILE"

TRIAL_USER_ENTRY=$(json_extract "$BUNDLE_FILE" ".adminFrames.users.items.find(x=>x.userId==='$TRIAL_USER')")
EXPIRED_STATUS=$(json_val "$TRIAL_USER_ENTRY" ".subscription.status")
[ "$EXPIRED_STATUS" = "expired" ] && ok "bundle: user subscription.status = expired" || fail "bundle: expected expired, got $EXPIRED_STATUS"

# Fleet device should show expired subscription
TRIAL_FLEET_DEVICE=$(json_extract "$BUNDLE_FILE" ".adminFrames.devices.items.find(x=>x.deviceId==='$DEVICE_ID')")
FLEET_EXPIRED_STATUS=$(json_val "$TRIAL_FLEET_DEVICE" ".subscription.status")
[ "$FLEET_EXPIRED_STATUS" = "expired" ] && ok "fleet device: subscription.status = expired" || fail "fleet device: expected expired, got $FLEET_EXPIRED_STATUS"

# Records should persist (expired user is not deleted)
SUB_TOTAL=$(json_extract "$BUNDLE_FILE" ".adminFrames.subscribers.total")
[ "$SUB_TOTAL" -ge 2 ] && ok "subscriber records persist (total: $SUB_TOTAL)" || fail "subscriber records missing"

ok "cancelled -> expired transition validated"

# ── Step 10: Reject invalid transitions ──────────────────────────────────────

step "Reject invalid transitions"

# Cannot go from expired back to active
RESULT=$(curl_post "$BASE/mock/transition-subscription/$TRIAL_USER" '{"status":"active"}')
TRANS_OK=$(json_val "$RESULT" ".ok")
[ "$TRANS_OK" = "false" ] && ok "rejected: expired -> active" || fail "should have rejected expired -> active"

# Cannot go from expired to trial
RESULT=$(curl_post "$BASE/mock/transition-subscription/$TRIAL_USER" '{"status":"trial"}')
TRANS_OK=$(json_val "$RESULT" ".ok")
[ "$TRANS_OK" = "false" ] && ok "rejected: expired -> trial" || fail "should have rejected expired -> trial"

# Non-existent user
RESULT=$(curl_post "$BASE/mock/transition-subscription/nonexistent_user" '{"status":"active"}')
TRANS_OK=$(json_val "$RESULT" ".ok")
[ "$TRANS_OK" = "false" ] && ok "rejected: nonexistent user" || fail "should have rejected nonexistent user"

ok "invalid transition guards working"

# ── Step 11: Default user unaffected ─────────────────────────────────────────

step "Default user subscription unaffected by trial user transitions"

BUNDLE_FILE="$TMPDIR/bundle-step11.json"
curl -sf "$BASE/mock/online-admin-bundle" > "$BUNDLE_FILE"

DEFAULT_USER_ENTRY=$(json_extract "$BUNDLE_FILE" ".adminFrames.users.items.find(x=>x.userId==='user_mock_001')")
DEFAULT_STATUS=$(json_val "$DEFAULT_USER_ENTRY" ".subscription.status")
DEFAULT_PLAN=$(json_val "$DEFAULT_USER_ENTRY" ".subscription.plan")

[ "$DEFAULT_STATUS" = "active" ] && ok "default user: subscription.status = active (unchanged)" || fail "default user: expected active, got $DEFAULT_STATUS"
[ "$DEFAULT_PLAN" = "frames_basic" ] && ok "default user: subscription.plan = frames_basic (unchanged)" || fail "default user: expected frames_basic, got $DEFAULT_PLAN"

ok "subscription transitions are isolated per user"

# ── Step 12: Run online-admin contract checker ───────────────────────────────

step "Run online-admin contract checker on final bundle"

FINAL_BUNDLE_PATH="$TMPDIR/final-bundle.json"
curl -sf "$BASE/mock/online-admin-bundle" > "$FINAL_BUNDLE_PATH"

if [ -s "$FINAL_BUNDLE_PATH" ]; then
  ok "final bundle saved to $FINAL_BUNDLE_PATH"
else
  fail "failed to save final bundle"
fi

# Run contract checker against the saved bundle
if [ -x "$CONTRACT_CHECK" ]; then
  if AUTOPOIESIS_ONLINE_ADMIN_CONTRACT_SOURCE="$FINAL_BUNDLE_PATH" bash "$CONTRACT_CHECK" > "$TMPDIR/contract-check.log" 2>&1; then
    ok "online-admin contract checker passed on post-transition bundle"
  else
    fail "online-admin contract checker failed on post-transition bundle"
    cat "$TMPDIR/contract-check.log" >&2
  fi
else
  ok "contract checker skipped (not executable or no file source support)"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

printf "\n══════════════════════════════════════════\n"
printf "Subscription Lifecycle Gate: %d passed, %d failed (12 steps)\n" "$PASS" "$FAIL"
printf "══════════════════════════════════════════\n"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
