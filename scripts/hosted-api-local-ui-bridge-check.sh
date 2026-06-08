#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Hosted API → Local UI Bridge Check
#
# Proves the real database-backed hosted API server (hosted-api/server.js)
# works end-to-end with the device-side local UI (local-ui/server.js).
#
# This is the key integration milestone: SQLite database → hosted API → HTTP
# → local UI → local state files. Every device lifecycle operation flows
# through both servers exactly as it would on a real Pi.
#
# 18 steps, ~70 checks.
#
# Usage:
#   scripts/hosted-api-local-ui-bridge-check.sh
#
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

HOSTED_API="$REPO_DIR/hosted-api/server.js"
HOSTED_DB="$REPO_DIR/hosted-api/db.js"
LOCAL_UI="$REPO_DIR/local-ui/server.js"
SCHEMA="$REPO_DIR/scripts/aos-schema-sqlite-validation.sql"

PASS=0; FAIL=0; STEP=0

ok()   { PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
step() { STEP=$((STEP+1)); printf "\n── Step %d: %s ──\n" "$STEP" "$1"; }
check() { echo "  Checks: $PASS passed, $FAIL failed"; }

# JSON field extraction helper — handles spacing variations
jval() {
  echo "$1" | node -pe "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf-8'));$2" 2>/dev/null
}

# ── Cleanup ──────────────────────────────────────────────────────────────────
WORK_DIR=""
API_PID=""
UI_PID=""

cleanup() {
  if [ -n "$UI_PID" ]; then kill "$UI_PID" 2>/dev/null || true; wait "$UI_PID" 2>/dev/null || true; fi
  if [ -n "$API_PID" ]; then kill "$API_PID" 2>/dev/null || true; wait "$API_PID" 2>/dev/null || true; fi
  if [ -n "$WORK_DIR" ]; then rm -rf "$WORK_DIR"; fi
}
trap cleanup EXIT

find_free_port() {
  python3 -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()
" 2>/dev/null || echo "$((32000 + RANDOM % 3000))"
}

wait_for_server() {
  local port=$1 max_wait=${2:-10} path=${3:-"/health"}
  for i in $(seq 1 $((max_wait * 4))); do
    if curl -sf "http://127.0.0.1:${port}${path}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

# ── Step 1: Syntax validation ────────────────────────────────────────────────
step "Syntax validation"
node --check "$HOSTED_API" 2>/dev/null && ok || fail "hosted-api/server.js syntax"
node --check "$HOSTED_DB" 2>/dev/null && ok || fail "hosted-api/db.js syntax"
node --check "$LOCAL_UI" 2>/dev/null && ok || fail "local-ui/server.js syntax"
bash -n "$0" 2>/dev/null && ok || fail "self syntax"
check

# ── Step 2: Static contract — bridge prerequisites ───────────────────────────
step "Static contract — bridge prerequisites"

# Hosted API routes that the local UI calls
for route in \
  "frames/device/register" \
  "frames/device/:id/pairing-status" \
  "frames/device/:id/settings" \
  "frames/device/:id/heartbeat" \
  "frames/device/:id/stream" \
  "frames/device/:id/feed" \
  "frames/device/:id/commands" \
  "frames/device/:id/release" \
  "health"
do
  grep -q "$route" "$HOSTED_API" && ok || fail "hosted route: $route"
done

# Local UI calls hosted API endpoints (using string literals)
for call in \
  "/frames/device/register" \
  "/pairing-status" \
  "x-frame-device-key" \
  "pairing/start" \
  "pairing/check" \
  "settings/sync" \
  "heartbeat" \
  "feed/sync" \
  "release/check"
do
  grep -qF "$call" "$LOCAL_UI" && ok || fail "local-ui uses: $call"
done

# Key integration functions must exist
for fn in startPairing checkPairing syncSettingsFromRemote sendHeartbeat syncFeedFromRemote checkRelease applyRemoteSettingsPayload normalizeCommandsPayload; do
  grep -qP "function $fn|async function $fn" "$LOCAL_UI" && ok || fail "local-ui function: $fn"
done

check

# ── Step 3: Bootstrap database ───────────────────────────────────────────────
step "Bootstrap database"
WORK_DIR=$(mktemp -d)
DB_FILE="$WORK_DIR/aos-bridge.db"
LOCAL_UI_DIR="$WORK_DIR/local-ui-data"
mkdir -p "$LOCAL_UI_DIR"

node -e "
const AosDb = require('$HOSTED_DB');
const fs = require('fs');
const sql = fs.readFileSync('$SCHEMA', 'utf-8');
const db = new AosDb('$DB_FILE');
for (const stmt of sql.split(';').map(s => s.trim()).filter(s => s.length > 0)) {
  db.db.prepare(stmt).run();
}
const tables = db.listTables();
if (tables.length < 14) {
  process.stderr.write('Too few tables: ' + tables.length + '\n');
  process.exit(1);
}
db.close();
console.log('Bootstrap: ' + tables.length + ' tables');
" 2>/dev/null && ok || fail "database bootstrap"
check

# ── Step 4: Start hosted API server ──────────────────────────────────────────
step "Start hosted API server"
API_PORT=$(find_free_port)
AOS_DB="$DB_FILE" AOS_PORT="$API_PORT" AOS_HOST="127.0.0.1" node "$HOSTED_API" > "$WORK_DIR/api.log" 2>&1 &
API_PID=$!

wait_for_server "$API_PORT" 15 "/health" && ok || fail "hosted API startup"

HEALTH=$(curl -sf "http://127.0.0.1:$API_PORT/health" 2>/dev/null)
[ "$(jval "$HEALTH" "d.ok")" = "true" ] && ok || fail "hosted health ok"
[ "$(jval "$HEALTH" "d.service")" = "aos-hosted-api" ] && ok || fail "hosted service name"
echo "  Hosted API on port $API_PORT"
check

# ── Step 5: Start local UI pointed at hosted API ─────────────────────────────
step "Start local UI pointed at hosted API"
UI_PORT=$(find_free_port)

AUTOPOIESIS_API_BASE_URL="http://127.0.0.1:$API_PORT" \
AUTOPOIESIS_PORT="$UI_PORT" \
AUTOPOIESIS_DATA_DIR="$LOCAL_UI_DIR" \
node "$LOCAL_UI" > "$WORK_DIR/ui.log" 2>&1 &
UI_PID=$!

wait_for_server "$UI_PORT" 15 "/local/health" && ok || fail "local UI startup"

# Health returns ok:false for unpaired devices (warnings about device_unpaired),
# but the server must respond with a health object
UI_HEALTH=$(curl -sf "http://127.0.0.1:$UI_PORT/local/health" 2>/dev/null)
[ "$(jval "$UI_HEALTH" "d.health !== undefined")" = "true" ] && ok || fail "local UI health responds"
echo "  Local UI on port $UI_PORT → hosted API on port $API_PORT"
check

# ── Step 6: Register device via local UI ─────────────────────────────────────
step "Register device via local UI (pairing/start)"
REG=$(curl -sf -X POST "http://127.0.0.1:$UI_PORT/local/pairing/start" 2>/dev/null)
[ "$(jval "$REG" "d.ok")" = "true" ] && ok || fail "registration ok"
[ -n "$(jval "$REG" "d.pairingCode")" ] && ok || fail "pairingCode returned"
[ -n "$(jval "$REG" "d.expiresAt")" ] && ok || fail "expiresAt returned"
[ "$(jval "$REG" "d.mock")" = "false" ] && ok || fail "real (non-mock) registration"

PAIR_CODE=$(jval "$REG" "d.pairingCode")

# Check pairing status via local UI
PAIR_STATUS=$(curl -sf "http://127.0.0.1:$UI_PORT/local/pairing/status" 2>/dev/null)
[ "$(jval "$PAIR_STATUS" "d.ok")" = "true" ] && ok || fail "pairing status ok"
[ "$(jval "$PAIR_STATUS" "d.device.paired")" = "false" ] && ok || fail "not yet paired"
[ "$(jval "$PAIR_STATUS" "d.device.hasDeviceApiKey")" = "true" ] && ok || fail "deviceApiKey stored"

DEVICE_ID=$(jval "$PAIR_STATUS" "d.device.deviceId")
[ -n "$DEVICE_ID" ] && ok || fail "device ID extracted"
echo "  Pairing code: $PAIR_CODE"
echo "  Device ID: $DEVICE_ID"
check

# ── Step 7: Verify hosted API has registered device ──────────────────────────
step "Verify hosted API has registered device"
PAIRING_API=$(curl -sf "http://127.0.0.1:$API_PORT/frames/device/$DEVICE_ID/pairing-status" 2>/dev/null)
[ "$(jval "$PAIRING_API" "d.paired")" = "false" ] && ok || fail "hosted: paired=false"
[ "$(jval "$PAIRING_API" "d.pairing.status")" = "pending" ] && ok || fail "hosted: status=pending"
check

# ── Step 8: Pair device via AosDb (simulating web app) ───────────────────────
step "Pair device via AosDb (simulating web app)"
PAIR_RESULT=$(node -e "
const AosDb = require('$HOSTED_DB');
const db = new AosDb('$DB_FILE');
const result = db.claimPairingCode('$PAIR_CODE', 'user-bridge-test-001');
console.log(JSON.stringify(result));
db.close();
" 2>/dev/null)
[ "$(jval "$PAIR_RESULT" "d.ok")" = "true" ] && ok || fail "pairing claim succeeded"
echo "  Paired device to user-bridge-test-001"
check

# ── Step 9: Check pairing via local UI ───────────────────────────────────────
step "Check pairing via local UI (pairing/check)"
CHECK=$(curl -sf -X POST "http://127.0.0.1:$UI_PORT/local/pairing/check" 2>/dev/null)
[ "$(jval "$CHECK" "d.paired")" = "true" ] && ok || fail "paired=true after pairing"
[ "$(jval "$CHECK" "d.ownerUserId")" = "user-bridge-test-001" ] && ok || fail "ownerUserId set"

# Hosted API also confirms
PAIR_API2=$(curl -sf "http://127.0.0.1:$API_PORT/frames/device/$DEVICE_ID/pairing-status" 2>/dev/null)
[ "$(jval "$PAIR_API2" "d.paired")" = "true" ] && ok || fail "hosted confirms paired"
[ "$(jval "$PAIR_API2" "d.pairing.status")" = "completed" ] && ok || fail "hosted status=completed"
check

# ── Step 10: Sync settings via local UI ──────────────────────────────────────
step "Sync settings via local UI"
SETTINGS_SYNC=$(curl -sf -X POST "http://127.0.0.1:$UI_PORT/local/settings/sync" 2>/dev/null)
[ "$(jval "$SETTINGS_SYNC" "d.ok")" = "true" ] && ok || fail "settings sync ok"
[ "$(jval "$SETTINGS_SYNC" "d.sync !== undefined")" = "true" ] && ok || fail "sync result present"
check

# ── Step 11: Push settings from local UI to hosted API ───────────────────────
step "Push settings from local UI to hosted API"
PUSH=$(curl -sf -X POST "http://127.0.0.1:$UI_PORT/local/settings" \
  -H "content-type: application/json" \
  -d '{"preferences":{"brightness":75,"volume":50},"device":{"deviceName":"Bridge Test Frame"}}' 2>/dev/null)
[ "$(jval "$PUSH" "d.ok")" = "true" ] && ok || fail "settings push ok"

# Verify the hosted API received the settings (read back via hosted API)
DEV_KEY=$(node -e "const d=JSON.parse(require('fs').readFileSync('$LOCAL_UI_DIR/device.json','utf-8'));console.log(d.deviceApiKey||d.device_api_key)")
HOSTED_SETTINGS=$(curl -sf "http://127.0.0.1:$API_PORT/frames/device/$DEVICE_ID/settings" \
  -H "x-frame-device-key: $DEV_KEY" 2>/dev/null)
[ "$(jval "$HOSTED_SETTINGS" "d.ok")" = "true" ] && ok || fail "hosted settings read ok"
[ "$(jval "$HOSTED_SETTINGS" "d.settings.brightness")" = "75" ] && ok || fail "brightness=75 persisted in hosted"
check

# ── Step 12: Send heartbeat via local UI ─────────────────────────────────────
step "Send heartbeat via local UI"
HB=$(curl -sf -X POST "http://127.0.0.1:$UI_PORT/local/heartbeat" 2>/dev/null)
[ "$(jval "$HB" "d.ok")" = "true" ] && ok || fail "heartbeat ok"
[ -n "$(jval "$HB" "d.heartbeatAt")" ] && ok || fail "heartbeatAt present"
[ "$(jval "$HB" "d.deliveryAck !== undefined")" = "true" ] && ok || fail "deliveryAck present"
check

# ── Step 13: Verify heartbeat reached the database ───────────────────────────
step "Verify heartbeat reached the database"
DEVICE_STATUS=$(node -e "
const AosDb = require('$HOSTED_DB');
const db = new AosDb('$DB_FILE');
const row = db.db.prepare('SELECT last_heartbeat_at FROM aos_frame_devices WHERE device_id = ?').get('$DEVICE_ID');
console.log(JSON.stringify(row));
db.close();
" 2>/dev/null)
[ -n "$(jval "$DEVICE_STATUS" "d.last_heartbeat_at")" ] && ok || fail "heartbeat timestamp stored"
echo "  Device status: $DEVICE_STATUS"
check

# ── Step 14: Sync feed via local UI ──────────────────────────────────────────
step "Sync feed via local UI"
FEED=$(curl -sf -X POST "http://127.0.0.1:$UI_PORT/local/feed/sync" 2>/dev/null)
[ "$(jval "$FEED" "d.ok")" = "true" ] && ok || fail "feed sync ok"
[ -n "$(jval "$FEED" "d.syncedAt")" ] && ok || fail "syncedAt present"
[ -n "$(jval "$FEED" "d.endpoint")" ] && ok || fail "endpoint present"

# Hosted API stream endpoint returns correct shape (empty items = ok for now)
STREAM=$(curl -sf "http://127.0.0.1:$API_PORT/frames/device/$DEVICE_ID/stream" \
  -H "x-frame-device-key: $DEV_KEY" 2>/dev/null)
[ "$(jval "$STREAM" "d.ok")" = "true" ] && ok || fail "hosted stream ok"
[ "$(jval "$STREAM" "d.items !== undefined")" = "true" ] && ok || fail "hosted stream has items"
[ "$(jval "$STREAM" "d.polling !== undefined")" = "true" ] && ok || fail "hosted stream has polling"
check

# ── Step 15: Command queue + delivery via heartbeat ──────────────────────────
step "Command queue and delivery via heartbeat"
# Queue a command via AosDb (simulating admin action)
CMD=$(node -e "
const AosDb = require('$HOSTED_DB');
const db = new AosDb('$DB_FILE');
const cmd = db.queueCommand('$DEVICE_ID', 'sync_settings', { source: 'admin_bridge_test' }, 'normal');
console.log(JSON.stringify(cmd));
db.close();
" 2>/dev/null)
CMD_ID=$(jval "$CMD" "d.command.commandId || d.commandId")
[ -n "$CMD_ID" ] && ok || fail "command queued in database"

# Send heartbeat to pick up the command
HB2=$(curl -sf -X POST "http://127.0.0.1:$UI_PORT/local/heartbeat" 2>/dev/null)
[ "$(jval "$HB2" "d.ok")" = "true" ] && ok || fail "heartbeat for command pickup"

# Process commands (this is what populates the audit)
PROCESS=$(curl -sf -X POST "http://127.0.0.1:$UI_PORT/local/commands/process" 2>/dev/null)
[ "$(jval "$PROCESS" "d.ok")" = "true" ] && ok || fail "command process ok"

# Verify commands audit shows the delivered command
COMMANDS=$(curl -sf "http://127.0.0.1:$UI_PORT/local/commands/audit" 2>/dev/null)
[ "$(jval "$COMMANDS" "d.ok")" = "true" ] && ok || fail "command audit ok"
echo "$COMMANDS" | grep -q "sync_settings" && ok || fail "sync_settings command in audit"

echo "  Command $CMD_ID queued, delivered, and processed"
check

# ── Step 16: Check release via local UI ──────────────────────────────────────
step "Check release via local UI"
RELEASE=$(curl -sf -X POST "http://127.0.0.1:$UI_PORT/local/release/check" 2>/dev/null)
[ "$(jval "$RELEASE" "d.ok")" = "true" ] && ok || fail "release check ok"
[ -n "$(jval "$RELEASE" "d.currentVersion")" ] && ok || fail "currentVersion present"
echo "$RELEASE" | grep -q "0.1.1" && ok || fail "correct version 0.1.1"
check

# ── Step 17: Verify device state consistency ─────────────────────────────────
step "Verify device state consistency"

# Local UI status must show paired device with correct owner
STATUS=$(curl -sf "http://127.0.0.1:$UI_PORT/local/status" 2>/dev/null)
[ "$(jval "$STATUS" "d.device.paired")" = "true" ] && ok || fail "status shows paired"
[ "$(jval "$STATUS" "d.device.ownerUserId")" = "user-bridge-test-001" ] && ok || fail "status shows owner"
[ "$(jval "$STATUS" "d.device.hasDeviceApiKey")" = "true" ] && ok || fail "status has device key"
[ "$(jval "$STATUS" "d.device.firstRunComplete")" = "true" ] && ok || fail "first run complete"

# Frame state must be readable
FRAME=$(curl -sf "http://127.0.0.1:$UI_PORT/local/frame-state" 2>/dev/null)
[ "$(jval "$FRAME" "d.ok")" = "true" ] && ok || fail "frame state ok"

# Feed must be accessible
FEED_GET=$(curl -sf "http://127.0.0.1:$UI_PORT/local/feed" 2>/dev/null)
[ "$(jval "$FEED_GET" "d.ok")" = "true" ] && ok || fail "feed accessible"

# Hosted API health must still be good after all operations
FINAL_HEALTH=$(curl -sf "http://127.0.0.1:$API_PORT/health" 2>/dev/null)
[ "$(jval "$FINAL_HEALTH" "d.ok")" = "true" ] && ok || fail "hosted API still healthy after full lifecycle"
check

# ── Step 18: Cross-server consistency ────────────────────────────────────────
step "Cross-server consistency"

# Local UI and hosted API must agree on device ID
[ "$(jval "$STATUS" "d.device.deviceId")" = "$DEVICE_ID" ] && ok || fail "device IDs match"

# Both must agree on owner
[ "$(jval "$STATUS" "d.device.ownerUserId")" = "user-bridge-test-001" ] && ok || fail "owner matches"

# Both must agree on paired state
HOSTED_PAIRING=$(curl -sf "http://127.0.0.1:$API_PORT/frames/device/$DEVICE_ID/pairing-status" 2>/dev/null)
[ "$(jval "$HOSTED_PAIRING" "d.paired")" = "true" ] && ok || fail "hosted confirms paired"
[ "$(jval "$HOSTED_PAIRING" "d.ownerUserId")" = "user-bridge-test-001" ] && ok || fail "hosted confirms owner"

# Settings must be consistent: hosted API has the brightness we pushed
HOSTED_SETTINGS_FINAL=$(curl -sf "http://127.0.0.1:$API_PORT/frames/device/$DEVICE_ID/settings" \
  -H "x-frame-device-key: $DEV_KEY" 2>/dev/null)
[ "$(jval "$HOSTED_SETTINGS_FINAL" "d.settings.brightness")" = "75" ] && ok || fail "hosted settings has brightness=75"

echo "  Device ID: $DEVICE_ID (consistent)"
echo "  Owner: user-bridge-test-001 (consistent)"
echo "  Paired: confirmed by both servers"
echo "  Settings: brightness=75 confirmed in hosted API"
check

# ── Summary ──────────────────────────────────────────────────────────────────
printf "\n═══ Summary: %d passed, %d failed (%d steps) ═══\n" "$PASS" "$FAIL" "$STEP"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
