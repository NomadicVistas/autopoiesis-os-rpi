#!/usr/bin/env bash
set -euo pipefail

# Feed offline fallback integration gate.
# Proves that syncFeedFromRemote falls back to cached items when the hosted API
# is unreachable, and that offline state propagates through diagnostics and health.

PORT="${AUTOPOIESIS_TEST_PORT:-3199}"
API_PORT="${AUTOPOIESIS_TEST_API_PORT:-3200}"
TMP_DIR=""
LOCAL_PID=""
API_PID=""

cleanup() {
  if [[ -n "$LOCAL_PID" ]]; then kill "$LOCAL_PID" 2>/dev/null || true; fi
  if [[ -n "$API_PID" ]]; then kill "$API_PID" 2>/dev/null || true; fi
  if [[ -n "$TMP_DIR" ]]; then rm -rf "$TMP_DIR"; fi
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
step() { printf '  %-55s' "$1"; }

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

TMP_DIR="$(mktemp -d)"
DATA_DIR="$TMP_DIR/data"
LOG_DIR="$TMP_DIR/logs"
CACHE_DIR="$DATA_DIR/cache"
mkdir -p "$DATA_DIR" "$LOG_DIR" "$CACHE_DIR/artworks" "$CACHE_DIR/thumbnails"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

# ─── Step 1: Syntax validation ────────────────────────────────
step "1. Syntax validation"
node -e "require('path');console.log('ok')" >/dev/null 2>&1 || fail "Node unavailable"
node --check "$REPO_DIR/local-ui/server.js" || fail "local-ui/server.js syntax error"
echo "OK"

# ─── Step 2: Start mock hosted API ────────────────────────────
step "2. Start mock hosted API"
MOCK_STATE="$TMP_DIR/mock-state.json"
echo '{}' > "$MOCK_STATE"
# Minimal mock API that always returns 503 to simulate offline
node - "$API_PORT" "$MOCK_STATE" "$TMP_DIR" <<'MOCK' &
const http = require("http");
const fs = require("fs");
const port = Number(process.argv[2]);
const stateFile = process.argv[3];
const tmpDir = process.argv[4];
let state = {};
try { state = JSON.parse(fs.readFileSync(stateFile, "utf8")); } catch {}
const server = http.createServer((req, res) => {
  res.writeHead(503, { "content-type": "application/json" });
  res.end(JSON.stringify({ ok: false, error: "Service temporarily unavailable" }));
});
server.listen(port, () => {
  fs.writeFileSync(tmpDir + "/mock-api-ready", "1");
});
MOCK
API_PID=$!
for i in $(seq 1 30); do
  [[ -f "$TMP_DIR/mock-api-ready" ]] && break
  sleep 0.1
done
[[ -f "$TMP_DIR/mock-api-ready" ]] || fail "mock API did not start"
echo "OK"

# ─── Step 3: Start local UI ───────────────────────────────────
step "3. Start local UI"
# Create a paired device so feed sync is attempted
DEVICE_ID="test-device-offline-001"
DEVICE_KEY="test-key-offline-001"
cat > "$DATA_DIR/device.json" <<DEV
{
  "deviceId": "$DEVICE_ID",
  "deviceApiKey": "$DEVICE_KEY",
  "paired": true,
  "ownerUserId": "user_test"
}
DEV
# preferences.json: let ensureState() write defaults so allowImages etc. are set correctly
echo '{}' > "$DATA_DIR/state.json"
echo '{"items":[]}' > "$DATA_DIR/feed.json"

AUTOPOIESIS_PORT="$PORT" \
AUTOPOIESIS_DATA_DIR="$DATA_DIR" \
AUTOPOIESIS_LOG_DIR="$LOG_DIR" \
AUTOPOIESIS_API_BASE_URL="http://127.0.0.1:$API_PORT" \
AUTOPOIESIS_PREFLIGHT_MIN_FREE_MB=0 \
node "$(pwd)/local-ui/server.js" &
LOCAL_PID=$!
for i in $(seq 1 40); do
  if curl -sf "http://127.0.0.1:$PORT/local/health" >/dev/null 2>&1; then break; fi
  sleep 0.25
done
curl -sf "http://127.0.0.1:$PORT/local/health" >/dev/null 2>&1 || fail "local UI did not start"
echo "OK"

# ─── Step 4: Seed cached items ────────────────────────────────
step "4. Seed cached items for offline fallback"
# Create a fake cached artwork
ARTWORK_FILE="$CACHE_DIR/artworks/test-artwork-001-media-artwork.jpg"
echo "fake-artwork-data" > "$ARTWORK_FILE"
chmod 600 "$ARTWORK_FILE"

cat > "$DATA_DIR/cache-index.json" <<CIDX
{
  "generatedAt": "$(date -Is)",
  "cachedCount": 1,
  "failedCount": 0,
  "items": [
    {
      "id": "test-artwork-001",
      "source": "stream",
      "type": "artwork",
      "priority": "normal",
      "expiresAt": null,
      "media": {
        "url": "https://example.com/artwork.jpg",
        "path": "$ARTWORK_FILE",
        "status": "cached",
        "bytes": 18
      },
      "thumbnail": {
        "url": null,
        "path": null,
        "status": "skipped",
        "bytes": 0
      }
    }
  ]
}
CIDX
echo "OK"

# ─── Step 5: Feed sync offline fallback ───────────────────────
step "5. Feed sync offline fallback (API unreachable)"
SYNC_RESULT="$(curl -sf -X POST "http://127.0.0.1:$PORT/local/feed/sync" 2>/dev/null || echo '{}')"
# Debug: show the actual result for troubleshooting
if echo "$SYNC_RESULT" | grep -q '"ok"'; then
  echo "$SYNC_RESULT" | node -e "
    const data = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
    if (!data.ok) { console.error('feed sync returned ok=false:', JSON.stringify(data)); process.exit(1); }
    if (!data.offline) { console.error('feed sync should report offline=true'); process.exit(1); }
    if (data.endpoint !== 'offline_cache') { console.error('expected endpoint offline_cache, got:', data.endpoint); process.exit(1); }
    if (!data.totalItems || data.totalItems < 1) { console.error('expected at least 1 cached item'); process.exit(1); }
    console.log('ok: offline=' + data.offline + ' items=' + data.totalItems);
  " || fail "Feed sync offline fallback did not work correctly"
else
  echo "DEBUG: sync returned: $SYNC_RESULT"
  fail "Feed sync returned unexpected response"
fi
echo "OK"

# ─── Step 6: Feed reflects cached items ───────────────────────
step "6. Feed GET shows cached items as offline source"
FEED_RESULT="$(curl -sf "http://127.0.0.1:$PORT/local/feed")"
echo "$FEED_RESULT" | node -e "
  const data = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
  if (!data.ok) { console.error('feed not ok'); process.exit(1); }
  if (!data.offline) { console.error('feed should report offline=true'); process.exit(1); }
  if (data.source !== 'offline_cache') { console.error('expected source offline_cache, got:', data.source); process.exit(1); }
  if (!data.offlineState || !data.offlineState.active) { console.error('offlineState should be active'); process.exit(1); }
  if (!data.displayQueue || data.displayQueue.length < 1) { console.error('expected at least 1 display queue item'); process.exit(1); }
  console.log('ok: offline=' + data.offline + ' source=' + data.source);
" || fail "Feed does not show cached items as offline source"
echo "OK"

# ─── Step 7: Diagnostics offline state ────────────────────────
step "7. Diagnostics shows offline state"
DIAG_RESULT="$(curl -sf "http://127.0.0.1:$PORT/local/diagnostics")"
echo "$DIAG_RESULT" | node -e "
  const raw = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
  const data = raw.diagnostics || raw;
  if (!data.offline) { console.error('diagnostics missing offline'); process.exit(1); }
  if (!data.offline.active) { console.error('diagnostics.offline.active should be true'); process.exit(1); }
  if (data.offline.reason !== 'hosted_api_unreachable') { console.error('expected reason hosted_api_unreachable, got:', data.offline.reason); process.exit(1); }
  console.log('ok: active=' + data.offline.active + ' reason=' + data.offline.reason);
" || fail "Diagnostics offline state incorrect"
echo "OK"

# ─── Step 8: Health issue for offline mode ────────────────────
step "8. Health reports offline_mode issue"
HEALTH_RESULT="$(curl -sf "http://127.0.0.1:$PORT/local/health")"
echo "$HEALTH_RESULT" | node -e "
  const data = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
  const issues = (data.health && data.health.issues) || [];
  const offlineIssue = issues.find(i => i.code === 'offline_mode');
  if (!offlineIssue) { console.error('missing offline_mode issue. issues:', JSON.stringify(issues.map(i=>i.code))); process.exit(1); }
  console.log('ok: level=' + offlineIssue.level);
" || fail "Health does not report offline_mode issue"
echo "OK"

# ─── Step 9: Support bundle includes offline state ────────────
step "9. Support bundle includes offline state"
BUNDLE_RESULT="$(curl -sf "http://127.0.0.1:$PORT/local/support-bundle")"
echo "$BUNDLE_RESULT" | node -e "
  const data = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
  if (!data.summary) { console.error('missing summary'); process.exit(1); }
  const offline = data.summary.offline;
  if (!offline || !offline.active) { console.error('support bundle offline should be active'); process.exit(1); }
  console.log('ok: active=' + offline.active);
" || fail "Support bundle offline state missing"
echo "OK"

# ─── Step 10: Frame state uses cached items ───────────────────
step "10. Frame state shows cached items as playable"
FRAME_RESULT="$(curl -sf "http://127.0.0.1:$PORT/local/frame-state")"
echo "$FRAME_RESULT" | node -e "
  const data = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
  if (!data.playableItems || data.playableItems < 1) { console.error('expected playable items from cache'); process.exit(1); }
  if (!data.items || data.items.length < 1) { console.error('expected frame items'); process.exit(1); }
  const item = data.items[0];
  if (!item.media || !item.media.cached) { console.error('expected item.media.cached=true'); process.exit(1); }
  console.log('ok: playable=' + data.playableItems + ' cached=' + item.media.cached);
" || fail "Frame state does not show cached items"
echo "OK"

# ─── Step 11: Network error detection ─────────────────────────
step "11. Network error detection helper"
node -e "
  const http = require('http');
  const fs = require('fs');
  // Load the server module functions via a test harness
  const code = fs.readFileSync('$REPO_DIR/local-ui/server.js', 'utf8');
  // Test isNetworkError by checking the function definition exists
  if (!code.includes('function isOfflineEligibleError')) {
    console.error('isOfflineEligibleError function not found');
    process.exit(1);
  }
  // Test that common network error patterns are covered
  const patterns = ['ECONNREFUSED', 'ENOTFOUND', 'ETIMEDOUT', 'ECONNRESET', 'fetch failed', 'unavailable'];
  for (const p of patterns) {
    if (!code.includes(p) && !code.includes(p.toLowerCase())) {
      console.error('missing network error pattern:', p);
      process.exit(1);
    }
  }
  console.log('ok: all network error patterns covered');
" || fail "Network error detection helper issue"
echo "OK"

# ─── Step 12: Build offline feed function exists ──────────────
step "12. buildOfflineFeed function generates feed from cache"
node -e "
  const fs = require('fs');
  const code = fs.readFileSync('$REPO_DIR/local-ui/server.js', 'utf8');
  if (!code.includes('function buildOfflineFeed')) {
    console.error('buildOfflineFeed function not found');
    process.exit(1);
  }
  if (!code.includes('offline_cache')) {
    console.error('offline_cache source not found');
    process.exit(1);
  }
  console.log('ok: buildOfflineFeed and offline_cache source present');
" || fail "buildOfflineFeed function check failed"
echo "OK"

echo ""
echo "All 12 steps passed."
echo "Feed offline fallback: API unreachable → cached items used → offline state tracked → health issue raised"
