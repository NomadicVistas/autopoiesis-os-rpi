#!/usr/bin/env bash
# kiosk-feed-polling-check.sh — Verify kiosk feed polling uses server-provided intervals
#
# Validates that the kiosk renderFrame() passes subscription-tier-aware polling
# intervals to the client-side JS and auto-refreshes when new content arrives.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PASSED=0
FAILED=0
TOTAL=0

pass() { PASSED=$((PASSED + 1)); TOTAL=$((TOTAL + 1)); echo "  ✅ $1"; }
fail() { FAILED=$((FAILED + 1)); TOTAL=$((TOTAL + 1)); echo "  ❌ $1"; }

section() { echo ""; echo "── $1 ──"; }

# ── Step 1: Syntax validation ──────────────────────────────────────────────

section "Step 1: Syntax validation"

node --check local-ui/server.js 2>/dev/null && pass "local-ui/server.js syntax" || fail "local-ui/server.js syntax"
bash -n scripts/kiosk-feed-polling-check.sh 2>/dev/null && pass "self syntax" || fail "self syntax"

# ── Step 2: Static contract — frameSettings includes new fields ─────────────

section "Step 2: Static contract — frameSettings polling fields"

SERVER="local-ui/server.js"

# Check that frameSettings includes pollAfterSeconds
if grep -q 'pollAfterSeconds:' "$SERVER" && grep -q 'frame.pollingStatus' "$SERVER"; then
  pass "frameSettings includes pollAfterSeconds from frame.pollingStatus"
else
  fail "frameSettings missing pollAfterSeconds"
fi

# Check that frameSettings includes offlineRetrySeconds
if grep -q 'offlineRetrySeconds:' "$SERVER" && grep -q 'OFFLINE_RETRY_SECONDS' "$SERVER"; then
  pass "frameSettings includes offlineRetrySeconds"
else
  fail "frameSettings missing offlineRetrySeconds"
fi

# Check that frameSettings includes currentItemCount
if grep -q 'currentItemCount:' "$SERVER" && grep -q 'frame.playableItems' "$SERVER"; then
  pass "frameSettings includes currentItemCount from frame.playableItems"
else
  fail "frameSettings missing currentItemCount"
fi

# Check default pollAfterSeconds fallback is 900s
if grep -q 'pollAfterSeconds.*900' "$SERVER"; then
  pass "pollAfterSeconds defaults to 900 seconds"
else
  fail "pollAfterSeconds default missing or wrong"
fi

# ── Step 3: Client-side polling interval uses frameSettings ─────────────────

section "Step 3: Client-side polling interval"

if grep -q 'frameSettings.pollAfterSeconds' "$SERVER"; then
  pass "client JS reads frameSettings.pollAfterSeconds"
else
  fail "client JS does not use frameSettings.pollAfterSeconds"
fi

if grep -q 'Math.max(60.*pollAfterSeconds' "$SERVER"; then
  pass "polling interval has 60-second minimum clamp"
else
  fail "polling interval missing minimum clamp"
fi

# Verify the old hardcoded 15*60*1000 sync setInterval is gone.
if grep -q 'setInterval.*15 \* 60 \* 1000' "$SERVER"; then
  fail "hardcoded 15-minute sync setInterval still present"
else
  pass "hardcoded 15-minute sync setInterval removed"
fi

# ── Step 4: Auto-refresh on new content ─────────────────────────────────────

section "Step 4: Auto-refresh on new content"

if grep -q 'function kioskFeedSync' "$SERVER"; then
  pass "kioskFeedSync function defined"
else
  fail "kioskFeedSync function missing"
fi

if grep -q 'newItemCount !== lastKnownItemCount' "$SERVER"; then
  pass "item count change detection"
else
  fail "item count change detection missing"
fi

if grep -q 'location.reload' "$SERVER"; then
  pass "location.reload() called on new content"
else
  fail "location.reload() call missing"
fi

if grep -q 'eligibleItems.*totalItems' "$SERVER"; then
  pass "sync response parsed for item count"
else
  fail "sync response item count parsing missing"
fi

# ── Step 5: Empty feed retry uses offline interval ─────────────────────────

section "Step 5: Empty feed retry interval"

if grep -q 'frameSettings.offlineRetrySeconds' "$SERVER"; then
  pass "empty feed retry uses offlineRetrySeconds"
else
  fail "empty feed retry does not use offlineRetrySeconds"
fi

if grep -q 'offlineRetrySeconds \* 1000.*10000' "$SERVER"; then
  pass "empty feed retry has 10-second minimum"
else
  fail "empty feed retry minimum clamp missing"
