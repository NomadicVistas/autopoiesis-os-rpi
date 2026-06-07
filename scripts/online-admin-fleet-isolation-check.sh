#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Online Admin Fleet Isolation Check
#
# Proves multi-device, multi-owner fleet isolation in the online admin bundle.
# Tests that:
#   - Each owner's Profile > Frames only shows their own devices
#   - Admin fleet shows all devices regardless of owner
#   - Subscription entitlements are properly attributed per owner
#   - Device ownership is consistent across profile and admin views
#   - No cross-owner device leakage occurs in profile bundles
#
# Uses the mock hosted API to register two devices under two different owners,
# walk their lifecycle, then fetch per-owner bundles and verify isolation.
#
# Usage:
#   scripts/online-admin-fleet-isolation-check.sh
#
# Environment:
#   ONLINE_ADMIN_FLEET_SKIP_CONTRACT  skip contract checker (default: 0)
# ─────────────────────────────────────────────────────────────────────────────

SKIP_CONTRACT="${ONLINE_ADMIN_FLEET_SKIP_CONTRACT:-0}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MOCK_API="$REPO_DIR/scripts/mock-hosted-api/server.js"
CONTRACT_CHECK="$REPO_DIR/scripts/online-admin-contract-check.sh"

MOCK_PORT=""
MOCK_PID=""
BUNDLE_A_FILE=""
BUNDLE_B_FILE=""

cleanup() {
  if [[ -n "$MOCK_PID" ]]; then
    kill "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true
  fi
  rm -f "$BUNDLE_A_FILE" "$BUNDLE_B_FILE"
}
trap cleanup EXIT

fail() {
  echo "online-admin-fleet-isolation-check failed: $*" >&2
  exit 1
}

step() {
  echo "  step $1: $2"
}

node_expr() {
  node -e "const d=require('fs').readFileSync('/dev/stdin','utf8');const j=JSON.parse(d);$1" 2>&1
}

# ── Requirements check ───────────────────────────────────────────────────────

[[ -f "$MOCK_API" ]] || fail "mock hosted API not found: $MOCK_API"
[[ -f "$CONTRACT_CHECK" ]] || fail "online-admin contract check not found: $CONTRACT_CHECK"
command -v node >/dev/null 2>&1 || fail "node is required"
command -v curl >/dev/null 2>&1 || fail "curl is required"

# ── Step 1: Start mock API on random port ────────────────────────────────────

MOCK_PORT=$(comm -23 <(seq 3160 3199) <(ss -tHln 'sport >= 3160 and sport <= 3199' | awk '{print $4}' | sed 's/.*://') | head -1)
[[ -n "$MOCK_PORT" ]] || fail "no available port in 3160-3199 range"

step 1 "starting mock hosted API on port $MOCK_PORT"
MOCK_API_BASE="http://127.0.0.1:$MOCK_PORT"

node "$MOCK_API" --port "$MOCK_PORT" &
MOCK_PID=$!

for i in $(seq 1 30); do
  if curl -fsS "$MOCK_API_BASE/mock/state" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done

curl -fsS "$MOCK_API_BASE/mock/state" >/dev/null 2>&1 || fail "mock API did not start"
echo "    mock API ready"

# ── Step 2: Add second owner user ───────────────────────────────────────────

step 2 "adding second owner user with pro subscription"

ADD_USER_B_BODY='{"userId":"user_owner_b","email":"owner-b@example.com","name":"Owner B","subscriber":{"status":"active","plan":"frames_pro","tier":"pro","currentPeriodEnd":"2026-08-01T00:00:00.000Z"}}'
ADD_USER_B_RESP=$(curl -fsS -X POST -H "content-type: application/json" -d "$ADD_USER_B_BODY" "$MOCK_API_BASE/mock/add-user")
ADD_USER_B_OK=$(echo "$ADD_USER_B_RESP" | node_expr "process.stdout.write(String(j.ok))")
[[ "$ADD_USER_B_OK" == "true" ]] || fail "add user B failed"
echo "    user_owner_b added with pro subscription"

# ── Step 3: Register and pair device A (owner A / default user) ──────────────

step 3 "registering and pairing device A for owner A"

DEV_A_RESP=$(curl -fsS -X POST -H "content-type: application/json" \
  -d '{"deviceName":"Owner A Frame","softwareVersion":"0.1.0","metadata":{"model":"Pi 5","ramMB":8192}}' \
  "$MOCK_API_BASE/frames/device/register")

