#!/usr/bin/env bash
# online-admin-device-state-actions-check.sh
# Validates device-state-aware action availability in the online admin bundle.
#
# Tests:
#   1. Syntax validation
#   2. Static contract (curator role, device-state constants, buildActionAvailability deviceState)
#   3. Default device state (paired, online, not disabled, remote enabled)
#   4. Offline device: online-required actions blocked with reasonCode offline
#   5. Disabled device: most actions blocked with reasonCode device_disabled (enable_device allowed)
#   6. Remote-disabled device: all actions blocked with reasonCode remote_disabled
#   7. Pending command: conflicting action blocked with reasonCode pending_command
#   8. Subscription degradation still overrides device state
#   9. Not-paired device excluded from fleet
#  10. Curator role — show_broadcast only
#  11. Admin bundle deviceState field in actionAvailability
#  12. Regression: online-admin-mock-bridge-check passes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MOCK_API="$REPO_ROOT/scripts/mock-hosted-api/server.js"
CHECKS=0
FAILS=0
STEP=0

pass() { CHECKS=$((CHECKS + 1)); }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS + 1)); CHECKS=$((CHECKS + 1)); }

step() { STEP=$((STEP + 1)); echo ""; echo "Step $STEP: $1"; }

assert_json_eq() {
  local label="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    pass
  else
    fail "$label: expected '$expected', got '$actual'"
  fi
}

assert_json_true() {
  local label="$1" actual="$2"
  if [ "$actual" = "true" ]; then
    pass
  else
    fail "$label: expected true, got '$actual'"
  fi
}

assert_json_false() {
  local label="$1" actual="$2"
  if [ "$actual" = "false" ]; then
    pass
  else
    fail "$label: expected false, got '$actual'"
  fi
}

assert_grep() {
  local label="$1" file="$2" pattern="$3"
  if grep -q "$pattern" "$file" 2>/dev/null; then
    pass
  else
    fail "$label: pattern '$pattern' not found"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Step 1: Syntax validation
# ──────────────────────────────────────────────────────────────────────────────
step "Syntax validation"

node --check "$MOCK_API" 2>/dev/null && pass || fail "mock API syntax"
node --check "$REPO_ROOT/local-ui/server.js" 2>/dev/null && pass || fail "local-ui syntax"
bash -n "$0" 2>/dev/null && pass || fail "self syntax"

# ──────────────────────────────────────────────────────────────────────────────
# Step 2: Static contract
# ──────────────────────────────────────────────────────────────────────────────
step "Static contract"

assert_grep "curator role in ROLE_ACTION_MATRIX" "$MOCK_API" 'role: "curator"'
assert_grep "ONLINE_REQUIRED_ACTIONS" "$MOCK_API" "ONLINE_REQUIRED_ACTIONS"
assert_grep "CONFLICTING_COMMAND_TYPES" "$MOCK_API" "CONFLICTING_COMMAND_TYPES"
assert_grep "DISABLED_BLOCKED_ACTIONS" "$MOCK_API" "DISABLED_BLOCKED_ACTIONS"
assert_grep "deviceState in return" "$MOCK_API" "deviceState: { isPaired, isOnline, isDisabled, isRemoteEnabled, pendingCommandCount"
assert_grep "disabled field on record" "$MOCK_API" "disabled: false,"
assert_grep "remoteEnabled field on record" "$MOCK_API" "remoteEnabled: true"
assert_grep "set-device-state route" "$MOCK_API" "mock/set-device-state"
assert_grep "curator in acceptedActorRoles" "$MOCK_API" '"curator"'
assert_grep "curator in show_broadcast acceptedActorRoles" "$MOCK_API" 'acceptedActorRoles.*curator'
assert_grep "remoteEnabled from record (fleet)" "$MOCK_API" "remoteEnabled: record.remoteEnabled"
assert_grep "disabled from record (fleet)" "$MOCK_API" "disabled: !!record.disabled"

# ──────────────────────────────────────────────────────────────────────────────
# Step 3: Start mock API and set up test fixtures
# ──────────────────────────────────────────────────────────────────────────────
step "Mock API startup and test fixtures"

PORT=18319
MOCK_PID=""
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"; [ -n "$MOCK_PID" ] && kill $MOCK_PID 2>/dev/null || true' EXIT

MOCK_API_PORT=$PORT node "$MOCK_API" > "$TMPDIR/api.log" 2>&1 &
MOCK_PID=$!
sleep 1

if ! kill -0 $MOCK_PID 2>/dev/null; then
  fail "Mock API failed to start"
  cat "$TMPDIR/api.log"
  exit 1
fi
pass

# State check
STATE=$(curl -sf "http://127.0.0.1:$PORT/mock/state" 2>/dev/null || echo '{}')
echo "$STATE" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('ok') else 1)" 2>/dev/null && pass || fail "state endpoint"

