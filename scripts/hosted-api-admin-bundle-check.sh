#!/usr/bin/env bash
# hosted-api-admin-bundle-check.sh
# Validation gate for the hosted API online admin bundle and device snapshot endpoints.
# Proves: fleet listing, user/subscription admin, profile frames, entitlements,
#         role-action matrix, action availability, device admin snapshot.
set -euo pipefail

CHECKS=0 PASS=0 FAIL=0
R=$(cd "$(dirname "$0")/.." && pwd)
DB="$R/data/test-admin-bundle-$$.db"
API_PID=""
API_PORT=$((31400 + $$ % 1000))
API_BASE="http://127.0.0.1:$API_PORT"

die()   { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
try()   { CHECKS=$((CHECKS+1)); if "$@"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi; }
assert(){ CHECKS=$((CHECKS+1)); if eval "$2"; then PASS=$((PASS+1)); else die "$1"; fi; }
cleanup(){ rm -f "$DB"; if [ -n "$API_PID" ]; then kill "$API_PID" 2>/dev/null || true; fi; }
trap cleanup EXIT

C() { printf "\033[36m%-14s\033[0m %s\n" "$1" "$2"; }

# ── Step 1: Syntax validation ─────────────────────────────────────────────────
C "STEP-1" "Syntax validation"
try node --check "$R/hosted-api/server.js"
try node --check "$R/hosted-api/db.js"
try bash -n "$0"

# ── Step 2: Static contract ────────────────────────────────────────────────────
C "STEP-2" "Static contract"

SERVER="$R/hosted-api/server.js"
DB_JS="$R/hosted-api/db.js"

# DB methods
try grep -q 'listDevices(' "$DB_JS"
try grep -q 'countDevicesByOwner(' "$DB_JS"
try grep -q 'listSubscriptions(' "$DB_JS"
try grep -q 'listOwnerUserIds(' "$DB_JS"

# Admin platform constants
try grep -q 'PLAN_LIMITS' "$SERVER"
try grep -q 'computeEntitlements(' "$SERVER"
try grep -q 'ROLE_ACTION_MATRIX' "$SERVER"
try grep -q 'buildActionAvailability(' "$SERVER"
try grep -q 'DEGRADED_STATUSES' "$SERVER"
try grep -q 'ONLINE_REQUIRED_ACTIONS' "$SERVER"
try grep -q 'DISABLED_BLOCKED_ACTIONS' "$SERVER"

# Plan limits tiers
for plan in frames_trial frames_basic frames_premium frames_enterprise; do
  try grep -q "$plan" "$SERVER"
done

# Role matrix roles
for role in admin owner maintainer support curator; do
  try grep -q "\"$role\"" "$SERVER"
done

# Routes
try grep -q '/frames/admin/bundle' "$SERVER"
try grep -q 'handleAdminBundle' "$SERVER"
try grep -q '/admin-snapshot' "$SERVER"
try grep -q 'handleAdminDeviceSnapshot' "$SERVER"

C "STEP-2" "Static contract done ($CHECKS checks so far)"

# ── Step 3: Server bootstrap ──────────────────────────────────────────────────
C "STEP-3" "Server bootstrap"

rm -f "$DB"
AOS_DB="$DB" AOS_PORT="$API_PORT" AOS_HOST="127.0.0.1" \
  node "$R/hosted-api/server.js" > /tmp/aos-admin-bundle-$$.log 2>&1 &
API_PID=$!

# Wait for server
for i in $(seq 1 30); do
  if curl -sf "$API_BASE/health" > /dev/null 2>&1; then break; fi
  sleep 0.3
done

HEALTH=$(curl -sf "$API_BASE/health")
assert "Health returns ok" 'echo "$HEALTH" | jq -e ".ok == true" > /dev/null'
assert "Health shows tables" 'echo "$HEALTH" | jq -e ".tables > 0" > /dev/null'

# ── Step 4: Register two devices, pair them ───────────────────────────────────
C "STEP-4" "Device registration and pairing"

REG1=$(curl -sf -X POST "$API_BASE/frames/device/register" \
  -H "Content-Type: application/json" \
  -d '{"softwareVersion":"0.1.0","deviceName":"Frame Alpha"}')
assert "Device 1 registration ok" 'echo "$REG1" | jq -e ".ok == true" > /dev/null'
DEV1=$(echo "$REG1" | jq -r '.device.deviceId')
KEY1=$(echo "$REG1" | jq -r '.device.deviceApiKey')
CODE1=$(echo "$REG1" | jq -r '.pairingCode')

REG2=$(curl -sf -X POST "$API_BASE/frames/device/register" \
  -H "Content-Type: application/json" \
  -d '{"softwareVersion":"0.2.0","deviceName":"Frame Beta"}')
assert "Device 2 registration ok" 'echo "$REG2" | jq -e ".ok == true" > /dev/null'
DEV2=$(echo "$REG2" | jq -r '.device.deviceId')
KEY2=$(echo "$REG2" | jq -r '.device.deviceApiKey')
CODE2=$(echo "$REG2" | jq -r '.pairingCode')

# Claim pairing codes via DB (simulating web app pair)
node -e "
const AosDb = require('$R/hosted-api/db');
const db = new AosDb('$DB');
const r1 = db.claimPairingCode('$CODE1', 'user-alice');
const r2 = db.claimPairingCode('$CODE2', 'user-alice');
if (!r1 || !r2) { process.exit(1); }
console.log('paired');
" > /dev/null

# Create subscription for user-alice
node -e "
const AosDb = require('$R/hosted-api/db');
const db = new AosDb('$DB');
db.upsertSubscription('user-alice', { plan: 'frames_basic', status: 'active' });
console.log('subscription created');
" > /dev/null

# Register and pair a third device with a different owner
REG3=$(curl -sf -X POST "$API_BASE/frames/device/register" \
  -H "Content-Type: application/json" \
  -d '{"softwareVersion":"0.1.0","deviceName":"Frame Gamma"}')
assert "Device 3 registration ok" 'echo "$REG3" | jq -e ".ok == true" > /dev/null'
DEV3=$(echo "$REG3" | jq -r '.device.deviceId')
KEY3=$(echo "$REG3" | jq -r '.device.deviceApiKey')
CODE3=$(echo "$REG3" | jq -r '.pairingCode')

node -e "
const AosDb = require('$R/hosted-api/db');
const db = new AosDb('$DB');
db.claimPairingCode('$CODE3', 'user-bob');
db.upsertSubscription('user-bob', { plan: 'frames_trial', status: 'trial' });
console.log('bob setup done');
" > /dev/null

# Set user preferences for alice
node -e "
const AosDb = require('$R/hosted-api/db');
const db = new AosDb('$DB');
db.setUserPreferences('user-alice', {
  activeArtists: ['vessel', 'sandman'],
  streamCategories: ['artwork', 'curatorial'],
  allowVideos: true,
  cacheLikedArtworks: true
});
console.log('prefs set');
" > /dev/null

# Like some artworks for alice
node -e "
const AosDb = require('$R/hosted-api/db');
const db = new AosDb('$DB');
db.likeArtwork('user-alice', 'artwork-001');
db.likeArtwork('user-alice', 'artwork-002');
console.log('likes set');
" > /dev/null

# Send heartbeats to make devices "online"
for dev_key in "$DEV1:$KEY1" "$DEV2:$KEY2" "$DEV3:$KEY3"; do
  DID="${dev_key%%:*}"
  DK="${dev_key##*:}"
  curl -sf -X POST "$API_BASE/frames/device/$DID/heartbeat" \
    -H "x-frame-device-key: $DK" \
    -H "Content-Type: application/json" \
    -d "{\"softwareVersion\":\"0.1.0\",\"currentMode\":\"display\"}" > /dev/null
done

C "STEP-4" "Devices registered and paired ($CHECKS checks so far)"

# ── Step 5: Admin bundle — structure ──────────────────────────────────────────
C "STEP-5" "Admin bundle structure"

BUNDLE=$(curl -sf "$API_BASE/frames/admin/bundle?userId=user-alice")
assert "Bundle ok" 'echo "$BUNDLE" | jq -e ".ok == true" > /dev/null'
assert "Bundle kind" 'echo "$BUNDLE" | jq -e ".kind == \"autopoiesis_frames_online_admin_bundle\"" > /dev/null'
assert "Bundle schemaVersion" 'echo "$BUNDLE" | jq -e ".schemaVersion == 1" > /dev/null'
assert "Bundle has generatedAt" 'echo "$BUNDLE" | jq -e ".generatedAt != null" > /dev/null'

# ── Step 6: Admin bundle — profile frames ─────────────────────────────────────
C "STEP-6" "Profile frames"

assert "Profile userId" 'echo "$BUNDLE" | jq -e ".profileFrames.userId == \"user-alice\"" > /dev/null'
assert "Profile has preferences" 'echo "$BUNDLE" | jq -e ".profileFrames.preferences != null" > /dev/null'
assert "Profile preferences activeArtists" 'echo "$BUNDLE" | jq -e ".profileFrames.preferences.activeArtists | length == 2" > /dev/null'
assert "Profile has likedArtworks" 'echo "$BUNDLE" | jq -e ".profileFrames.likedArtworks | length == 2" > /dev/null'
assert "Profile likedArtwork id" 'echo "$BUNDLE" | jq -e ".profileFrames.likedArtworks[0].artworkId == \"artwork-001\"" > /dev/null'
assert "Profile has devices" 'echo "$BUNDLE" | jq -e ".profileFrames.devices | length == 2" > /dev/null'
assert "Profile device has actionAvailability" 'echo "$BUNDLE" | jq -e ".profileFrames.devices[0].actionAvailability != null" > /dev/null'
assert "Profile has entitlements" 'echo "$BUNDLE" | jq -e ".profileFrames.entitlements != null" > /dev/null'
assert "Profile entitlements plan" 'echo "$BUNDLE" | jq -e ".profileFrames.entitlements.plan == \"frames_basic\"" > /dev/null'
assert "Profile entitlements canAddDevice" 'echo "$BUNDLE" | jq -e ".profileFrames.entitlements.canAddDevice == true" > /dev/null'
assert "Profile entitlements deviceUsage=2" 'echo "$BUNDLE" | jq -e ".profileFrames.entitlements.deviceUsage == 2" > /dev/null'
assert "Profile entitlements deviceLimit=3" 'echo "$BUNDLE" | jq -e ".profileFrames.entitlements.deviceLimit == 3" > /dev/null'
assert "Profile entitlements deviceSlotsRemaining=1" 'echo "$BUNDLE" | jq -e ".profileFrames.entitlements.deviceSlotsRemaining == 1" > /dev/null'

# ── Step 7: Admin bundle — admin frames ───────────────────────────────────────
C "STEP-7" "Admin frames"

assert "Admin has actor" 'echo "$BUNDLE" | jq -e ".adminFrames.actor.role == \"admin\"" > /dev/null'
assert "Admin users exist" 'echo "$BUNDLE" | jq -e ".adminFrames.users.total >= 2" > /dev/null'
assert "Admin subscriptions exist" 'echo "$BUNDLE" | jq -e ".adminFrames.subscriptions.total >= 1" > /dev/null'
assert "Admin devices exist" 'echo "$BUNDLE" | jq -e ".adminFrames.devices.total == 3" > /dev/null'
assert "Admin has planLimits" 'echo "$BUNDLE" | jq -e ".adminFrames.planLimits != null" > /dev/null'
assert "Admin has remoteActions" 'echo "$BUNDLE" | jq -e ".adminFrames.remoteActions != null" > /dev/null'
assert "Admin acceptedActorRoles" 'echo "$BUNDLE" | jq -e ".adminFrames.remoteActions.acceptedActorRoles | length == 5" > /dev/null'
assert "Admin has roleActionMatrix" 'echo "$BUNDLE" | jq -e ".adminFrames.remoteActions.roleActionMatrix | length == 5" > /dev/null'

# ── Step 8: Admin bundle — plan limits ─────────────────────────────────────────
C "STEP-8" "Plan limits"

for plan in frames_trial frames_basic frames_premium frames_enterprise; do
  assert "Plan limit $plan exists" "echo \"\$BUNDLE\" | jq -e \".adminFrames.planLimits.$plan != null\" > /dev/null"
done
assert "Trial maxDevices=1" 'echo "$BUNDLE" | jq -e ".adminFrames.planLimits.frames_trial.maxDevices == 1" > /dev/null'
assert "Basic maxDevices=3" 'echo "$BUNDLE" | jq -e ".adminFrames.planLimits.frames_basic.maxDevices == 3" > /dev/null'
assert "Premium maxDevices=10" 'echo "$BUNDLE" | jq -e ".adminFrames.planLimits.frames_premium.maxDevices == 10" > /dev/null'
assert "Enterprise unlimited" 'echo "$BUNDLE" | jq -e ".adminFrames.planLimits.frames_enterprise.maxDevices == null" > /dev/null'
assert "Enterprise label" 'echo "$BUNDLE" | jq -e ".adminFrames.planLimits.frames_enterprise.maxDevicesLabel == \"unlimited\"" > /dev/null'

# ── Step 9: Admin bundle — fleet devices ───────────────────────────────────────
C "STEP-9" "Fleet devices"

assert "Fleet device has deviceId" 'echo "$BUNDLE" | jq -e ".adminFrames.devices.items[0].deviceId != null" > /dev/null'
assert "Fleet device has deviceName" 'echo "$BUNDLE" | jq -e ".adminFrames.devices.items[0].deviceName != null" > /dev/null'
assert "Fleet device has ownerUserId" 'echo "$BUNDLE" | jq -e ".adminFrames.devices.items[0].ownerUserId != null" > /dev/null'
assert "Fleet device has softwareVersion" 'echo "$BUNDLE" | jq -e ".adminFrames.devices.items[0].softwareVersion != null" > /dev/null'
assert "Fleet device has online status" 'echo "$BUNDLE" | jq -e ".adminFrames.devices.items[0].online == true" > /dev/null'
assert "Fleet device has paired=true" 'echo "$BUNDLE" | jq -e ".adminFrames.devices.items[0].paired == true" > /dev/null'
assert "Fleet device has actionAvailability" 'echo "$BUNDLE" | jq -e ".adminFrames.devices.items[0].actionAvailability != null" > /dev/null'
assert "Fleet device has actionAvailability.actions" 'echo "$BUNDLE" | jq -e ".adminFrames.devices.items[0].actionAvailability.actions != null" > /dev/null'
assert "Fleet device has deviceState" 'echo "$BUNDLE" | jq -e ".adminFrames.devices.items[0].actionAvailability.deviceState != null" > /dev/null'
assert "Fleet device deviceState.isPaired" 'echo "$BUNDLE" | jq -e ".adminFrames.devices.items[0].actionAvailability.deviceState.isPaired == true" > /dev/null'
assert "Fleet device deviceState.isOnline" 'echo "$BUNDLE" | jq -e ".adminFrames.devices.items[0].actionAvailability.deviceState.isOnline == true" > /dev/null'
assert "Fleet device has health" 'echo "$BUNDLE" | jq -e ".adminFrames.devices.items[0].health != null" > /dev/null'

# ── Step 10: Admin bundle — users with entitlements ────────────────────────────
C "STEP-10" "Users with entitlements"

# Check user-alice
ALICE_ENTRY=$(echo "$BUNDLE" | jq '.adminFrames.users.items[] | select(.userId == "user-alice")')
assert "User alice exists in admin users" '[ -n "$ALICE_ENTRY" ]'
assert "Alice frameCount=2" 'echo "$ALICE_ENTRY" | jq -e ".frameCount == 2" > /dev/null'
assert "Alice has subscription" 'echo "$ALICE_ENTRY" | jq -e ".subscription != null" > /dev/null'
assert "Alice subscription plan" 'echo "$ALICE_ENTRY" | jq -e ".subscription.plan == \"frames_basic\"" > /dev/null'
assert "Alice has entitlements" 'echo "$ALICE_ENTRY" | jq -e ".entitlements != null" > /dev/null'
assert "Alice entitlements plan" 'echo "$ALICE_ENTRY" | jq -e ".entitlements.plan == \"frames_basic\"" > /dev/null'
assert "Alice entitlements deviceUsage=2" 'echo "$ALICE_ENTRY" | jq -e ".entitlements.deviceUsage == 2" > /dev/null'

# Check user-bob
BOB_ENTRY=$(echo "$BUNDLE" | jq '.adminFrames.users.items[] | select(.userId == "user-bob")')
assert "User bob exists in admin users" '[ -n "$BOB_ENTRY" ]'
assert "Bob frameCount=1" 'echo "$BOB_ENTRY" | jq -e ".frameCount == 1" > /dev/null'
assert "Bob entitlements trial" 'echo "$BOB_ENTRY" | jq -e ".entitlements.plan == \"frames_trial\"" > /dev/null'
assert "Bob entitlements deviceLimit=1" 'echo "$BOB_ENTRY" | jq -e ".entitlements.deviceLimit == 1" > /dev/null'

# ── Step 11: Admin bundle — default (no userId) ───────────────────────────────
C "STEP-11" "Default bundle (no userId param)"

DEFAULT_BUNDLE=$(curl -sf "$API_BASE/frames/admin/bundle")
assert "Default bundle ok" 'echo "$DEFAULT_BUNDLE" | jq -e ".ok == true" > /dev/null'
assert "Default bundle has profileFrames" 'echo "$DEFAULT_BUNDLE" | jq -e ".profileFrames != null" > /dev/null'
assert "Default bundle has adminFrames" 'echo "$DEFAULT_BUNDLE" | jq -e ".adminFrames != null" > /dev/null'
assert "Default bundle has fleet devices" 'echo "$DEFAULT_BUNDLE" | jq -e ".adminFrames.devices.total == 3" > /dev/null'

# ── Step 12: Device admin snapshot ─────────────────────────────────────────────
C "STEP-12" "Device admin snapshot"

SNAP=$(curl -sf "$API_BASE/frames/device/$DEV1/admin-snapshot")
assert "Snapshot ok" 'echo "$SNAP" | jq -e ".ok == true" > /dev/null'
assert "Snapshot kind" 'echo "$SNAP" | jq -e ".kind == \"autopoiesis_frames_admin_device_snapshot\"" > /dev/null'
assert "Snapshot has device" 'echo "$SNAP" | jq -e ".device != null" > /dev/null'
assert "Snapshot deviceId" 'echo "$SNAP" | jq -e ".device.deviceId == \"$DEV1\"" > /dev/null'
assert "Snapshot deviceName present" 'echo "$SNAP" | jq -e ".device.deviceName != null" > /dev/null'
assert "Snapshot ownerUserId" 'echo "$SNAP" | jq -e ".device.ownerUserId == \"user-alice\"" > /dev/null'
assert "Snapshot paired" 'echo "$SNAP" | jq -e ".device.paired == true" > /dev/null'
assert "Snapshot online" 'echo "$SNAP" | jq -e ".device.online == true" > /dev/null'
assert "Snapshot has ownerSubscription" 'echo "$SNAP" | jq -e ".ownerSubscription != null" > /dev/null'
assert "Snapshot ownerSubscription plan" 'echo "$SNAP" | jq -e ".ownerSubscription.plan == \"frames_basic\"" > /dev/null'
assert "Snapshot has ownerEntitlements" 'echo "$SNAP" | jq -e ".ownerEntitlements != null" > /dev/null'
assert "Snapshot has actionAvailability" 'echo "$SNAP" | jq -e ".actionAvailability != null" > /dev/null'
assert "Snapshot actionAvailability.actions" 'echo "$SNAP" | jq -e ".actionAvailability.actions != null" > /dev/null'
assert "Snapshot actionAvailability.deviceState" 'echo "$SNAP" | jq -e ".actionAvailability.deviceState != null" > /dev/null'
assert "Snapshot has events" 'echo "$SNAP" | jq -e ".events != null" > /dev/null'
assert "Snapshot has pendingCommands" 'echo "$SNAP" | jq -e ".pendingCommands != null" > /dev/null'
assert "Snapshot admin actions: sync_settings allowed" 'echo "$SNAP" | jq -e ".actionAvailability.actions.sync_settings.allowed == true" > /dev/null'
assert "Snapshot admin actions: factory_reset allowed" 'echo "$SNAP" | jq -e ".actionAvailability.actions.factory_reset_request.allowed == true" > /dev/null'

# 404 for nonexistent device
SNAP_404=$(curl -s -o /dev/null -w "%{http_code}" "$API_BASE/frames/device/aos_nonexistent/admin-snapshot")
assert "Snapshot 404 for nonexistent" '[ "$SNAP_404" = "404" ]'

# ── Step 13: Action availability — role gating ─────────────────────────────────
C "STEP-13" "Role-based action availability"

# Admin actions on the first device
ADMIN_ACTIONS=$(echo "$BUNDLE" | jq '.adminFrames.devices.items[0].actionAvailability.actions')
assert "Admin can sync_settings" 'echo "$ADMIN_ACTIONS" | jq -e ".sync_settings.allowed == true" > /dev/null'
assert "Admin can factory_reset" 'echo "$ADMIN_ACTIONS" | jq -e ".factory_reset_request.allowed == true" > /dev/null'
assert "Admin can update_device" 'echo "$ADMIN_ACTIONS" | jq -e ".update_device.allowed == true" > /dev/null'

# Owner actions on profile device
OWNER_ACTIONS=$(echo "$BUNDLE" | jq '.profileFrames.devices[0].actionAvailability.actions')
assert "Owner can sync_settings" 'echo "$OWNER_ACTIONS" | jq -e ".sync_settings.allowed == true" > /dev/null'
assert "Owner can factory_reset" 'echo "$OWNER_ACTIONS" | jq -e ".factory_reset_request.allowed == true" > /dev/null'

# ── Step 14: Regression — existing endpoints still work ────────────────────────
C "STEP-14" "Regression check"

# Settings still work
SETTINGS=$(curl -sf "$API_BASE/frames/device/$DEV1/settings" \
  -H "x-frame-device-key: $KEY1")
assert "Settings endpoint still ok" 'echo "$SETTINGS" | jq -e ".ok == true" > /dev/null'

# Heartbeat still works
HB=$(curl -sf -X POST "$API_BASE/frames/device/$DEV1/heartbeat" \
  -H "x-frame-device-key: $KEY1" \
  -H "Content-Type: application/json" \
  -d '{"softwareVersion":"0.1.0","currentMode":"display"}')
assert "Heartbeat endpoint still ok" 'echo "$HB" | jq -e ".ok == true" > /dev/null'

# Stream still works
STREAM=$(curl -sf "$API_BASE/frames/device/$DEV1/stream" \
  -H "x-frame-device-key: $KEY1")
assert "Stream endpoint still ok" 'echo "$STREAM" | jq -e ".ok == true" > /dev/null'

# Health still works
H2=$(curl -sf "$API_BASE/health")
assert "Health still ok" 'echo "$H2" | jq -e ".ok == true" > /dev/null'

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  hosted-api-admin-bundle-check results"
echo "  Total: $CHECKS  Passed: $PASS  Failed: $FAIL"
echo "══════════════════════════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
  echo "  STATUS: FAILED"
  exit 1
else
  echo "  STATUS: ALL CHECKS PASSED"
  exit 0
fi