DEV_A_ID=$(echo "$DEV_A_RESP" | node_expr "process.stdout.write(j.device.deviceId)")
DEV_A_KEY=$(echo "$DEV_A_RESP" | node_expr "process.stdout.write(j.device.deviceApiKey)")
[[ -n "$DEV_A_ID" ]] || fail "device A registration failed"
[[ -n "$DEV_A_KEY" ]] || fail "device A missing API key"

# Pair to default owner (user_mock_001)
curl -fsS -X POST "$MOCK_API_BASE/mock/pair-device/$DEV_A_ID" >/dev/null
echo "    device A registered and paired: $DEV_A_ID"

# ── Step 4: Register and pair device B (owner B) ────────────────────────────

step 4 "registering and pairing device B for owner B"

DEV_B_RESP=$(curl -fsS -X POST -H "content-type: application/json" \
  -d '{"deviceName":"Owner B Frame","softwareVersion":"0.2.0","metadata":{"model":"Pi 4","ramMB":4096}}' \
  "$MOCK_API_BASE/frames/device/register")

DEV_B_ID=$(echo "$DEV_B_RESP" | node_expr "process.stdout.write(j.device.deviceId)")
DEV_B_KEY=$(echo "$DEV_B_RESP" | node_expr "process.stdout.write(j.device.deviceApiKey)")
[[ -n "$DEV_B_ID" ]] || fail "device B registration failed"
[[ -n "$DEV_B_KEY" ]] || fail "device B missing API key"

# Pair to owner B
PAIR_B_BODY='{"ownerUserId":"user_owner_b"}'
PAIR_B_RESP=$(curl -fsS -X POST -H "content-type: application/json" -d "$PAIR_B_BODY" "$MOCK_API_BASE/mock/pair-device/$DEV_B_ID")
PAIR_B_OWNER=$(echo "$PAIR_B_RESP" | node_expr "process.stdout.write(j.ownerUserId)")
[[ "$PAIR_B_OWNER" == "user_owner_b" ]] || fail "device B not paired to owner B"
echo "    device B registered and paired to user_owner_b: $DEV_B_ID"

# ── Step 5: Sync settings for both devices ───────────────────────────────────

step 5 "syncing settings for both devices"

SETTINGS_A_BODY='{"settings":{"displayMode":"slideshow","shuffleInterval":45,"activeArtists":["artist-001"],"updatedAt":"2099-06-07T20:00:00.000Z"}}'
SETTINGS_A_RESP=$(curl -fsS -X POST -H "content-type: application/json" -H "x-frame-device-key: $DEV_A_KEY" -d "$SETTINGS_A_BODY" "$MOCK_API_BASE/frames/device/$DEV_A_ID/settings")
SETTINGS_A_OK=$(echo "$SETTINGS_A_RESP" | node_expr "process.stdout.write(String(j.ok))")
[[ "$SETTINGS_A_OK" == "true" ]] || fail "device A settings sync failed"

SETTINGS_B_BODY='{"settings":{"displayMode":"shuffle","shuffleInterval":60,"activeArtists":["artist-002","artist-003"],"updatedAt":"2099-06-07T20:01:00.000Z"}}'
SETTINGS_B_RESP=$(curl -fsS -X POST -H "content-type: application/json" -H "x-frame-device-key: $DEV_B_KEY" -d "$SETTINGS_B_BODY" "$MOCK_API_BASE/frames/device/$DEV_B_ID/settings")
SETTINGS_B_OK=$(echo "$SETTINGS_B_RESP" | node_expr "process.stdout.write(String(j.ok))")
[[ "$SETTINGS_B_OK" == "true" ]] || fail "device B settings sync failed"

echo "    both devices settings synced"

# ── Step 6: Send heartbeats for both devices ─────────────────────────────────

step 6 "sending heartbeats for both devices"

HB_A_BODY='{"softwareVersion":"0.1.0","events":[{"eventKey":"evt_a_1","type":"frame_item_displayed","observedAt":"2026-06-07T20:02:00.000Z","artworkId":"artwork-001"}]}'
HB_A_RESP=$(curl -fsS -X POST -H "content-type: application/json" -H "x-frame-device-key: $DEV_A_KEY" -d "$HB_A_BODY" "$MOCK_API_BASE/frames/device/$DEV_A_ID/heartbeat")
HB_A_OK=$(echo "$HB_A_RESP" | node_expr "process.stdout.write(String(j.ok))")
[[ "$HB_A_OK" == "true" ]] || fail "device A heartbeat failed"

