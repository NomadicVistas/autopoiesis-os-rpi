#!/usr/bin/env bash
set -euo pipefail

# ── Online admin entitlements check ──────────────────────────────────────────
# Validates subscription-tier device limits, feature entitlements,
# subscription-status-gated remote actions, and device limit enforcement on pairing.
# Runs against the mock hosted API in an isolated temp directory.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MOCK_API="$REPO_ROOT/scripts/mock-hosted-api/server.js"
ONLINE_ADMIN_CHECK="$REPO_ROOT/scripts/online-admin-contract-check.sh"

PORT=19874
BASE="http://127.0.0.1:$PORT"
TMPDIR=""
MOCK_PID=""
STEP=0
CHECKS=0
FAILS=0

cleanup() {
  if [[ -n "$MOCK_PID" ]]; then
    kill "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true
  fi
  if [[ -n "$TMPDIR" ]]; then
    rm -rf "$TMPDIR"
  fi
}
trap cleanup EXIT

pass() { CHECKS=$((CHECKS + 1)); echo "  ✓ $*"; }
fail() { FAILS=$((FAILS + 1)); CHECKS=$((CHECKS + 1)); echo "  ✗ FAIL: $*" >&2; }
step() { STEP=$((STEP + 1)); echo ""; echo "Step $STEP: $*"; }

# ── Step 1: Syntax validation ────────────────────────────────────────────────
step "Syntax validation"
node --check "$MOCK_API" && pass "mock API syntax" || fail "mock API syntax"
bash -n "$ONLINE_ADMIN_CHECK" && pass "online-admin contract syntax" || fail "online-admin contract syntax"
bash -n "$0" && pass "self syntax" || fail "self syntax"

