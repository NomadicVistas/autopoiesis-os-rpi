#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Online Admin Mock Bridge Check
#
# Proves that the mock hosted API can produce an online-admin bundle that
# satisfies the online-admin contract checker. This is the cross-system
# consistency link between device mock state and the admin/profile bundle
# contract.
#
# The bridge:
#   1. Starts the mock hosted API on a random port
#   2. Registers a device and pairs it
#   3. Walks device lifecycle: settings sync, heartbeat, command, release
#   4. Adds a second admin user with a different subscription status
#   5. Fetches the online-admin bundle from the mock API
#   6. Runs the online-admin contract checker against the generated bundle
#   7. Proves bundle state is consistent with mock device lifecycle data
#
# Usage:
#   scripts/online-admin-mock-bridge-check.sh
#
# Environment:
#   ONLINE_ADMIN_BRIDGE_SKIP_CONTRACT  skip contract check (default: 0)
# ─────────────────────────────────────────────────────────────────────────────

SKIP_CONTRACT="${ONLINE_ADMIN_BRIDGE_SKIP_CONTRACT:-0}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MOCK_API="$REPO_DIR/scripts/mock-hosted-api/server.js"
CONTRACT_CHECK="$REPO_DIR/scripts/online-admin-contract-check.sh"

MOCK_PORT=""
MOCK_PID=""
BUNDLE_FILE=""

cleanup() {
  if [[ -n "$MOCK_PID" ]]; then
    kill "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true
  fi
  if [[ -n "$BUNDLE_FILE" ]]; then
    rm -f "$BUNDLE_FILE"
  fi
}
trap cleanup EXIT

fail() {
  echo "online-admin-mock-bridge-check failed: $*" >&2
  exit 1
}

step() {
  echo "  step $1: $2"
}

# ── Requirements check ───────────────────────────────────────────────────────

[[ -f "$MOCK_API" ]] || fail "mock hosted API not found: $MOCK_API"
[[ -f "$CONTRACT_CHECK" ]] || fail "online-admin contract check not found: $CONTRACT_CHECK"
command -v node >/dev/null 2>&1 || fail "node is required"
command -v curl >/dev/null 2>&1 || fail "curl is required"

# ── Step 1: Start mock API on random port ────────────────────────────────────

MOCK_PORT=$(comm -23 <(seq 3140 3199) <(ss -tHln 'sport >= 3140 and sport <= 3199' | awk '{print $4}' | sed 's/.*://') | head -1)
[[ -n "$MOCK_PORT" ]] || fail "no available port in 3140-3199 range"

step 1 "starting mock hosted API on port $MOCK_PORT"
MOCK_API_BASE="http://127.0.0.1:$MOCK_PORT"

node "$MOCK_API" --port "$MOCK_PORT" &
MOCK_PID=$!

# Wait for mock API to be ready
for i in $(seq 1 30); do
  if curl -fsS "$MOCK_API_BASE/mock/state" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done

curl -fsS "$MOCK_API_BASE/mock/state" >/dev/null 2>&1 || fail "mock API did not start"

echo "    mock API ready"

# ── Step 2: Register device ──────────────────────────────────────────────────

step 2 "registering device"

REGISTER_BODY='{"deviceName":"Bridge Test Frame","softwareVersion":"0.1.0","metadata":{"model":"Pi 5","ramMB":8192}}'
REGISTER_RESP=$(curl -fsS -X POST -H "content-type: application/json" -d "$REGISTER_BODY" "$MOCK_API_BASE/frames/device/register")

DEVICE_ID=$(echo "$REGISTER_RESP" | node -e "const d=require('fs').readFileSync('/dev/stdin','utf8');const j=JSON.parse(d);process.stdout.write(j.device.deviceId)")
DEVICE_KEY=$(echo "$REGISTER_RESP" | node -e "const d=require('fs').readFileSync('/dev/stdin','utf8');const j=JSON.parse(d);process.stdout.write(j.device.deviceApiKey)")