HB_B_BODY='{"softwareVersion":"0.2.0","events":[{"eventKey":"evt_b_1","type":"frame_item_displayed","observedAt":"2026-06-07T20:03:00.000Z","artworkId":"artwork-002"}]}'
HB_B_RESP=$(curl -fsS -X POST -H "content-type: application/json" -H "x-frame-device-key: $DEV_B_KEY" -d "$HB_B_BODY" "$MOCK_API_BASE/frames/device/$DEV_B_ID/heartbeat")
HB_B_OK=$(echo "$HB_B_RESP" | node_expr "process.stdout.write(String(j.ok))")
[[ "$HB_B_OK" == "true" ]] || fail "device B heartbeat failed"

echo "    both heartbeats accepted"

# ── Step 7: Fetch per-owner bundles ──────────────────────────────────────────

step 7 "fetching per-owner bundles"

BUNDLE_A_RESP=$(curl -fsS "$MOCK_API_BASE/mock/online-admin-bundle")
BUNDLE_A_KIND=$(echo "$BUNDLE_A_RESP" | node_expr "process.stdout.write(j.kind || '')")
[[ "$BUNDLE_A_KIND" == "autopoiesis_frames_online_admin_bundle" ]] || fail "bundle A kind mismatch"

BUNDLE_B_RESP=$(curl -fsS "$MOCK_API_BASE/mock/online-admin-bundle/user_owner_b")
BUNDLE_B_KIND=$(echo "$BUNDLE_B_RESP" | node_expr "process.stdout.write(j.kind || '')")
[[ "$BUNDLE_B_KIND" == "autopoiesis_frames_online_admin_bundle" ]] || fail "bundle B kind mismatch"

BUNDLE_A_FILE=$(mktemp)
BUNDLE_B_FILE=$(mktemp)
echo "$BUNDLE_A_RESP" > "$BUNDLE_A_FILE"
echo "$BUNDLE_B_RESP" > "$BUNDLE_B_FILE"

echo "    bundle A (default owner) and bundle B (owner B) generated"

# ── Step 8: Verify Profile > Frames device isolation ─────────────────────────

step 8 "verifying Profile > Frames device isolation"

# Write both bundles to a combined temp file with a separator
COMBINED_FILE=$(mktemp)
trap 'rm -f $COMBINED_FILE' EXIT
echo "$BUNDLE_A_RESP" > "$COMBINED_FILE"