api() {
  local method="$1" path="$2" body="${3:-}"
  if [ "$method" = "GET" ]; then
    curl -sf "http://127.0.0.1:$PORT$path" 2>/dev/null || echo '{"ok":false}'
  else
    curl -sf -X "$method" -H "Content-Type: application/json" -d "$body" "http://127.0.0.1:$PORT$path" 2>/dev/null || echo '{"ok":false}'
  fi
}

api_hdr() {
  local method="$1" path="$2" header="$3" body="${4:-}"
  curl -sf -X "$method" -H "Content-Type: application/json" -H "$header" -d "$body" "http://127.0.0.1:$PORT$path" 2>/dev/null || echo '{"ok":false}'
}

jq_val() {
  echo "$1" | python3 -c "import sys,json; print(str(json.load(sys.stdin)$2).lower())" 2>/dev/null
}

# Register a device
REG=$(api POST /frames/device/register '{}')
DEV_ID=$(jq_val "$REG" "['device']['deviceId']")
DEV_KEY=$(jq_val "$REG" "['device']['deviceApiKey']")
PAIR_CODE=$(jq_val "$REG" "['pairingCode']")

[ -n "$DEV_ID" ] && [ "$DEV_ID" != "None" ] && pass || fail "device registration: got deviceId"
[ -n "$DEV_KEY" ] && [ "$DEV_KEY" != "None" ] && pass || fail "device registration: got deviceApiKey"

# Pair the device
PAIR=$(api POST "/mock/pair-device/$DEV_ID" "{\"pairingCode\":\"$PAIR_CODE\",\"ownerUserId\":\"user_test_001\"}")
PAIR_OK=$(jq_val "$PAIR" "['ok']")
[ "$PAIR_OK" = "true" ] && pass || fail "device pairing"

# Set up user subscription (active, basic plan)
api POST /mock/add-user '{"userId":"user_test_001","email":"test@example.com","subscriber":{"status":"active","plan":"frames_basic","tier":"basic"}}' > /dev/null

# Send heartbeat to make device online
api_hdr POST "/frames/device/$DEV_ID/heartbeat" "x-frame-device-key: $DEV_KEY" '{}' > /dev/null && pass || fail "heartbeat"

# ──────────────────────────────────────────────────────────────────────────────
# Step 4: Default device state — all actions allowed for admin
# ──────────────────────────────────────────────────────────────────────────────
step "Default device state — online, paired, not disabled"

BUNDLE=$(api GET /mock/online-admin-bundle)

FLEET_COUNT=$(jq_val "$BUNDLE" "['adminFrames']['devices']['total']")
[ "$FLEET_COUNT" -ge 1 ] 2>/dev/null && pass || fail "fleet has devices (count=$FLEET_COUNT)"

# Get actionAvailability for our device
ADMIN_DEV0=$(echo "$BUNDLE" | python3 -c "
import sys,json
d=json.load(sys.stdin)
devs=d['adminFrames']['devices']['items']
for dev in devs:
  if dev.get('deviceId')=='$DEV_ID':
    print(json.dumps(dev))
    break
" 2>/dev/null)

AA=$(echo "$ADMIN_DEV0" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['actionAvailability']))" 2>/dev/null)

