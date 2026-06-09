#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# admin-command-audit-fleet-queue-check.sh
#
# Validation gate for admin command audit logging + fleet-wide command queue.
# Tests: audit table population, audit status lifecycle, fleet commands endpoint,
# command-audits endpoint, filtering, pagination, auth gates, and regression.
#
# Usage: bash scripts/admin-command-audit-fleet-queue-check.sh
# ---------------------------------------------------------------------------
set -euo pipefail

PASS=0
FAIL=0
SKIP=0
STEP=0
TOTAL=0

# Colors
G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; B='\033[0;34m'; N='\033[0m'

ok()   { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); printf "  ${G}✓${N} %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); printf "  ${R}✗${N} %s\n" "$1"; }
skip() { SKIP=$((SKIP+1)); TOTAL=$((TOTAL+1)); printf "  ${Y}⊘${N} %s\n" "$1"; }
step() { STEP=$((STEP+1)); printf "\n${B}── Step %d: %s ──${N}\n" "$STEP" "$1"; }
die()  { printf "\n${R}FATAL: %s${N}\n" "$1"; exit 1; }

cleanup() {
  if [ -n "${SRV_PID:-}" ] && kill -0 "$SRV_PID" 2>/dev/null; then
    kill "$SRV_PID" 2>/dev/null || true
    wait "$SRV_PID" 2>/dev/null || true
  fi
  rm -f "$TMP_DB" 2>/dev/null || true
}
trap cleanup EXIT

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DB=$(mktemp /tmp/aos-audit-check-XXXXXX.db)
ADMIN_TOKEN="test-admin-audit-token-$(date +%s)"
export NODE_PATH="$REPO/node_modules"
PORT=$(( 19300 + (RANDOM % 500) ))

# ── Step 1: Syntax validation ─────────────────────────────────────────────
step "Syntax validation"

node --check "$REPO/hosted-api/server.js" && ok "hosted-api/server.js syntax" || fail "hosted-api/server.js syntax"
node --check "$REPO/hosted-api/db.js"     && ok "hosted-api/db.js syntax"     || fail "hosted-api/db.js syntax"

bash -n "$REPO/install.sh"        2>/dev/null && ok "install.sh syntax"         || fail "install.sh syntax"
bash -n "$REPO/update.sh"         2>/dev/null && ok "update.sh syntax"          || fail "update.sh syntax"
bash -n "$REPO/factory-reset.sh"  2>/dev/null && ok "factory-reset.sh syntax"   || fail "factory-reset.sh syntax"

# ── Step 2: Static contract ──────────────────────────────────────────────
step "Static contract — source code patterns"

SRV="$REPO/hosted-api/server.js"
DB="$REPO/hosted-api/db.js"

grep -q 'logCommandAudit' "$DB"                        && ok "db.js has logCommandAudit method"         || fail "db.js missing logCommandAudit"
grep -q 'updateCommandAuditStatus' "$DB"               && ok "db.js has updateCommandAuditStatus"       || fail "db.js missing updateCommandAuditStatus"
grep -q 'listAllCommands' "$DB"                         && ok "db.js has listAllCommands"                || fail "db.js missing listAllCommands"
grep -q 'listCommandAudits' "$DB"                       && ok "db.js has listCommandAudits"              || fail "db.js missing listCommandAudits"
grep -q 'aos_admin_command_audits' "$DB"                && ok "db.js references aos_admin_command_audits" || fail "db.js missing audit table ref"
grep -q 'logCommandAudit' "$SRV"                        && ok "server.js calls logCommandAudit"          || fail "server.js missing logCommandAudit call"
grep -q 'updateCommandAuditStatus' "$SRV"               && ok "server.js calls updateCommandAuditStatus" || fail "server.js missing updateCommandAuditStatus"
grep -q 'handleAdminListCommands' "$SRV"                && ok "server.js has handleAdminListCommands"    || fail "server.js missing handleAdminListCommands"
grep -q 'handleAdminListCommandAudits' "$SRV"           && ok "server.js has handleAdminListCommandAudits" || fail "server.js missing handleAdminListCommandAudits"
grep -q '/frames/admin/commands' "$SRV"                 && ok "server.js routes /frames/admin/commands"  || fail "server.js missing commands route"
grep -q '/frames/admin/command-audits' "$SRV"           && ok "server.js routes /frames/admin/command-audits" || fail "server.js missing audit route"