[[ -n "$DEVICE_ID" ]] || fail "registration did not return deviceId"
[[ -n "$DEVICE_KEY" ]] || fail "registration did not return deviceApiKey"

echo "    deviceId=$DEVICE_ID"

# ── Step 3: Pair device ──────────────────────────────────────────────────────

step 3 "pairing device"

PAIR_RESP=$(curl -fsS -X POST "$MOCK_API_BASE/mock/pair-device/$DEVICE_ID")
PAIRED=$(echo "$PAIR_RESP" | node -e "const d=require('fs').readFileSync('/dev/stdin','utf8');const j=JSON.parse(d);process.stdout.write(String(j.paired))")

[[ "$PAIRED" == "true" ]] || fail "pairing failed"

echo "    paired=true"

# ── Step 4: Sync settings ────────────────────────────────────────────────────

step 4 "syncing settings"

SETTINGS_BODY='{"settings":{"displayMode":"slideshow","shuffleInterval":45,"activeArtists":["artist-001","artist-002"],"updatedAt":"2099-06-07T20:00:00.000Z"}}'
SETTINGS_RESP=$(curl -fsS -X POST -H "content-type: application/json" -H "x-frame-device-key: $DEVICE_KEY" -d "$SETTINGS_BODY" "$MOCK_API_BASE/frames/device/$DEVICE_ID/settings")

SETTINGS_OK=$(echo "$SETTINGS_RESP" | node -e "const d=require('fs').readFileSync('/dev/stdin','utf8');const j=JSON.parse(d);process.stdout.write(String(j.ok))")
[[ "$SETTINGS_OK" == "true" ]] || fail "settings sync failed"
echo "    settings synced"

# ── Step 5: Send heartbeat ───────────────────────────────────────────────────

step 5 "sending heartbeat"

HEARTBEAT_BODY='{"softwareVersion":"0.1.0","events":[{"eventKey":"evt_display_1","type":"frame_item_displayed","observedAt":"2026-06-07T20:01:00.000Z","artworkId":"artwork-001"}]}'
HEARTBEAT_RESP=$(curl -fsS -X POST -H "content-type: application/json" -H "x-frame-device-key: $DEVICE_KEY" -d "$HEARTBEAT_BODY" "$MOCK_API_BASE/frames/device/$DEVICE_ID/heartbeat")

HEARTBEAT_OK=$(echo "$HEARTBEAT_RESP" | node -e "const d=require('fs').readFileSync('/dev/stdin','utf8');const j=JSON.parse(d);process.stdout.write(String(j.ok))")
[[ "$HEARTBEAT_OK" == "true" ]] || fail "heartbeat failed"
echo "    heartbeat accepted"

# ── Step 6: Queue and process a command ──────────────────────────────────────

step 6 "queueing and processing command"

CMD_RESP=$(curl -fsS -X POST -H "content-type: application/json" -d '{"type":"clear_cache","risk":"low"}' "$MOCK_API_BASE/mock/queue-command/$DEVICE_ID")
CMD_ID=$(echo "$CMD_RESP" | node -e "const d=require('fs').readFileSync('/dev/stdin','utf8');const j=JSON.parse(d);process.stdout.write(j.command.commandId)")
[[ -n "$CMD_ID" ]] || fail "command queue failed"
echo "    command queued: $CMD_ID"

# Acknowledge the command
ACK_RESP=$(curl -fsS -X POST -H "content-type: application/json" -H "x-frame-device-key: $DEVICE_KEY" -d '{"status":"acknowledged"}' "$MOCK_API_BASE/frames/device/$DEVICE_ID/commands/$CMD_ID/ack")
ACK_OK=$(echo "$ACK_RESP" | node -e "const d=require('fs').readFileSync('/dev/stdin','utf8');const j=JSON.parse(d);process.stdout.write(String(j.ok))")
[[ "$ACK_OK" == "true" ]] || fail "command ack failed"
echo "    command acknowledged"