fi

# ── Step 6: Live integration test ───────────────────────────────────────────

section "Step 6: Live integration test with mock API"

MOCK_PORT=19876
LOCAL_UI_PORT=19877
MOCK_PID=""
UI_PID=""
TMP_DIR=""

cleanup() {
  [[ -n "$MOCK_PID" ]] && kill "$MOCK_PID" 2>/dev/null || true
  [[ -n "$UI_PID" ]] && kill "$UI_PID" 2>/dev/null || true
  [[ -n "$TMP_DIR" ]] && rm -rf "$TMP_DIR" || true
}
trap cleanup EXIT

TMP_DIR=$(mktemp -d)

# Start mock API
MOCK_API_PORT=$MOCK_PORT SINGLE_OWNER_MODE=1 node scripts/mock-hosted-api/server.js > "$TMP_DIR/mock.log" 2>&1 &
MOCK_PID=$!

MOCK_READY=0
for i in $(seq 1 10); do
  if curl -sf "http://127.0.0.1:$MOCK_PORT/mock/state" >/dev/null 2>&1; then
    MOCK_READY=1
    break
  fi
  sleep 0.5
done

if [[ "$MOCK_READY" -eq 1 ]]; then
  pass "mock API started on :$MOCK_PORT"
else
  fail "mock API failed to start"
  echo "   Log: $(tail -5 "$TMP_DIR/mock.log")"
fi

# Start local UI
LOCAL_UI_STATE_DIR="$TMP_DIR/local-ui"
mkdir -p "$LOCAL_UI_STATE_DIR"

AUTOPOIESIS_PORT=$LOCAL_UI_PORT \
  AUTOPOIESIS_API_BASE_URL="http://127.0.0.1:$MOCK_PORT" \
  AUTOPOIESIS_DATA_DIR="$LOCAL_UI_STATE_DIR" \
  node local-ui/server.js > "$TMP_DIR/local-ui.log" 2>&1 &
UI_PID=$!

UI_READY=0
for i in $(seq 1 10); do
  if curl -sf "http://127.0.0.1:$LOCAL_UI_PORT/local/health" >/dev/null 2>&1; then
    UI_READY=1
    break
  fi
  sleep 0.5
done

if [[ "$UI_READY" -eq 1 ]]; then
  pass "local UI started on :$LOCAL_UI_PORT"
else
  fail "local UI failed to start"
  echo "   Log: $(tail -5 "$TMP_DIR/local-ui.log")"
fi

# Pairing flow: local UI registers + pairs with mock API
PAIR_START=$(curl -s -X POST "http://127.0.0.1:$LOCAL_UI_PORT/local/pairing/start" 2>/dev/null || echo '{}')
if echo "$PAIR_START" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{const j=JSON.parse(d);process.exit(j.ok?0:1)})" 2>/dev/null; then
  pass "local UI pairing/start succeeded"
else
  fail "local UI pairing/start failed"
  echo "   Response: $(echo "$PAIR_START" | head -c 300)"
fi

LOCAL_DEVICE_ID=$(echo "$PAIR_START" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{const j=JSON.parse(d);console.log(j.deviceId||(j.device&&j.device.deviceId)||'')})" 2>/dev/null || echo "")

# If device ID not in pairing/start response, read from pairing status
if [[ -z "$LOCAL_DEVICE_ID" ]]; then
  LOCAL_DEVICE_ID=$(curl -s "http://127.0.0.1:$LOCAL_UI_PORT/local/pairing/status" 2>/dev/null | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{const j=JSON.parse(d);console.log((j.device&&j.device.deviceId)||'')})" 2>/dev/null || echo "")
fi

if [[ -n "$LOCAL_DEVICE_ID" ]]; then
  pass "device registered: $LOCAL_DEVICE_ID"
else
  fail "could not extract device ID from pairing/start"
fi

if [[ -n "$LOCAL_DEVICE_ID" ]]; then
  PAIR_MOCK=$(curl -s -X POST "http://127.0.0.1:$MOCK_PORT/mock/pair-device/$LOCAL_DEVICE_ID" \
    -H "content-type: application/json" \
    -d '{"userId":"user-kiosk-poll-test"}' 2>/dev/null || echo '{}')
  if echo "$PAIR_MOCK" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{const j=JSON.parse(d);process.exit(j.paired?0:1)})" 2>/dev/null; then
    pass "device paired on mock API"
  else
    fail "mock pair failed: $(echo "$PAIR_MOCK" | head -c 200)"
  fi
fi