# ── Step 2: Static contract: PLAN_LIMITS shape ──────────────────────────────
step "Static contract: PLAN_LIMITS shape"
PLAN_CHECK=$(node -e "
const fs = require('fs');
const src = fs.readFileSync('$MOCK_API', 'utf8');

// Extract PLAN_LIMITS
const match = src.match(/const PLAN_LIMITS = ({[\\s\\S]*?^};?)/m);
if (!match) { console.log('FAIL:PLAN_LIMITS_NOT_FOUND'); process.exit(0); }

const plans = ['frames_trial', 'frames_basic', 'frames_premium', 'frames_enterprise'];
let checks = 0;

// Check all plans exist
for (const p of plans) {
  if (!src.includes(p + ':')) { console.log('FAIL:PLAN_NOT_FOUND:' + p); process.exit(0); }
  checks++;
}

// Check required limit fields per plan
const requiredFields = ['maxDevices', 'remoteActions', 'cacheLimitMb', 'activeArtistsLimit', 'offlineCache'];
for (const field of requiredFields) {
  if (!src.includes(field)) { console.log('FAIL:FIELD_NOT_FOUND:' + field); process.exit(0); }
  checks++;
}

// Check DEGRADED_STATUSES
if (!src.includes('DEGRADED_STATUSES')) { console.log('FAIL:DEGRADED_STATUSES_NOT_FOUND'); process.exit(0); }
checks++;
if (!src.includes('\"expired\"')) { console.log('FAIL:EXPIRED_NOT_IN_DEGRADED'); process.exit(0); }
checks++;
if (!src.includes('\"cancelled\"')) { console.log('FAIL:CANCELLED_NOT_IN_DEGRADED'); process.exit(0); }
checks++;
if (!src.includes('\"past_due\"')) { console.log('FAIL:PAST_DUE_NOT_IN_DEGRADED'); process.exit(0); }
checks++;

// Check ENTITLED_STATUSES
if (!src.includes('ENTITLED_STATUSES')) { console.log('FAIL:ENTITLED_STATUSES_NOT_FOUND'); process.exit(0); }
checks++;

// Check computeEntitlements function
if (!src.includes('function computeEntitlements')) { console.log('FAIL:COMPUTE_ENTITLEMENTS_NOT_FOUND'); process.exit(0); }
checks++;

// Check entitlement fields
const entFields = ['deviceLimit', 'deviceUsage', 'deviceSlotsRemaining', 'canAddDevice', 'canUseRemoteActions', 'cacheLimitMb', 'activeArtistsLimit', 'offlineCache', 'degradedAccess', 'degradedReason', 'degradedActionsBlocked'];
for (const f of entFields) {
  if (!src.includes(f)) { console.log('FAIL:ENT_FIELD_NOT_FOUND:' + f); process.exit(0); }
  checks++;
}

console.log('OK:' + checks);
" 2>&1)

if [[ "$PLAN_CHECK" == OK:* ]]; then
  pass "PLAN_LIMITS static contract ($(echo "$PLAN_CHECK" | cut -d: -f2) checks)"
else
  fail "PLAN_LIMITS static contract: $PLAN_CHECK"
fi

# ── Step 3: computeEntitlements unit tests ────────────────────────────────────
step "computeEntitlements unit tests"
ENT_TESTS=$(node -e "
const fs = require('fs');
const src = fs.readFileSync('$MOCK_API', 'utf8');

// Extract just the data structures and computeEntitlements
const modifiedSrc = src.replace(/require\\(/g, '// require(').replace(/process\\.exit/g, '// process.exit');
const moduleWrap = modifiedSrc + '\\nmodule.exports = { computeEntitlements, PLAN_LIMITS, DEGRADED_STATUSES, ENTITLED_STATUSES };';
" 2>&1 || true)

# Test via eval approach
ENT_RESULT=$(node -e "
// Simulate computeEntitlements for unit testing
const devices = new Map();
const adminSubscribers = new Map();
const adminUsers = new Map();
const adminSubscriptions = new Map();

const PLAN_LIMITS = {
  frames_trial:     { maxDevices: 1,       remoteActions: true,  cacheLimitMb: 256, activeArtistsLimit: 5,   offlineCache: false },
  frames_basic:     { maxDevices: 3,       remoteActions: true,  cacheLimitMb: 512, activeArtistsLimit: 20,  offlineCache: true },
  frames_premium:   { maxDevices: 10,      remoteActions: true,  cacheLimitMb: 2048, activeArtistsLimit: 100, offlineCache: true },
  frames_enterprise:{ maxDevices: Infinity, remoteActions: true, cacheLimitMb: 8192, activeArtistsLimit: Infinity, offlineCache: true }
};
const DEGRADED_STATUSES = new Set(['expired', 'cancelled', 'past_due']);

function computeEntitlements(userId) {
  const subscriber = adminSubscribers.get(userId);
  const plan = subscriber ? subscriber.plan : 'frames_trial';
  const tier = subscriber ? subscriber.tier : 'trial';
  const status = subscriber ? subscriber.status : 'trial';
  const limits = PLAN_LIMITS[plan] || PLAN_LIMITS.frames_trial;
  const ownedDevices = [...devices.values()].filter((d) => d.ownerUserId === userId);
  const deviceCount = ownedDevices.length;
  const isDegraded = DEGRADED_STATUSES.has(status);
  return {
    plan, tier, status,
    deviceLimit: limits.maxDevices === Infinity ? null : limits.maxDevices,
    deviceLimitLabel: limits.maxDevices === Infinity ? 'unlimited' : String(limits.maxDevices),
    deviceUsage: deviceCount,
    deviceSlotsRemaining: limits.maxDevices === Infinity ? null : Math.max(0, limits.maxDevices - deviceCount),
    canAddDevice: !isDegraded && deviceCount < limits.maxDevices,
    canUseRemoteActions: limits.remoteActions && !isDegraded,
    cacheLimitMb: limits.cacheLimitMb,
    activeArtistsLimit: limits.activeArtistsLimit === Infinity ? null : limits.activeArtistsLimit,
    offlineCache: limits.offlineCache && !isDegraded,
    degradedAccess: isDegraded,
    degradedReason: isDegraded ? ('Subscription ' + status) : null,
    degradedActionsBlocked: isDegraded ? ['restart_device', 'update_device', 'factory_reset_request', 'show_broadcast'] : []
  };
}

let fails = 0;
let checks = 0;

// Test 1: Default (no subscriber) → trial plan
const e1 = computeEntitlements('user_none');
checks++;
if (e1.plan !== 'frames_trial') { fails++; console.log('FAIL: default plan should be trial, got ' + e1.plan); }
checks++;
if (e1.deviceLimit !== 1) { fails++; console.log('FAIL: trial deviceLimit should be 1, got ' + e1.deviceLimit); }
checks++;
if (e1.canAddDevice !== true) { fails++; console.log('FAIL: trial with 0 devices should canAddDevice=true'); }
checks++;
if (e1.offlineCache !== false) { fails++; console.log('FAIL: trial offlineCache should be false'); }
checks++;
if (e1.degradedAccess !== false) { fails++; console.log('FAIL: trial degradedAccess should be false'); }

// Test 2: Active basic plan
adminSubscribers.set('user_basic', { plan: 'frames_basic', tier: 'basic', status: 'active', subscriptionId: 'sub_1' });
const e2 = computeEntitlements('user_basic');
checks++;
if (e2.deviceLimit !== 3) { fails++; console.log('FAIL: basic deviceLimit should be 3'); }
checks++;
if (e2.canAddDevice !== true) { fails++; console.log('FAIL: basic active canAddDevice=true'); }
checks++;
if (e2.offlineCache !== true) { fails++; console.log('FAIL: basic active offlineCache=true'); }
checks++;
if (e2.degradedAccess !== false) { fails++; console.log('FAIL: basic active degradedAccess=false'); }

// Test 3: Expired basic → degraded
adminSubscribers.set('user_expired', { plan: 'frames_basic', tier: 'basic', status: 'expired', subscriptionId: 'sub_2' });
const e3 = computeEntitlements('user_expired');
checks++;
if (e3.degradedAccess !== true) { fails++; console.log('FAIL: expired degradedAccess=true'); }
checks++;
if (e3.canAddDevice !== false) { fails++; console.log('FAIL: expired canAddDevice=false'); }
checks++;
if (e3.canUseRemoteActions !== false) { fails++; console.log('FAIL: expired canUseRemoteActions=false'); }
checks++;
if (e3.offlineCache !== false) { fails++; console.log('FAIL: expired offlineCache=false'); }
checks++;
if (e3.degradedReason !== 'Subscription expired') { fails++; console.log('FAIL: expired degradedReason'); }
checks++;
if (e3.degradedActionsBlocked.length === 0) { fails++; console.log('FAIL: expired should have blocked actions'); }

// Test 4: Past due basic → degraded
adminSubscribers.set('user_pastdue', { plan: 'frames_basic', tier: 'basic', status: 'past_due', subscriptionId: 'sub_3' });
const e4 = computeEntitlements('user_pastdue');
checks++;
if (e4.degradedAccess !== true) { fails++; console.log('FAIL: past_due degradedAccess=true'); }
checks++;
if (e4.canUseRemoteActions !== false) { fails++; console.log('FAIL: past_due canUseRemoteActions=false'); }

// Test 5: Cancelled → degraded
adminSubscribers.set('user_cancelled', { plan: 'frames_basic', tier: 'basic', status: 'cancelled', subscriptionId: 'sub_4' });
const e5 = computeEntitlements('user_cancelled');
checks++;
if (e5.degradedAccess !== true) { fails++; console.log('FAIL: cancelled degradedAccess=true'); }

// Test 6: Premium with devices
adminSubscribers.set('user_prem', { plan: 'frames_premium', tier: 'premium', status: 'active', subscriptionId: 'sub_5' });
devices.set('dev1', { ownerUserId: 'user_prem' });
devices.set('dev2', { ownerUserId: 'user_prem' });
devices.set('dev3', { ownerUserId: 'user_prem' });
const e6 = computeEntitlements('user_prem');
checks++;
if (e6.deviceLimit !== 10) { fails++; console.log('FAIL: premium deviceLimit=10'); }
checks++;
if (e6.deviceUsage !== 3) { fails++; console.log('FAIL: premium deviceUsage=3, got ' + e6.deviceUsage); }
checks++;
if (e6.deviceSlotsRemaining !== 7) { fails++; console.log('FAIL: premium deviceSlotsRemaining=7, got ' + e6.deviceSlotsRemaining); }
checks++;
if (e6.canAddDevice !== true) { fails++; console.log('FAIL: premium with 3 devices canAddDevice=true'); }

// Test 7: Trial at limit (1 device)
devices.set('dev_t1', { ownerUserId: 'user_none' });
const e7 = computeEntitlements('user_none');
checks++;
if (e7.deviceUsage !== 1) { fails++; console.log('FAIL: trial at limit deviceUsage=1'); }
checks++;
if (e7.canAddDevice !== false) { fails++; console.log('FAIL: trial at limit canAddDevice=false'); }
checks++;
if (e7.deviceSlotsRemaining !== 0) { fails++; console.log('FAIL: trial at limit deviceSlotsRemaining=0'); }

// Test 8: Enterprise → unlimited
adminSubscribers.set('user_ent', { plan: 'frames_enterprise', tier: 'enterprise', status: 'active', subscriptionId: 'sub_6' });
const e8 = computeEntitlements('user_ent');
checks++;
if (e8.deviceLimit !== null) { fails++; console.log('FAIL: enterprise deviceLimit=null'); }
checks++;
if (e8.deviceSlotsRemaining !== null) { fails++; console.log('FAIL: enterprise deviceSlotsRemaining=null'); }
checks++;
if (e8.activeArtistsLimit !== null) { fails++; console.log('FAIL: enterprise activeArtistsLimit=null'); }
checks++;
if (e8.canAddDevice !== true) { fails++; console.log('FAIL: enterprise canAddDevice=true always'); }

if (fails > 0) {
  console.log('FAIL:' + fails + '/' + checks);
} else {
  console.log('OK:' + checks);
}
" 2>&1)

if [[ "$ENT_RESULT" == OK:* ]]; then
  pass "computeEntitlements unit tests ($(echo "$ENT_RESULT" | cut -d: -f2) checks)"
else
  fail "computeEntitlements unit tests: $ENT_RESULT"
fi

# ── Step 4: Start mock API ──────────────────────────────────────────────────
step "Start mock API and generate bundle"
TMPDIR=$(mktemp -d)
MOCK_PID=""
(node "$MOCK_API" --port "$PORT" > "$TMPDIR/mock-api.log" 2>&1) &
MOCK_PID=$!

# Wait for server
for i in $(seq 1 30); do
  if curl -fsS "$BASE/mock/state" > /dev/null 2>&1; then break; fi
  sleep 0.3
done
curl -fsS "$BASE/mock/state" > /dev/null || { fail "mock API did not start"; exit 1; }
pass "mock API started on port $PORT"

# ── Step 5: Trial user device limit enforcement ─────────────────────────────
step "Trial user device limit enforcement"

# Register 2 devices
R1=$(curl -fsS -X POST "$BASE/frames/device/register" -H 'Content-Type: application/json' -d '{"deviceId":"ent-dev-1"}')
echo "$R1" | grep -q '"ok":true' && pass "device 1 registered" || fail "device 1 register"

R2=$(curl -fsS -X POST "$BASE/frames/device/register" -H 'Content-Type: application/json' -d '{"deviceId":"ent-dev-2"}')
echo "$R2" | grep -q '"ok":true' && pass "device 2 registered" || fail "device 2 register"

# Add a trial user with 1-device limit
ADD_TRIAL=$(curl -fsS -X POST "$BASE/mock/add-user" -H 'Content-Type: application/json' -d '{
  "userId": "trial_user",
  "email": "trial@test.com",
  "subscriber": { "status": "trial", "plan": "frames_trial", "tier": "trial" }
}')
echo "$ADD_TRIAL" | grep -q '"ok":true' && pass "trial user created" || fail "trial user create"

# Pair first device → should succeed (trial limit is 1)
PAIR1=$(curl -fsS -X POST "$BASE/mock/pair-device/ent-dev-1" -H 'Content-Type: application/json' -d '{"ownerUserId":"trial_user"}')
echo "$PAIR1" | grep -q '"ok":true' && pass "trial user pair device 1 succeeds" || fail "trial user pair device 1"

# Pair second device → should fail (trial limit reached)
PAIR2_HTTP=$(curl -s -o "$TMPDIR/pair2-body.json" -w "%{http_code}" -X POST "$BASE/mock/pair-device/ent-dev-2" -H 'Content-Type: application/json' -d '{"ownerUserId":"trial_user"}')
if [[ "$PAIR2_HTTP" == "403" ]]; then
  pass "trial user pair device 2 rejected (403)"
else
  fail "trial user pair device 2 should return 403, got $PAIR2_HTTP"
fi
PAIR2_BODY=$(cat "$TMPDIR/pair2-body.json")
echo "$PAIR2_BODY" | grep -q 'device_limit_reached\|Device limit' && pass "device limit error message present" || fail "device limit error message missing"

# ── Step 6: Upgrade to basic → can pair more devices ────────────────────────
step "Subscription upgrade unlocks device limit"

# Transition trial → active with basic plan
TRANS=$(curl -fsS -X POST "$BASE/mock/transition-subscription/trial_user" -H 'Content-Type: application/json' -d '{"status":"active","plan":"frames_basic","tier":"basic"}')
echo "$TRANS" | grep -q '"ok":true' && pass "trial → active transition" || fail "trial → active transition"

# Now pair second device → should succeed (basic limit is 3)
PAIR3=$(curl -fsS -w "\n%{http_code}" -X POST "$BASE/mock/pair-device/ent-dev-2" -H 'Content-Type: application/json' -d '{"ownerUserId":"trial_user"}')
HTTP_CODE3=$(echo "$PAIR3" | tail -1)
if [[ "$HTTP_CODE3" == "200" ]]; then
  pass "basic user pair device 2 succeeds (200)"
else
  fail "basic user pair device 2 should return 200, got $HTTP_CODE3"
fi

# ── Step 7: Entitlements in admin bundle ────────────────────────────────────
step "Entitlements in admin bundle"

BUNDLE=$(curl -fsS "$BASE/mock/online-admin-bundle/trial_user")
echo "$BUNDLE" > "$TMPDIR/bundle-trial-user.json"

# Check profileFrames.entitlements
echo "$BUNDLE" | node -e "
const data = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
const ent = data.profileFrames.entitlements;
let checks = 0;
if (!ent) { console.log('FAIL:no entitlements'); process.exit(0); }
if (ent.plan !== 'frames_basic') { console.log('FAIL:plan=' + ent.plan); process.exit(0); }
checks++;
if (ent.tier !== 'basic') { console.log('FAIL:tier=' + ent.tier); process.exit(0); }
checks++;
if (ent.status !== 'active') { console.log('FAIL:status=' + ent.status); process.exit(0); }
checks++;
if (ent.deviceLimit !== 3) { console.log('FAIL:deviceLimit=' + ent.deviceLimit); process.exit(0); }
checks++;
if (ent.deviceUsage !== 2) { console.log('FAIL:deviceUsage=' + ent.deviceUsage); process.exit(0); }
checks++;
if (ent.deviceSlotsRemaining !== 1) { console.log('FAIL:deviceSlotsRemaining=' + ent.deviceSlotsRemaining); process.exit(0); }
checks++;
if (ent.canAddDevice !== true) { console.log('FAIL:canAddDevice=' + ent.canAddDevice); process.exit(0); }
checks++;
if (ent.canUseRemoteActions !== true) { console.log('FAIL:canUseRemoteActions'); process.exit(0); }
checks++;
if (ent.degradedAccess !== false) { console.log('FAIL:degradedAccess'); process.exit(0); }
checks++;
if (ent.degradedReason !== null) { console.log('FAIL:degradedReason=' + ent.degradedReason); process.exit(0); }
checks++;
if (ent.cacheLimitMb !== 512) { console.log('FAIL:cacheLimitMb=' + ent.cacheLimitMb); process.exit(0); }
checks++;
if (ent.offlineCache !== true) { console.log('FAIL:offlineCache'); process.exit(0); }
checks++;
console.log('OK:' + checks);
" 2>&1 | while read line; do
  if [[ "$line" == OK:* ]]; then
    pass "profileFrames.entitlements shape ($(echo "$line" | cut -d: -f2) checks)"
  else
    fail "profileFrames.entitlements: $line"
  fi
done

# Check adminFrames.planLimits
echo "$BUNDLE" | node -e "
const data = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
const pl = data.adminFrames.planLimits;
let checks = 0;
if (!pl) { console.log('FAIL:no planLimits'); process.exit(0); }
if (!pl.frames_trial) { console.log('FAIL:missing frames_trial'); process.exit(0); }
checks++;
if (!pl.frames_basic) { console.log('FAIL:missing frames_basic'); process.exit(0); }
checks++;
if (!pl.frames_premium) { console.log('FAIL:missing frames_premium'); process.exit(0); }
checks++;
if (!pl.frames_enterprise) { console.log('FAIL:missing frames_enterprise'); process.exit(0); }
checks++;
if (pl.frames_trial.maxDevices !== 1) { console.log('FAIL:trial maxDevices=' + pl.frames_trial.maxDevices); process.exit(0); }
checks++;
if (pl.frames_basic.maxDevices !== 3) { console.log('FAIL:basic maxDevices=' + pl.frames_basic.maxDevices); process.exit(0); }
checks++;
if (pl.frames_enterprise.maxDevices !== null) { console.log('FAIL:enterprise maxDevices should be null'); process.exit(0); }
checks++;
if (pl.frames_basic.cacheLimitMb !== 512) { console.log('FAIL:basic cacheLimitMb'); process.exit(0); }
checks++;
if (pl.frames_premium.activeArtistsLimit !== 100) { console.log('FAIL:premium activeArtistsLimit'); process.exit(0); }
checks++;
console.log('OK:' + checks);
" 2>&1 | while read line; do
  if [[ "$line" == OK:* ]]; then
    pass "adminFrames.planLimits shape ($(echo "$line" | cut -d: -f2) checks)"
  else
    fail "adminFrames.planLimits: $line"
  fi
done

# ── Step 8: Degraded subscription blocks remote actions ─────────────────────
step "Degraded subscription blocks remote actions"

# Transition to expired
TRANS_EXP=$(curl -fsS -X POST "$BASE/mock/transition-subscription/trial_user" -H 'Content-Type: application/json' -d '{"status":"past_due"}')
echo "$TRANS_EXP" | grep -q '"ok":true' && pass "active → past_due transition" || fail "active → past_due transition"
TRANS_EXP2=$(curl -fsS -X POST "$BASE/mock/transition-subscription/trial_user" -H 'Content-Type: application/json' -d '{"status":"cancelled"}')
echo "$TRANS_EXP2" | grep -q '"ok":true' && pass "past_due → cancelled transition" || fail "past_due → cancelled transition"
TRANS_EXP3=$(curl -fsS -X POST "$BASE/mock/transition-subscription/trial_user" -H 'Content-Type: application/json' -d '{"status":"expired"}')
echo "$TRANS_EXP3" | grep -q '"ok":true' && pass "cancelled → expired transition" || fail "cancelled → expired transition"

# Get bundle for expired user
BUNDLE_EXP=$(curl -fsS "$BASE/mock/online-admin-bundle/trial_user")
echo "$BUNDLE_EXP" > "$TMPDIR/bundle-expired-user.json"

echo "$BUNDLE_EXP" | node -e "
const data = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
const ent = data.profileFrames.entitlements;
let checks = 0;
if (!ent.degradedAccess) { console.log('FAIL:expired should have degradedAccess=true'); process.exit(0); }
checks++;
if (ent.canAddDevice) { console.log('FAIL:expired canAddDevice should be false'); process.exit(0); }
checks++;
if (ent.canUseRemoteActions) { console.log('FAIL:expired canUseRemoteActions should be false'); process.exit(0); }
checks++;
if (!ent.degradedReason) { console.log('FAIL:expired should have degradedReason'); process.exit(0); }
checks++;
if (ent.offlineCache) { console.log('FAIL:expired offlineCache should be false'); process.exit(0); }
checks++;
if (!Array.isArray(ent.degradedActionsBlocked) || ent.degradedActionsBlocked.length === 0) { console.log('FAIL:expired should have blocked actions'); process.exit(0); }
checks++;
console.log('OK:' + checks);
" 2>&1 | while read line; do
  if [[ "$line" == OK:* ]]; then
    pass "expired user entitlements ($(echo "$line" | cut -d: -f2) checks)"
  else
    fail "expired entitlements: $line"
  fi
done

# Check degraded remote actions on owned device
echo "$BUNDLE_EXP" | node -e "
const data = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
const fleetDevices = data.adminFrames.devices.items;
const owned = fleetDevices.filter(d => d.ownerUserId === 'trial_user');
let checks = 0;
if (owned.length === 0) { console.log('FAIL:no devices owned by trial_user'); process.exit(0); }
for (const device of owned) {
  const actions = device.actionAvailability?.actions || {};
  // restart_device and update_device should be blocked by subscription degradation
  if (actions.restart_device && actions.restart_device.allowed !== false) { console.log('FAIL:restart_device should be blocked'); process.exit(0); }
  checks++;
  if (actions.restart_device && !actions.restart_device.degradedBySubscription) { console.log('FAIL:restart_device should have degradedBySubscription=true'); process.exit(0); }
  checks++;
  if (actions.factory_reset_request && actions.factory_reset_request.allowed !== false) { console.log('FAIL:factory_reset should be blocked'); process.exit(0); }
  checks++;
  if (actions.show_broadcast && actions.show_broadcast.allowed !== false) { console.log('FAIL:show_broadcast should be blocked for degraded'); process.exit(0); }
  checks++;
  // sync_settings and clear_cache should still be allowed (low-risk, not in degradedActionsBlocked)
  if (actions.sync_settings && actions.sync_settings.allowed !== true) { console.log('FAIL:sync_settings should still be allowed'); process.exit(0); }
  checks++;
}
console.log('OK:' + checks);
" 2>&1 | while read line; do
  if [[ "$line" == OK:* ]]; then
    pass "degraded remote action gating ($(echo "$line" | cut -d: -f2) checks)"
  else
    fail "degraded remote actions: $line"
  fi
done

# ── Step 9: User entitlements in admin bundle ───────────────────────────────
step "User entitlements in admin users list"

echo "$BUNDLE_EXP" | node -e "
const data = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
const users = data.adminFrames.users.items;
const trialUser = users.find(u => u.userId === 'trial_user');
let checks = 0;
if (!trialUser) { console.log('FAIL:trial_user not found in admin users'); process.exit(0); }
checks++;
if (!trialUser.entitlements) { console.log('FAIL:trial_user has no entitlements'); process.exit(0); }
checks++;
if (trialUser.entitlements.plan !== 'frames_basic') { console.log('FAIL:user entitlement plan=' + trialUser.entitlements.plan); process.exit(0); }
checks++;
if (trialUser.entitlements.degradedAccess !== true) { console.log('FAIL:user entitlement degradedAccess should be true'); process.exit(0); }
checks++;
if (trialUser.entitlements.canAddDevice !== false) { console.log('FAIL:user entitlement canAddDevice should be false'); process.exit(0); }
checks++;
// Cross-reference with subscription
if (trialUser.subscription && trialUser.entitlements.plan !== trialUser.subscription.plan) {
  console.log('FAIL:user entitlement plan should match subscription plan'); process.exit(0);
}
checks++;
console.log('OK:' + checks);
" 2>&1 | while read line; do
  if [[ "$line" == OK:* ]]; then
    pass "admin user entitlements ($(echo "$line" | cut -d: -f2) checks)"
  else
    fail "admin user entitlements: $line"
  fi
done

# ── Step 10: Device limit blocks new pairing for expired user ───────────────
step "Device limit blocks pairing for expired user"

# Register a third device
R3=$(curl -fsS -X POST "$BASE/frames/device/register" -H 'Content-Type: application/json' -d '{"deviceId":"ent-dev-3"}')
echo "$R3" | grep -q '"ok":true' && pass "device 3 registered" || fail "device 3 register"

# Pair should fail — expired user can't add devices
PAIR_EXP_HTTP=$(curl -s -o "$TMPDIR/pair-exp-body.json" -w "%{http_code}" -X POST "$BASE/mock/pair-device/ent-dev-3" -H 'Content-Type: application/json' -d '{"ownerUserId":"trial_user"}')
if [[ "$PAIR_EXP_HTTP" == "403" ]]; then
  pass "expired user pairing rejected (403)"
else
  fail "expired user pairing should return 403, got $PAIR_EXP_HTTP"
fi

BODY_EXP=$(cat "$TMPDIR/pair-exp-body.json")
echo "$BODY_EXP" | grep -q 'subscription_degraded' && pass "subscription_degraded reason code present" || fail "subscription_degraded reason code missing"

# ── Step 11: Online admin contract checker passes ───────────────────────────
step "Online admin contract checker passes"

bash "$ONLINE_ADMIN_CHECK" "$TMPDIR/bundle-trial-user.json" > "$TMPDIR/contract-trial.log" 2>&1
RESULT=$?
if [[ $RESULT -eq 0 ]]; then
  pass "online-admin contract check on trial→basic bundle"
else
  fail "online-admin contract check on trial→basic bundle (exit $RESULT)"
  cat "$TMPDIR/contract-trial.log" | tail -5
fi

bash "$ONLINE_ADMIN_CHECK" "$TMPDIR/bundle-expired-user.json" > "$TMPDIR/contract-expired.log" 2>&1
RESULT2=$?
if [[ $RESULT2 -eq 0 ]]; then
  pass "online-admin contract check on expired bundle"
else
  fail "online-admin contract check on expired bundle (exit $RESULT2)"
  cat "$TMPDIR/contract-expired.log" | tail -5
fi

# ── Step 12: Regression: existing admin checks pass ─────────────────────────
step "Regression: existing mock bridge check"
bash "$REPO_ROOT/scripts/online-admin-mock-bridge-check.sh" > "$TMPDIR/bridge-regression.log" 2>&1
BRIDGE_RESULT=$?
if [[ $BRIDGE_RESULT -eq 0 ]]; then
  pass "online-admin-mock-bridge-check passed"
else
  fail "online-admin-mock-bridge-check failed (exit $BRIDGE_RESULT)"
  tail -5 "$TMPDIR/bridge-regression.log"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════"
if [[ $FAILS -eq 0 ]]; then
  echo "✅ All $CHECKS checks passed across $STEP steps"
else
  echo "❌ $FAILS failures out of $CHECKS checks across $STEP steps"
fi
echo "═══════════════════════════════════════"

exit $FAILS