grep -q 'CREATE TABLE.*aos_admin_command_audits' "$REPO/scripts/aos-schema-sqlite-validation.sql" \
  && ok "schema has aos_admin_command_audits table"     || fail "schema missing audit table"

# ── Step 3: Server bootstrap ────────────────────────────────────────────
step "Server bootstrap with fresh database"

export AOS_DB="$TMP_DB"
export AOS_PORT="$PORT"
export AOS_HOST="127.0.0.1"
export AUTOPOIESIS_FRAMES_ADMIN_TOKEN="$ADMIN_TOKEN"

node "$REPO/hosted-api/server.js" &
SRV_PID=$!
sleep 1.5

if kill -0 "$SRV_PID" 2>/dev/null; then
  ok "Server started on port $PORT"
else
  fail "Server failed to start"
  die "Cannot continue without server"
fi

# Helper functions
api() {
  local method="$1" path="$2"
  shift 2
  curl -s --max-time 5 "$@" "http://127.0.0.1:$PORT$path"
}

admin_api() {
  local method="$1" path="$2"
  shift 2
  curl -s --max-time 5 -H "x-admin-token: $ADMIN_TOKEN" "$@" "http://127.0.0.1:$PORT$path"
}

# Health check
HEALTH=$(api GET "/health")
echo "$HEALTH" | grep -q '"ok":true' && ok "Health endpoint responds" || fail "Health endpoint failed"

# ── Step 4: Device registration + pairing ───────────────────────────────
step "Device registration + pairing setup"

REG1=$(api POST "/frames/device/register" \
  -H "Content-Type: application/json" \
  -d '{"deviceId":"dev-audit-001","softwareVersion":"0.1.0","deviceName":"Audit Test Frame"}')

DEV1_KEY=$(echo "$REG1" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).device.deviceApiKey" 2>/dev/null || echo "")
PAIR_CODE=$(echo "$REG1" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).pairingCode" 2>/dev/null || echo "")

[ -n "$DEV1_KEY" ] && ok "Device 1 registered with API key" || fail "Device 1 registration"
[ -n "$PAIR_CODE" ] && ok "Pairing code generated" || fail "Pairing code"