# ── Step 7: Stage a release ──────────────────────────────────────────────────

step 7 "staging release"

RELEASE_RESP=$(curl -fsS -X POST -H "content-type: application/json" -d '{"version":"0.2.0","channel":"stable","tagName":"v0.2.0"}' "$MOCK_API_BASE/mock/set-release/$DEVICE_ID")
RELEASE_OK=$(echo "$RELEASE_RESP" | node -e "const d=require('fs').readFileSync('/dev/stdin','utf8');const j=JSON.parse(d);process.stdout.write(String(j.ok))")
[[ "$RELEASE_OK" == "true" ]] || fail "release staging failed"
echo "    release staged: v0.2.0"

# ── Step 8: Add second admin user ────────────────────────────────────────────

step 8 "adding second admin user with trial subscription"

ADD_USER_BODY='{"userId":"user_mock_002","email":"trial@example.com","name":"Trial User","subscriber":{"status":"trialing","plan":"frames_pro","tier":"pro","currentPeriodEnd":"2026-07-07T00:00:00.000Z"}}'
ADD_USER_RESP=$(curl -fsS -X POST -H "content-type: application/json" -d "$ADD_USER_BODY" "$MOCK_API_BASE/mock/add-user")
ADD_USER_OK=$(echo "$ADD_USER_RESP" | node -e "const d=require('fs').readFileSync('/dev/stdin','utf8');const j=JSON.parse(d);process.stdout.write(String(j.ok))")
[[ "$ADD_USER_OK" == "true" ]] || fail "add user failed"
echo "    user_mock_002 added with trialing subscription"

# ── Step 9: Fetch online-admin bundle ────────────────────────────────────────

step 9 "fetching online-admin bundle"

BUNDLE_RESP=$(curl -fsS "$MOCK_API_BASE/mock/online-admin-bundle")
BUNDLE_KIND=$(echo "$BUNDLE_RESP" | node -e "const d=require('fs').readFileSync('/dev/stdin','utf8');const j=JSON.parse(d);process.stdout.write(j.kind || '')")
[[ "$BUNDLE_KIND" == "autopoiesis_frames_online_admin_bundle" ]] || fail "bundle kind mismatch: $BUNDLE_KIND"

# Save bundle to temp file for contract check
BUNDLE_FILE=$(mktemp)
echo "$BUNDLE_RESP" > "$BUNDLE_FILE"

echo "    bundle generated (kind=$BUNDLE_KIND)"

# ── Step 10: Validate bundle structure ────────────────────────────────────────

step 10 "validating bundle structure"