AA_PAIRED=$(jq_val "$AA" "['deviceState']['isPaired']")
AA_ONLINE=$(jq_val "$AA" "['deviceState']['isOnline']")
AA_DISABLED=$(jq_val "$AA" "['deviceState']['isDisabled']")
AA_REMOTE=$(jq_val "$AA" "['deviceState']['isRemoteEnabled']")

assert_json_true "device is paired" "$AA_PAIRED"
assert_json_true "device is online" "$AA_ONLINE"
assert_json_false "device not disabled" "$AA_DISABLED"
assert_json_true "remote enabled" "$AA_REMOTE"

RESTART_ALLOWED=$(jq_val "$AA" "['actions']['restart_device']['allowed']")
UPDATE_ALLOWED=$(jq_val "$AA" "['actions']['update_device']['allowed']")
FACTORY_ALLOWED=$(jq_val "$AA" "['actions']['factory_reset_request']['allowed']")
SHOW_BC_ALLOWED=$(jq_val "$AA" "['actions']['show_broadcast']['allowed']")

assert_json_true "restart_device allowed" "$RESTART_ALLOWED"
assert_json_true "update_device allowed" "$UPDATE_ALLOWED"
assert_json_true "factory_reset_request allowed" "$FACTORY_ALLOWED"
assert_json_true "show_broadcast allowed" "$SHOW_BC_ALLOWED"

# ──────────────────────────────────────────────────────────────────────────────
# Step 5: Offline device — online-required actions blocked
# ──────────────────────────────────────────────────────────────────────────────
step "Offline device — online-required actions blocked"

# Register a second device that never sends heartbeat
REG2=$(api POST /frames/device/register '{}')
DEV2_ID=$(jq_val "$REG2" "['device']['deviceId']")
PAIR2=$(jq_val "$REG2" "['pairingCode']")
api POST "/mock/pair-device/$DEV2_ID" "{\"pairingCode\":\"$PAIR2\",\"ownerUserId\":\"user_test_001\"}" > /dev/null

BUNDLE2=$(api GET /mock/online-admin-bundle)