ISOLATION_RESULT=$(node -e "
  const fs = require('fs');
  const a = JSON.parse(fs.readFileSync('$BUNDLE_A_FILE', 'utf8'));
  const b = JSON.parse(fs.readFileSync('$BUNDLE_B_FILE', 'utf8'));

  // Bundle A: default user (user_mock_001)
  if (a.profileFrames.userId !== 'user_mock_001') {
    console.error('bundle A userId mismatch: ' + a.profileFrames.userId); process.exit(1);
  }
  // Bundle A profile devices: only device A
  const aDeviceIds = a.profileFrames.devices.map(d => d.deviceId);
  if (aDeviceIds.length !== 1) {
    console.error('bundle A profile should have 1 device, got ' + aDeviceIds.length); process.exit(1);
  }
  if (aDeviceIds[0] !== '$DEV_A_ID') {
    console.error('bundle A profile device should be device A, got ' + aDeviceIds[0]); process.exit(1);
  }
  // Bundle A profile device must be owned by user_mock_001
  if (a.profileFrames.devices[0].ownerUserId !== 'user_mock_001') {
    console.error('bundle A profile device owner mismatch'); process.exit(1);
  }
  // Bundle A profile must NOT contain device B
  if (aDeviceIds.includes('$DEV_B_ID')) {
    console.error('bundle A profile contains device B (cross-owner leak)'); process.exit(1);
  }

  // Bundle B: owner B (user_owner_b)
  if (b.profileFrames.userId !== 'user_owner_b') {
    console.error('bundle B userId mismatch: ' + b.profileFrames.userId); process.exit(1);
  }
  // Bundle B profile devices: only device B
  const bDeviceIds = b.profileFrames.devices.map(d => d.deviceId);
  if (bDeviceIds.length !== 1) {
    console.error('bundle B profile should have 1 device, got ' + bDeviceIds.length); process.exit(1);
  }
  if (bDeviceIds[0] !== '$DEV_B_ID') {
    console.error('bundle B profile device should be device B, got ' + bDeviceIds[0]); process.exit(1);
  }
  // Bundle B profile device must be owned by user_owner_b
  if (b.profileFrames.devices[0].ownerUserId !== 'user_owner_b') {
    console.error('bundle B profile device owner mismatch'); process.exit(1);
  }
  // Bundle B profile must NOT contain device A
  if (bDeviceIds.includes('$DEV_A_ID')) {
    console.error('bundle B profile contains device A (cross-owner leak)'); process.exit(1);
  }

  process.stdout.write('ok');
" 2>&1) || fail "profile isolation check failed: $ISOLATION_RESULT"

echo "    profile isolation verified: A sees only device A, B sees only device B"

# ── Step 9: Verify admin fleet shows both devices ────────────────────────────

step 9 "verifying admin fleet shows both devices"

FLEET_RESULT=$(node -e "
  const fs = require('fs');
  const a = JSON.parse(fs.readFileSync('$BUNDLE_A_FILE', 'utf8'));
  const b = JSON.parse(fs.readFileSync('$BUNDLE_B_FILE', 'utf8'));

  // Both bundles should show the same fleet (all devices)
  const fleetA = a.adminFrames.devices.items;
  const fleetB = b.adminFrames.devices.items;

  const fleetAIds = fleetA.map(d => d.deviceId).sort();
  const fleetBIds = fleetB.map(d => d.deviceId).sort();

  if (fleetAIds.length !== 2) {
    console.error('fleet A should have 2 devices, got ' + fleetAIds.length); process.exit(1);
  }
  if (fleetBIds.length !== 2) {
    console.error('fleet B should have 2 devices, got ' + fleetBIds.length); process.exit(1);
  }
  if (JSON.stringify(fleetAIds) !== JSON.stringify(fleetBIds)) {
    console.error('fleet devices differ between bundles'); process.exit(1);
  }
  if (!fleetAIds.includes('$DEV_A_ID')) {
    console.error('fleet missing device A'); process.exit(1);
  }
  if (!fleetAIds.includes('$DEV_B_ID')) {
    console.error('fleet missing device B'); process.exit(1);
  }

  // Verify device ownership in fleet
  const fleetDeviceA = fleetA.find(d => d.deviceId === '$DEV_A_ID');
  const fleetDeviceB = fleetA.find(d => d.deviceId === '$DEV_B_ID');

  if (fleetDeviceA.ownerUserId !== 'user_mock_001') {
    console.error('fleet device A owner mismatch: ' + fleetDeviceA.ownerUserId); process.exit(1);
  }
  if (fleetDeviceB.ownerUserId !== 'user_owner_b') {
    console.error('fleet device B owner mismatch: ' + fleetDeviceB.ownerUserId); process.exit(1);
  }

  // Verify both devices are online
  if (!fleetDeviceA.online) {
    console.error('fleet device A should be online after heartbeat'); process.exit(1);
  }
  if (!fleetDeviceB.online) {
    console.error('fleet device B should be online after heartbeat'); process.exit(1);
  }

  process.stdout.write('ok');
" 2>&1) || fail "fleet completeness check failed: $FLEET_RESULT"

echo "    fleet verified: both bundles show 2 devices with correct ownership"

# ── Step 10: Verify subscription attribution per owner ────────────────────────

step 10 "verifying subscription attribution per owner"

SUB_RESULT=$(node -e "
  const fs = require('fs');
  const a = JSON.parse(fs.readFileSync('$BUNDLE_A_FILE', 'utf8'));
  const b = JSON.parse(fs.readFileSync('$BUNDLE_B_FILE', 'utf8'));

  // Both bundles should have the same admin users/subscribers/subscriptions
  const usersA = a.adminFrames.users.items;
  const usersB = b.adminFrames.users.items;
  if (usersA.length !== usersB.length || usersA.length !== 2) {
    console.error('both bundles should have 2 admin users'); process.exit(1);
  }

  const subsA = a.adminFrames.subscriptions.items;
  const subsB = b.adminFrames.subscriptions.items;
  if (subsA.length !== subsB.length || subsA.length !== 2) {
    console.error('both bundles should have 2 subscriptions'); process.exit(1);
  }

  // Verify owner A's subscription is basic
  const ownerASub = subsA.find(s => s.userId === 'user_mock_001');
  if (!ownerASub) { console.error('owner A subscription not found'); process.exit(1); }
  if (ownerASub.plan !== 'frames_basic') { console.error('owner A plan mismatch: ' + ownerASub.plan); process.exit(1); }
  if (ownerASub.tier !== 'basic') { console.error('owner A tier mismatch: ' + ownerASub.tier); process.exit(1); }

  // Verify owner B's subscription is pro
  const ownerBSub = subsA.find(s => s.userId === 'user_owner_b');
  if (!ownerBSub) { console.error('owner B subscription not found'); process.exit(1); }
  if (ownerBSub.plan !== 'frames_pro') { console.error('owner B plan mismatch: ' + ownerBSub.plan); process.exit(1); }
  if (ownerBSub.tier !== 'pro') { console.error('owner B tier mismatch: ' + ownerBSub.tier); process.exit(1); }

  // Fleet device B must reference owner B's subscription
  const fleetDeviceB = a.adminFrames.devices.items.find(d => d.deviceId === '$DEV_B_ID');
  if (fleetDeviceB.subscription) {
    if (fleetDeviceB.subscription.subscriptionId !== ownerBSub.subscriptionId) {
      console.error('fleet device B subscription reference mismatch'); process.exit(1);
    }
    if (fleetDeviceB.subscription.plan !== 'frames_pro') {
      console.error('fleet device B subscription plan mismatch: ' + fleetDeviceB.subscription.plan); process.exit(1);
    }
  }

  // Verify subscriber consistency
  const subscribersA = a.adminFrames.subscribers.items;
  const ownerBSuber = subscribersA.find(s => s.userId === 'user_owner_b');
  if (!ownerBSuber) { console.error('owner B subscriber not found'); process.exit(1); }
  if (ownerBSuber.subscriptionId !== ownerBSub.subscriptionId) {
    console.error('owner B subscriber subscriptionId mismatch'); process.exit(1);
  }

  process.stdout.write('ok');
" 2>&1) || fail "subscription attribution check failed: $SUB_RESULT"

echo "    subscriptions verified: owner A=basic, owner B=pro, fleet attribution correct"

# ── Step 11: Verify settings propagated per-device ───────────────────────────

step 11 "verifying per-device settings propagation"

SETTINGS_RESULT=$(node -e "
  const fs = require('fs');
  const a = JSON.parse(fs.readFileSync('$BUNDLE_A_FILE', 'utf8'));
  const b = JSON.parse(fs.readFileSync('$BUNDLE_B_FILE', 'utf8'));

  // Device A in fleet should have slideshow mode
  const fleetDevA = a.adminFrames.devices.items.find(d => d.deviceId === '$DEV_A_ID');
  if (fleetDevA.settings.displayMode !== 'slideshow') {
    console.error('device A fleet settings displayMode mismatch: ' + fleetDevA.settings.displayMode); process.exit(1);
  }
  if (fleetDevA.settings.shuffleInterval !== 45) {
    console.error('device A fleet shuffleInterval mismatch'); process.exit(1);
  }

  // Device B in fleet should have shuffle mode
  const fleetDevB = a.adminFrames.devices.items.find(d => d.deviceId === '$DEV_B_ID');
  if (fleetDevB.settings.displayMode !== 'shuffle') {
    console.error('device B fleet settings displayMode mismatch: ' + fleetDevB.settings.displayMode); process.exit(1);
  }
  if (fleetDevB.settings.shuffleInterval !== 60) {
    console.error('device B fleet shuffleInterval mismatch'); process.exit(1);
  }

  // Device A in profile A should have slideshow
  const profDevA = a.profileFrames.devices.find(d => d.deviceId === '$DEV_A_ID');
  if (profDevA.settings.displayMode !== 'slideshow') {
    console.error('profile device A settings displayMode mismatch'); process.exit(1);
  }

  // Device B in profile B should have shuffle
  const profDevB = b.profileFrames.devices.find(d => d.deviceId === '$DEV_B_ID');
  if (profDevB.settings.displayMode !== 'shuffle') {
    console.error('profile device B settings displayMode mismatch'); process.exit(1);
  }

  process.stdout.write('ok');
" 2>&1) || fail "settings propagation check failed: $SETTINGS_RESULT"

echo "    settings propagated: device A=slideshow/45s, device B=shuffle/60s"

# ── Step 12: Run contract checker on both bundles ────────────────────────────

step 12 "running online-admin contract checker on both bundles"

if [[ "$SKIP_CONTRACT" == "1" ]]; then
  echo "    (skipped)"
else
  CONTRACT_A=$(bash "$CONTRACT_CHECK" "$BUNDLE_A_FILE" 2>&1) || fail "bundle A contract check failed: $CONTRACT_A"
  echo "    bundle A: $CONTRACT_A"

  CONTRACT_B=$(bash "$CONTRACT_CHECK" "$BUNDLE_B_FILE" 2>&1) || fail "bundle B contract check failed: $CONTRACT_B"
  echo "    bundle B: $CONTRACT_B"
fi

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo "online-admin-fleet-isolation-check: all 12 steps passed"