BUNDLE_VALID=$(echo "$BUNDLE_RESP" | node -e "
  const d = require('fs').readFileSync('/dev/stdin','utf8');
  const j = JSON.parse(d);
  const checks = [
    ['ok', j.ok === true],
    ['schemaVersion', j.schemaVersion === 1],
    ['generatedAt', typeof j.generatedAt === 'string'],
    ['profileFrames.userId', typeof j.profileFrames.userId === 'string'],
    ['profileFrames.preferences', typeof j.profileFrames.preferences === 'object'],
    ['profileFrames.cachePreferences', typeof j.profileFrames.cachePreferences === 'object'],
    ['profileFrames.activeArtists', Array.isArray(j.profileFrames.activeArtists)],
    ['profileFrames.likedArtworks', Array.isArray(j.profileFrames.likedArtworks) || typeof j.profileFrames.likedArtworks === 'object'],
    ['profileFrames.devices', Array.isArray(j.profileFrames.devices)],
    ['adminFrames.actor', typeof j.adminFrames.actor === 'object'],
    ['adminFrames.users', typeof j.adminFrames.users === 'object'],
    ['adminFrames.subscribers', typeof j.adminFrames.subscribers === 'object'],
    ['adminFrames.subscriptions', typeof j.adminFrames.subscriptions === 'object'],
    ['adminFrames.devices', typeof j.adminFrames.devices === 'object'],
    ['adminFrames.remoteActions', typeof j.adminFrames.remoteActions === 'object'],
    ['adminFrames.remoteActions.commands', Array.isArray(j.adminFrames.remoteActions.commands)],
    ['adminFrames.remoteActions.roleActionMatrix', Array.isArray(j.adminFrames.remoteActions.roleActionMatrix)],
    ['users count >= 2', j.adminFrames.users.items.length >= 2],
    ['subscriptions count >= 2', j.adminFrames.subscriptions.items.length >= 2],
    ['fleet devices >= 1', j.adminFrames.devices.items.length >= 1],
  ];
  const failures = checks.filter(([_, ok]) => !ok);
  if (failures.length) {
    console.error('bundle validation failures: ' + failures.map(([n]) => n).join(', '));
    process.exit(1);
  }
  process.stdout.write('ok');
" 2>&1) || fail "bundle structure validation failed: $BUNDLE_VALID"

echo "    structure valid: users=2+, subscriptions=2+, devices=1+"

# ── Step 11: Verify device state propagation ──────────────────────────────────

step 11 "verifying device state propagation into bundle"

DEVICE_STATE=$(echo "$BUNDLE_RESP" | node -e "
  const d = require('fs').readFileSync('/dev/stdin','utf8');
  const j = JSON.parse(d);

  // Find our device in the fleet
  const fleetDevice = j.adminFrames.devices.items.find(dev => dev.deviceId === '$DEVICE_ID');
  if (!fleetDevice) { console.error('device not found in fleet'); process.exit(1); }
  if (!fleetDevice.online) { console.error('fleet device should be online after heartbeat'); process.exit(1); }
  if (fleetDevice.softwareVersion !== '0.1.0') { console.error('fleet device software version mismatch'); process.exit(1); }
  if (fleetDevice.settings.displayMode !== 'slideshow') { console.error('fleet device settings not propagated'); process.exit(1); }

  // Find our device in profile
  const profileDevice = j.profileFrames.devices.find(dev => dev.deviceId === '$DEVICE_ID');
  if (!profileDevice) { console.error('device not found in profile'); process.exit(1); }
  if (profileDevice.ownerUserId !== j.profileFrames.userId) { console.error('profile device owner mismatch'); process.exit(1); }
  if (!profileDevice.actionAvailability) { console.error('profile device missing actionAvailability'); process.exit(1); }
  if (!profileDevice.actionAvailability.actions) { console.error('profile device missing action decisions'); process.exit(1); }

  // Verify release propagation
  if (!fleetDevice.release || fleetDevice.release.version !== '0.2.0') { console.error('fleet device release not propagated'); process.exit(1); }

  // Verify second user
  const user2 = j.adminFrames.users.items.find(u => u.userId === 'user_mock_002');
  if (!user2) { console.error('second user not found'); process.exit(1); }

  const sub2 = j.adminFrames.subscriptions.items.find(s => s.userId === 'user_mock_002');
  if (!sub2) { console.error('second user subscription not found'); process.exit(1); }
  if (sub2.status !== 'trialing') { console.error('second user subscription status mismatch'); process.exit(1); }

  process.stdout.write('ok');
" 2>&1) || fail "device state propagation check failed: $DEVICE_STATE"

echo "    device state propagated: online, settings, release, users, subscriptions"

# ── Step 12: Run contract checker ────────────────────────────────────────────

step 12 "running online-admin contract checker"

if [[ "$SKIP_CONTRACT" == "1" ]]; then
  echo "    (skipped)"
else
  CONTRACT_OUTPUT=$(bash "$CONTRACT_CHECK" "$BUNDLE_FILE" 2>&1) || fail "contract check failed: $CONTRACT_OUTPUT"
  echo "    $CONTRACT_OUTPUT"
fi

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo "online-admin-mock-bridge-check: all 12 steps passed"