# Claim pairing code using db.js claimPairingCode method
PAIR1_OUT=$(node -e "
const AosDb = require('$REPO/hosted-api/db');
const db = new AosDb('$TMP_DB');
const result = db.claimPairingCode('$PAIR_CODE', 'user-alice');
console.log(JSON.stringify(result));
")
echo "$PAIR1_OUT" | grep -q '"ok":true' && ok "Device 1 paired to user-alice" || fail "Device 1 pairing"

# Register a second device
REG2=$(api POST "/frames/device/register" \
  -H "Content-Type: application/json" \
  -d '{"deviceId":"dev-audit-002","softwareVersion":"0.1.0","deviceName":"Second Frame"}')

DEV2_KEY=$(echo "$REG2" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).device.deviceApiKey" 2>/dev/null || echo "")
[ -n "$DEV2_KEY" ] && ok "Device 2 registered" || fail "Device 2 registration"

# Pair device 2
PAIR2_OUT=$(node -e "
const AosDb = require('$REPO/hosted-api/db');
const db = new AosDb('$TMP_DB');
db.db.prepare('UPDATE aos_frame_devices SET owner_user_id = ?, paired = 1 WHERE device_id = ?').run('user-bob', 'dev-audit-002');
console.log('{\"ok\":true}');
")
echo "$PAIR2_OUT" | grep -q '"ok":true' && ok "Device 2 paired to user-bob" || fail "Device 2 pairing"

# Send heartbeat for device 1 (makes it "online" for action gating)
HB1=$(api POST "/frames/device/dev-audit-001/heartbeat" \
  -H "x-frame-device-key: $DEV1_KEY" \
  -H "Content-Type: application/json" \
  -d '{"currentMode":"display"}')
echo "$HB1" | grep -q '"ok":true' && ok "Device 1 heartbeat sent (online)" || fail "Device 1 heartbeat"

# Send heartbeat for device 2
HB2=$(api POST "/frames/device/dev-audit-002/heartbeat" \
  -H "x-frame-device-key: $DEV2_KEY" \
  -H "Content-Type: application/json" \
  -d '{"currentMode":"display"}')
echo "$HB2" | grep -q '"ok":true' && ok "Device 2 heartbeat sent (online)" || fail "Device 2 heartbeat"

# ── Step 5: Admin device action → audit trail creation ──────────────────
step "Admin device action triggers audit logging"

# Queue restart_device via admin action
ACTION1=$(admin_api POST "/frames/admin/devices/dev-audit-001/actions" \
  -H "Content-Type: application/json" \
  -d '{"action":"restart_device","reason":"Testing audit trail"}')

echo "$ACTION1" | grep -q '"queued":true'   && ok "restart_device action queued"    || fail "restart_device action queue"
echo "$ACTION1" | grep -q '"commandId"'     && ok "Response has commandId"           || fail "commandId in response"

CMD1_ID=$(echo "$ACTION1" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).commandId" 2>/dev/null || echo "")
[ -n "$CMD1_ID" ] && ok "Command ID extracted: $CMD1_ID" || fail "Extract command ID"

# Verify audit record was created in the database
AUDIT_CHECK=$(node -e "
const Database = require('better-sqlite3');
const db = new Database('$TMP_DB');
const row = db.prepare('SELECT * FROM aos_admin_command_audits WHERE command_id = ?').get('$CMD1_ID');
if (row) {
  console.log(JSON.stringify({
    found: true,
    commandType: row.command_type,
    risk: row.risk,
    actorId: row.actor_id,
    actorRole: row.actor_role,
    reason: row.reason,
    status: row.status
  }));
} else {
  console.log(JSON.stringify({found: false}));
}
")

echo "$AUDIT_CHECK" | grep -q '"found":true'       && ok "Audit record exists in DB"            || fail "Audit record not found"
echo "$AUDIT_CHECK" | grep -q '"restart_device"'   && ok "Audit has correct command_type"       || fail "Audit command_type mismatch"
echo "$AUDIT_CHECK" | grep -q '"high"'             && ok "Audit has correct risk level (high)"  || fail "Audit risk mismatch"
echo "$AUDIT_CHECK" | grep -q '"admin"'            && ok "Audit actor_id is admin"              || fail "Audit actor_id"
echo "$AUDIT_CHECK" | grep -q 'Testing audit'      && ok "Audit preserves reason"               || fail "Audit reason"
echo "$AUDIT_CHECK" | grep -q '"pending"'          && ok "Audit status is pending"              || fail "Audit initial status"

# Queue a second action (clear_cache) on device 2
ACTION2=$(admin_api POST "/frames/admin/devices/dev-audit-002/actions" \
  -H "Content-Type: application/json" \
  -d '{"action":"clear_cache"}')

echo "$ACTION2" | grep -q '"queued":true' && ok "clear_cache action queued on device 2" || fail "clear_cache action queue"

CMD2_ID=$(echo "$ACTION2" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).commandId" 2>/dev/null || echo "")

# ── Step 6: Fleet-wide commands endpoint ────────────────────────────────
step "Fleet-wide command queue listing"

# Get all commands
ALL_CMDS=$(admin_api GET "/frames/admin/commands")
echo "$ALL_CMDS" | grep -q '"ok":true'    && ok "Commands endpoint responds ok" || fail "Commands endpoint"
echo "$ALL_CMDS" | grep -q '"total":2'    && ok "Total commands = 2"            || fail "Commands total count"

ALL_ITEMS=$(echo "$ALL_CMDS" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).items.length" 2>/dev/null || echo "0")
[ "$ALL_ITEMS" = "2" ] && ok "Returns 2 command items" || fail "Command items count (got $ALL_ITEMS)"

# Filter by device
DEV1_CMDS=$(admin_api GET "/frames/admin/commands?deviceId=dev-audit-001")
DEV1_TOTAL=$(echo "$DEV1_CMDS" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).total" 2>/dev/null || echo "0")
[ "$DEV1_TOTAL" = "1" ] && ok "Filter by deviceId returns 1 command" || fail "deviceId filter (got $DEV1_TOTAL)"

# Filter by status
QUEUED_CMDS=$(admin_api GET "/frames/admin/commands?status=queued")
QUEUED_TOTAL=$(echo "$QUEUED_CMDS" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).total" 2>/dev/null || echo "0")
[ "$QUEUED_TOTAL" = "2" ] && ok "Filter by status=queued returns 2" || fail "status filter (got $QUEUED_TOTAL)"

# Filter by command type
RESTART_CMDS=$(admin_api GET "/frames/admin/commands?commandType=restart_device")
RESTART_TOTAL=$(echo "$RESTART_CMDS" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).total" 2>/dev/null || echo "0")
[ "$RESTART_TOTAL" = "1" ] && ok "Filter by commandType returns 1" || fail "commandType filter (got $RESTART_TOTAL)"

# Pagination
PAGE_CMDS=$(admin_api GET "/frames/admin/commands?limit=1&offset=0")
PAGE_ITEMS=$(echo "$PAGE_CMDS" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).items.length" 2>/dev/null || echo "0")
PAGE_TOTAL=$(echo "$PAGE_CMDS" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).total" 2>/dev/null || echo "0")
[ "$PAGE_ITEMS" = "1" ] && ok "Pagination limit=1 returns 1 item" || fail "pagination limit (got $PAGE_ITEMS)"
[ "$PAGE_TOTAL" = "2" ] && ok "Pagination total still 2"           || fail "pagination total (got $PAGE_TOTAL)"

# ── Step 7: Command audit trail endpoint ────────────────────────────────
step "Command audit trail listing"

# Get all audits
ALL_AUDITS=$(admin_api GET "/frames/admin/command-audits")
echo "$ALL_AUDITS" | grep -q '"ok":true'    && ok "Audit trail endpoint responds ok"  || fail "Audit trail endpoint"
echo "$ALL_AUDITS" | grep -q '"total":2'    && ok "Total audit records = 2"           || fail "Audit total count"

# Filter by device
DEV1_AUDITS=$(admin_api GET "/frames/admin/command-audits?deviceId=dev-audit-001")
DEV1_AUDIT_TOTAL=$(echo "$DEV1_AUDITS" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).total" 2>/dev/null || echo "0")
[ "$DEV1_AUDIT_TOTAL" = "1" ] && ok "Audit filter by deviceId returns 1" || fail "audit deviceId filter (got $DEV1_AUDIT_TOTAL)"

# Filter by command type
AUDIT_BY_TYPE=$(admin_api GET "/frames/admin/command-audits?commandType=clear_cache")
AUDIT_TYPE_TOTAL=$(echo "$AUDIT_BY_TYPE" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).total" 2>/dev/null || echo "0")
[ "$AUDIT_TYPE_TOTAL" = "1" ] && ok "Audit filter by commandType returns 1" || fail "audit commandType filter (got $AUDIT_TYPE_TOTAL)"

# Filter by risk
HIGH_RISK=$(admin_api GET "/frames/admin/command-audits?risk=high")
HIGH_RISK_TOTAL=$(echo "$HIGH_RISK" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).total" 2>/dev/null || echo "0")
[ "$HIGH_RISK_TOTAL" = "1" ] && ok "Audit filter by risk=high returns 1" || fail "audit risk filter (got $HIGH_RISK_TOTAL)"

# Filter by actor role
ADMIN_ROLE=$(admin_api GET "/frames/admin/command-audits?actorRole=admin")
ADMIN_ROLE_TOTAL=$(echo "$ADMIN_ROLE" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).total" 2>/dev/null || echo "0")
[ "$ADMIN_ROLE_TOTAL" = "2" ] && ok "Audit filter by actorRole=admin returns 2" || fail "audit actorRole filter (got $ADMIN_ROLE_TOTAL)"

# Verify audit record fields
FIRST_AUDIT=$(echo "$ALL_AUDITS" | node -pe "JSON.stringify(JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).items[0])" 2>/dev/null || echo "{}")
echo "$FIRST_AUDIT" | grep -q '"auditId"'       && ok "Audit item has auditId"          || fail "audit item auditId"
echo "$FIRST_AUDIT" | grep -q '"commandId"'     && ok "Audit item has commandId"         || fail "audit item commandId"
echo "$FIRST_AUDIT" | grep -q '"deviceId"'      && ok "Audit item has deviceId"          || fail "audit item deviceId"
echo "$FIRST_AUDIT" | grep -q '"commandType"'   && ok "Audit item has commandType"       || fail "audit item commandType"
echo "$FIRST_AUDIT" | grep -q '"risk"'          && ok "Audit item has risk"              || fail "audit item risk"
echo "$FIRST_AUDIT" | grep -q '"actorId"'       && ok "Audit item has actorId"           || fail "audit item actorId"
echo "$FIRST_AUDIT" | grep -q '"actorRole"'     && ok "Audit item has actorRole"         || fail "audit item actorRole"
echo "$FIRST_AUDIT" | grep -q '"payloadSummary"' && ok "Audit item has payloadSummary"   || fail "audit item payloadSummary"
echo "$FIRST_AUDIT" | grep -q '"authorization"' && ok "Audit item has authorization"    || fail "audit item authorization"

# ── Step 8: Audit status lifecycle via command acknowledgement ──────────
step "Audit status lifecycle — command ack updates audit"

# Acknowledge the first command
ACK=$(api POST "/frames/device/dev-audit-001/commands/$CMD1_ID/ack" \
  -H "x-frame-device-key: $DEV1_KEY" \
  -H "Content-Type: application/json" \
  -d '{"status":"acknowledged"}')

echo "$ACK" | grep -q '"ok":true' && ok "Command acknowledged" || fail "Command ack"

# Verify audit status updated
AUDIT_AFTER_ACK=$(node -e "
const Database = require('better-sqlite3');
const db = new Database('$TMP_DB');
const row = db.prepare('SELECT status FROM aos_admin_command_audits WHERE command_id = ?').get('$CMD1_ID');
console.log(row ? row.status : 'not_found');
")

[ "$AUDIT_AFTER_ACK" = "acknowledged" ] && ok "Audit status updated to acknowledged" || fail "Audit status after ack (got $AUDIT_AFTER_ACK)"

# Second command: simulate failure
ACK2=$(api POST "/frames/device/dev-audit-002/commands/$CMD2_ID/ack" \
  -H "x-frame-device-key: $DEV2_KEY" \
  -H "Content-Type: application/json" \
  -d '{"status":"failed","error":"Cache service unavailable"}')

echo "$ACK2" | grep -q '"ok":true' && ok "Second command ack (failed)" || fail "Second command ack"

AUDIT_AFTER_FAIL=$(node -e "
const Database = require('better-sqlite3');
const db = new Database('$TMP_DB');
const row = db.prepare('SELECT status, error FROM aos_admin_command_audits WHERE command_id = ?').get('$CMD2_ID');
console.log(row ? row.status + '|' + (row.error || '') : 'not_found');
")

echo "$AUDIT_AFTER_FAIL" | grep -q '^failed|' && ok "Audit status updated to failed" || fail "Audit status after fail (got $AUDIT_AFTER_FAIL)"
echo "$AUDIT_AFTER_FAIL" | grep -q 'Cache service unavailable' && ok "Audit error message preserved" || fail "Audit error message (got $AUDIT_AFTER_FAIL)"

# Verify audit filter by status
ACKD_AUDITS=$(admin_api GET "/frames/admin/command-audits?status=acknowledged")
ACKD_TOTAL=$(echo "$ACKD_AUDITS" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).total" 2>/dev/null || echo "0")
[ "$ACKD_TOTAL" = "1" ] && ok "Filter by status=acknowledged returns 1" || fail "audit status filter (got $ACKD_TOTAL)"

FAILED_AUDITS=$(admin_api GET "/frames/admin/command-audits?status=failed")
FAILED_TOTAL=$(echo "$FAILED_AUDITS" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).total" 2>/dev/null || echo "0")
[ "$FAILED_TOTAL" = "1" ] && ok "Filter by status=failed returns 1" || fail "audit failed filter (got $FAILED_TOTAL)"

# Commands also reflect ack
ACKD_CMDS=$(admin_api GET "/frames/admin/commands?status=acknowledged")
ACKD_CMD_TOTAL=$(echo "$ACKD_CMDS" | node -pe "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).total" 2>/dev/null || echo "0")
[ "$ACKD_CMD_TOTAL" = "1" ] && ok "Commands filter by status=acknowledged returns 1" || fail "commands status filter (got $ACKD_CMD_TOTAL)"

# ── Step 9: Auth gates ──────────────────────────────────────────────────
step "Authentication gates on new endpoints"

# Commands endpoint without admin token → 401
NO_TOKEN_CMDS=$(api GET "/frames/admin/commands")
echo "$NO_TOKEN_CMDS" | grep -q '401\|Missing admin token' && ok "Commands: no token → 401" || fail "Commands auth gate"

# Commands with wrong token → 403
WRONG_TOKEN_CMDS=$(curl -s --max-time 5 -H "x-admin-token: wrong-token" "http://127.0.0.1:$PORT/frames/admin/commands")
echo "$WRONG_TOKEN_CMDS" | grep -q '403\|Invalid admin token' && ok "Commands: wrong token → 403" || fail "Commands wrong token gate"

# Audits endpoint without admin token → 401
NO_TOKEN_AUDITS=$(api GET "/frames/admin/command-audits")
echo "$NO_TOKEN_AUDITS" | grep -q '401\|Missing admin token' && ok "Audits: no token → 401" || fail "Audits auth gate"

# Audits with wrong token → 403
WRONG_TOKEN_AUDITS=$(curl -s --max-time 5 -H "x-admin-token: wrong-token" "http://127.0.0.1:$PORT/frames/admin/command-audits")
echo "$WRONG_TOKEN_AUDITS" | grep -q '403\|Invalid admin token' && ok "Audits: wrong token → 403" || fail "Audits wrong token gate"

# ── Step 10: Regression ─────────────────────────────────────────────────
step "Regression — existing endpoints unaffected"

# Settings still works
SETTINGS=$(api GET "/frames/device/dev-audit-001/settings")
echo "$SETTINGS" | grep -q '"ok":true' && ok "Settings endpoint unaffected" || fail "Settings regression"

# Admin bundle still works
BUNDLE=$(admin_api GET "/frames/admin/bundle")
echo "$BUNDLE" | grep -q '"ok":true' && ok "Admin bundle unaffected" || fail "Bundle regression"

# Health still works
H2=$(api GET "/health")
echo "$H2" | grep -q '"ok":true' && ok "Health endpoint unaffected" || fail "Health regression"

# Admin device snapshot still works
SNAP=$(admin_api GET "/frames/device/dev-audit-001/admin-snapshot")
echo "$SNAP" | grep -q '"ok":true' && ok "Admin snapshot unaffected" || fail "Snapshot regression"

# ── Summary ─────────────────────────────────────────────────────────────
printf "\n${B}═══════════════════════════════════════════════════════${N}\n"
printf "  Admin Command Audit + Fleet Queue Check\n"
printf "  Steps: %d  Checks: %d  ${G}Pass: %d${N}  ${R}Fail: %d${N}  ${Y}Skip: %d${N}\n" \
  "$STEP" "$TOTAL" "$PASS" "$FAIL" "$SKIP"
printf "${B}═══════════════════════════════════════════════════════${N}\n"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