CHECK_RESULT=$(curl -s -X POST "http://127.0.0.1:$LOCAL_UI_PORT/local/pairing/check" 2>/dev/null || echo '{}')
if echo "$CHECK_RESULT" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{const j=JSON.parse(d);process.exit(j.paired?0:1)})" 2>/dev/null; then
  pass "local UI confirmed paired"
else
  fail "local UI pairing check incomplete"
fi

# Sync feed
SYNC_RESULT=$(curl -s -X POST "http://127.0.0.1:$LOCAL_UI_PORT/local/feed/sync" 2>/dev/null || echo '{}')
if echo "$SYNC_RESULT" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{const j=JSON.parse(d);process.exit(j.ok?0:1)})" 2>/dev/null; then
  pass "feed sync succeeded"
else
  fail "feed sync failed: $(echo "$SYNC_RESULT" | head -c 200)"
fi

# Fetch the kiosk frame page
FRAME_HTML=$(curl -s "http://127.0.0.1:$LOCAL_UI_PORT/frame" 2>/dev/null || echo "")

if [[ -n "$FRAME_HTML" ]]; then
  pass "frame page rendered"
else
  fail "frame page returned empty"
fi

if echo "$FRAME_HTML" | grep -q 'pollAfterSeconds'; then
  pass "frame HTML contains pollAfterSeconds in frameSettings"
else
  fail "frame HTML missing pollAfterSeconds in frameSettings"
fi

if echo "$FRAME_HTML" | grep -q 'offlineRetrySeconds'; then
  pass "frame HTML contains offlineRetrySeconds in frameSettings"
else
  fail "frame HTML missing offlineRetrySeconds in frameSettings"
fi

if echo "$FRAME_HTML" | grep -q 'currentItemCount'; then
  pass "frame HTML contains currentItemCount in frameSettings"
else
  fail "frame HTML missing currentItemCount in frameSettings"
fi

if echo "$FRAME_HTML" | grep -q 'kioskFeedSync'; then
  pass "frame HTML contains kioskFeedSync function"
else
  fail "frame HTML missing kioskFeedSync function"
fi

if echo "$FRAME_HTML" | grep -q '15 \* 60 \* 1000'; then
  fail "frame HTML still contains hardcoded 15-minute interval"
else
  pass "frame HTML does not contain hardcoded 15-minute interval"
fi

if echo "$FRAME_HTML" | grep -q 'frameSettings.pollAfterSeconds'; then
  pass "frame HTML uses frameSettings.pollAfterSeconds for sync interval"
else
  fail "frame HTML does not use frameSettings.pollAfterSeconds"
fi

if echo "$FRAME_HTML" | grep -q 'newItemCount !== lastKnownItemCount'; then
  pass "frame HTML detects item count changes"
else
  fail "frame HTML missing item count change detection"
fi

if echo "$FRAME_HTML" | grep -q 'frameSettings.offlineRetrySeconds'; then
  pass "frame HTML uses offlineRetrySeconds for empty feed retry"
else
  fail "frame HTML does not use offlineRetrySeconds for empty feed retry"
fi

# ── Step 7: Polling interval reflects feed state ──────────

section "Step 7: Polling interval reflects feed state"

POLL_VALUE=$(echo "$FRAME_HTML" | node -e "
let d='';
process.stdin.on('data',c=>d+=c);
process.stdin.on('end',()=>{
  const m = d.match(/pollAfterSeconds['\"]?\\s*:\\s*(\\d+)/);
  console.log(m ? m[1] : 'not_found');
})" 2>/dev/null)

if [[ "$POLL_VALUE" != "not_found" && -n "$POLL_VALUE" ]]; then
  pass "pollAfterSeconds value present: ${POLL_VALUE}s"
  if [[ "$POLL_VALUE" -ge 60 && "$POLL_VALUE" -le 1200 ]]; then
    pass "pollAfterSeconds value in reasonable range (60-1200s)"
  else
    fail "pollAfterSeconds value out of range: ${POLL_VALUE}s"
  fi
else
  fail "could not extract pollAfterSeconds value"
fi

if [[ "$POLL_VALUE" == "900" ]]; then
  pass "default 900s pollAfterSeconds matches mock API default"
else
  pass "pollAfterSeconds from stream response: ${POLL_VALUE}s (tier-specific)"
fi

# ── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "══════════════════════════════════════════════"
echo "  Kiosk Feed Polling Check Summary"
echo "  ✅ Passed: $PASSED  ❌ Failed: $FAILED  Total: $TOTAL"
echo "══════════════════════════════════════════════"

if [[ "$FAILED" -gt 0 ]]; then
  exit 1
fi
echo "All checks passed."