DEV2_AA=$(echo "$BUNDLE2" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for dev in d['adminFrames']['devices']['items']:
  if dev.get('deviceId')=='$DEV2_ID':
    print(json.dumps(dev['actionAvailability']))
    break
" 2>/dev/null)

DEV2_ONLINE=$(jq_val "$DEV2_AA" "['deviceState']['isOnline']")
assert_json_false "device2 offline" "$DEV2_ONLINE"

RESTART2=$(jq_val "$DEV2_AA" "['actions']['restart_device']['allowed']")
RESTART2_REASON=$(jq_val "$DEV2_AA" "['actions']['restart_device']['reasonCode']")
assert_json_false "offline: restart_device blocked" "$RESTART2"
assert_json_eq "offline: reasonCode is offline" "$RESTART2_REASON" "offline"

UPDATE2=$(jq_val "$DEV2_AA" "['actions']['update_device']['allowed']")
assert_json_false "offline: update_device blocked" "$UPDATE2"

SHOW2=$(jq_val "$DEV2_AA" "['actions']['show_broadcast']['allowed']")
assert_json_false "offline: show_broadcast blocked" "$SHOW2"

# enable_device should NOT be blocked by offline
ENABLE2=$(jq_val "$DEV2_AA" "['actions']['enable_device']['allowed']")
assert_json_true "offline: enable_device still allowed" "$ENABLE2"

# factory_reset_request NOT blocked by offline
FACTORY2=$(jq_val "$DEV2_AA" "['actions']['factory_reset_request']['allowed']")
assert_json_true "offline: factory_reset_request still allowed" "$FACTORY2"

# ──────────────────────────────────────────────────────────────────────────────
# Step 6: Disabled device — most actions blocked, enable_device escape hatch
# ──────────────────────────────────────────────────────────────────────────────
step "Disabled device — most actions blocked, enable_device escape hatch"

api POST "/mock/set-device-state/$DEV_ID" '{"disabled":true}'

BUNDLE_DIS=$(api GET /mock/online-admin-bundle)

DEV1_DIS_AA=$(echo "$BUNDLE_DIS" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for dev in d['adminFrames']['devices']['items']:
  if dev.get('deviceId')=='$DEV_ID':
    print(json.dumps(dev['actionAvailability']))
    break
" 2>/dev/null)

DIS_STATE=$(jq_val "$DEV1_DIS_AA" "['deviceState']['isDisabled']")
assert_json_true "disabled: deviceState.isDisabled" "$DIS_STATE"

DIS_RESTART=$(jq_val "$DEV1_DIS_AA" "['actions']['restart_device']['allowed']")
DIS_RESTART_RC=$(jq_val "$DEV1_DIS_AA" "['actions']['restart_device']['reasonCode']")
assert_json_false "disabled: restart_device blocked" "$DIS_RESTART"
assert_json_eq "disabled: reasonCode is device_disabled" "$DIS_RESTART_RC" "device_disabled"

DIS_SHOW=$(jq_val "$DEV1_DIS_AA" "['actions']['show_broadcast']['allowed']")
assert_json_false "disabled: show_broadcast blocked" "$DIS_SHOW"

DIS_SYNC=$(jq_val "$DEV1_DIS_AA" "['actions']['sync_settings']['allowed']")
DIS_SYNC_RC=$(jq_val "$DEV1_DIS_AA" "['actions']['sync_settings']['reasonCode']")
assert_json_false "disabled: sync_settings blocked" "$DIS_SYNC"
assert_json_eq "disabled: sync_settings reasonCode" "$DIS_SYNC_RC" "device_disabled"

# enable_device is the escape hatch
DIS_ENABLE=$(jq_val "$DEV1_DIS_AA" "['actions']['enable_device']['allowed']")
assert_json_true "disabled: enable_device is the escape hatch" "$DIS_ENABLE"

# Re-enable
api POST "/mock/set-device-state/$DEV_ID" '{"disabled":false}'

# ──────────────────────────────────────────────────────────────────────────────
# Step 7: Remote-disabled device — all actions blocked
# ──────────────────────────────────────────────────────────────────────────────
step "Remote-disabled device — all remote actions blocked"

api POST "/mock/set-device-state/$DEV_ID" '{"remoteEnabled":false}'

BUNDLE_REMOTE=$(api GET /mock/online-admin-bundle)

DEV1_REMOTE_AA=$(echo "$BUNDLE_REMOTE" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for dev in d['adminFrames']['devices']['items']:
  if dev.get('deviceId')=='$DEV_ID':
    print(json.dumps(dev['actionAvailability']))
    break
" 2>/dev/null)

REMOTE_STATE=$(jq_val "$DEV1_REMOTE_AA" "['deviceState']['isRemoteEnabled']")
assert_json_false "remote-disabled: deviceState.isRemoteEnabled" "$REMOTE_STATE"

for ACTION in sync_settings clear_cache restart_display enable_device disable_device restart_device update_device show_broadcast factory_reset_request; do
  ACTION_ALLOWED=$(jq_val "$DEV1_REMOTE_AA" "['actions']['$ACTION']['allowed']")
  ACTION_RC=$(jq_val "$DEV1_REMOTE_AA" "['actions']['$ACTION']['reasonCode']")
  assert_json_false "remote-disabled: $ACTION blocked" "$ACTION_ALLOWED"
  assert_json_eq "remote-disabled: $ACTION reasonCode" "$ACTION_RC" "remote_disabled"
done

# Re-enable
api POST "/mock/set-device-state/$DEV_ID" '{"remoteEnabled":true}'

# ──────────────────────────────────────────────────────────────────────────────
# Step 8: Pending command — conflicting action blocked
# ──────────────────────────────────────────────────────────────────────────────
step "Pending command — conflicting action blocked"

api POST "/mock/queue-command/$DEV_ID" '{"type":"restart_device"}'

BUNDLE_PEND=$(api GET /mock/online-admin-bundle)

DEV1_PEND_AA=$(echo "$BUNDLE_PEND" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for dev in d['adminFrames']['devices']['items']:
  if dev.get('deviceId')=='$DEV_ID':
    print(json.dumps(dev['actionAvailability']))
    break
" 2>/dev/null)

PEND_COUNT=$(jq_val "$DEV1_PEND_AA" "['deviceState']['pendingCommandCount']")
[ "$PEND_COUNT" -gt 0 ] 2>/dev/null && pass || fail "pending: pendingCommandCount > 0 (got $PEND_COUNT)"

PEND_RESTART=$(jq_val "$DEV1_PEND_AA" "['actions']['restart_device']['allowed']")
PEND_RESTART_RC=$(jq_val "$DEV1_PEND_AA" "['actions']['restart_device']['reasonCode']")
assert_json_false "pending: restart_device blocked" "$PEND_RESTART"
assert_json_eq "pending: reasonCode is pending_command" "$PEND_RESTART_RC" "pending_command"

# Non-conflicting actions should still be allowed
PEND_SYNC=$(jq_val "$DEV1_PEND_AA" "['actions']['sync_settings']['allowed']")
assert_json_true "pending: sync_settings still allowed" "$PEND_SYNC"

PEND_SHOW=$(jq_val "$DEV1_PEND_AA" "['actions']['show_broadcast']['allowed']")
assert_json_true "pending: show_broadcast still allowed" "$PEND_SHOW"

# ──────────────────────────────────────────────────────────────────────────────
# Step 9: Subscription degradation overrides device state
# ──────────────────────────────────────────────────────────────────────────────
step "Subscription degradation overrides device state"

api POST /mock/transition-subscription/user_test_001 '{"status":"past_due"}'

BUNDLE_DEG=$(api GET /mock/online-admin-bundle)

DEV1_DEG_AA=$(echo "$BUNDLE_DEG" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for dev in d['adminFrames']['devices']['items']:
  if dev.get('deviceId')=='$DEV_ID':
    print(json.dumps(dev['actionAvailability']))
    break
" 2>/dev/null)

DEG_RESTART=$(jq_val "$DEV1_DEG_AA" "['actions']['restart_device']['allowed']")
DEG_RESTART_RC=$(jq_val "$DEV1_DEG_AA" "['actions']['restart_device']['reasonCode']")
DEG_DEGRADED=$(jq_val "$DEV1_DEG_AA" "['actions']['restart_device']['degradedBySubscription']")
assert_json_false "degraded: restart_device blocked" "$DEG_RESTART"
assert_json_eq "degraded: reasonCode is subscription_degraded" "$DEG_RESTART_RC" "subscription_degraded"
assert_json_true "degraded: degradedBySubscription flag" "$DEG_DEGRADED"

# Low-risk actions should still be allowed
DEG_SYNC=$(jq_val "$DEV1_DEG_AA" "['actions']['sync_settings']['allowed']")
assert_json_true "degraded: sync_settings still allowed" "$DEG_SYNC"

# Restore subscription
api POST /mock/transition-subscription/user_test_001 '{"status":"active","plan":"frames_basic","tier":"basic"}'

# ──────────────────────────────────────────────────────────────────────────────
# Step 10: Not-paired device excluded from fleet
# ──────────────────────────────────────────────────────────────────────────────
step "Not-paired device excluded from fleet"

REG3=$(api POST /frames/device/register '{}')
DEV3_ID=$(jq_val "$REG3" "['device']['deviceId']")

BUNDLE3=$(api GET /mock/online-admin-bundle)

DEV3_IN_FLEET=$(echo "$BUNDLE3" | python3 -c "
import sys,json
d=json.load(sys.stdin)
count = sum(1 for dev in d['adminFrames']['devices']['items'] if dev.get('deviceId') == '$DEV3_ID')
print(count)
" 2>/dev/null)
[ "$DEV3_IN_FLEET" = "0" ] && pass || fail "unpaired device not in fleet"

# Pair it, then check actions
PAIR3=$(jq_val "$REG3" "['pairingCode']")
api POST "/mock/pair-device/$DEV3_ID" "{\"pairingCode\":\"$PAIR3\",\"ownerUserId\":\"user_test_001\"}" > /dev/null

BUNDLE3P=$(api GET /mock/online-admin-bundle)

DEV3_AA=$(echo "$BUNDLE3P" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for dev in d['adminFrames']['devices']['items']:
  if dev.get('deviceId')=='$DEV3_ID':
    print(json.dumps(dev['actionAvailability']))
    break
" 2>/dev/null)

DEV3_ONLINE=$(jq_val "$DEV3_AA" "['deviceState']['isOnline']")
assert_json_false "newly paired device is offline" "$DEV3_ONLINE"

DEV3_ENABLE=$(jq_val "$DEV3_AA" "['actions']['enable_device']['allowed']")
assert_json_true "paired device: enable_device allowed" "$DEV3_ENABLE"

# ──────────────────────────────────────────────────────────────────────────────
# Step 11: Curator role — show_broadcast only
# ──────────────────────────────────────────────────────────────────────────────
step "Curator role — show_broadcast only, rest read-only"

BUNDLE_FRESH=$(api GET /mock/online-admin-bundle)

MATRIX_HAS_CURATOR=$(echo "$BUNDLE_FRESH" | python3 -c "
import sys,json
d=json.load(sys.stdin)
matrix = d['adminFrames']['remoteActions']['roleActionMatrix']
has = any(r['role'] == 'curator' for r in matrix)
print('true' if has else 'false')
" 2>/dev/null)
assert_json_true "curator in roleActionMatrix" "$MATRIX_HAS_CURATOR"

CURATOR_SHOW=$(echo "$BUNDLE_FRESH" | python3 -c "
import sys,json
d=json.load(sys.stdin)
matrix = d['adminFrames']['remoteActions']['roleActionMatrix']
curator = [r for r in matrix if r['role'] == 'curator'][0]
print('true' if curator['actions']['show_broadcast']['allowed'] else 'false')
" 2>/dev/null)
assert_json_true "curator: show_broadcast allowed" "$CURATOR_SHOW"

CURATOR_RESTART=$(echo "$BUNDLE_FRESH" | python3 -c "
import sys,json
d=json.load(sys.stdin)
matrix = d['adminFrames']['remoteActions']['roleActionMatrix']
curator = [r for r in matrix if r['role'] == 'curator'][0]
print('true' if curator['actions']['restart_device']['allowed'] else 'false')
" 2>/dev/null)
assert_json_false "curator: restart_device not allowed" "$CURATOR_RESTART"

CURATOR_FACTORY=$(echo "$BUNDLE_FRESH" | python3 -c "
import sys,json
d=json.load(sys.stdin)
matrix = d['adminFrames']['remoteActions']['roleActionMatrix']
curator = [r for r in matrix if r['role'] == 'curator'][0]
print('true' if curator['actions']['factory_reset_request']['allowed'] else 'false')
" 2>/dev/null)
assert_json_false "curator: factory_reset_request not allowed" "$CURATOR_FACTORY"

# ──────────────────────────────────────────────────────────────────────────────
# Step 12: Regression — online-admin-mock-bridge-check passes
# ──────────────────────────────────────────────────────────────────────────────
step "Regression: online-admin-mock-bridge-check"

if [ -f "$SCRIPT_DIR/online-admin-mock-bridge-check.sh" ]; then
  if bash "$SCRIPT_DIR/online-admin-mock-bridge-check.sh" > "$TMPDIR/regression.log" 2>&1; then
    pass
  else
    fail "online-admin-mock-bridge-check regression"
    tail -20 "$TMPDIR/regression.log"
  fi
else
  pass  # skip if not present
fi

# ──────────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"
if [ "$FAILS" -eq 0 ]; then
  echo "ALL $CHECKS CHECKS PASSED ($STEP steps)"
else
  echo "$FAILS FAILURES out of $CHECKS checks ($STEP steps)"
fi
echo "─────────────────────────────────────────"

[ "$FAILS" -eq 0 ]
