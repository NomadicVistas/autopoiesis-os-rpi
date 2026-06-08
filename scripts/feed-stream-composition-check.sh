#!/usr/bin/env bash
# feed-stream-composition-check.sh
#
# Validates the personalized stream composition engine in the mock hosted API.
# Tests content pool diversity, targeting, artist boosting, subscription-tier
# polling, broadcast command inclusion, and device-side pipeline integration.
#
# 12 steps, ~80 checks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOCK_API="$SCRIPT_DIR/mock-hosted-api/server.js"
LOCAL_UI="$SCRIPT_DIR/../local-ui/server.js"
PORT=3159

pass=0
fail=0
step=0
MOCK_PID=""
TMP=""

ok() { pass=$((pass + 1)); }
fail_msg() { fail=$((fail + 1)); echo "  FAIL: $1"; }
step_header() { step=$((step + 1)); echo ""; echo "=== Step $step: $1 ==="; }

cleanup() {
  [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null || true
  [ -n "$TMP" ] && rm -rf "$TMP"
}
trap cleanup EXIT

TMP="$(mktemp -d)"

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Syntax validation
# ─────────────────────────────────────────────────────────────────────────────
step_header "Syntax validation"

node --check "$MOCK_API" 2>/dev/null && ok || fail_msg "mock API syntax"
node --check "$LOCAL_UI" 2>/dev/null && ok || fail_msg "local UI syntax"
bash -n "$0" 2>/dev/null && ok || fail_msg "self syntax"

echo "  ($pass passed, $fail failed)"

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Static content pool contract
# ─────────────────────────────────────────────────────────────────────────────
step_header "Static content pool contract"

# Check MOCK_CONTENT_POOL exists
grep -q 'MOCK_CONTENT_POOL' "$MOCK_API" && ok || fail_msg "MOCK_CONTENT_POOL not found"

# Check MOCK_ARTISTS exists
grep -q 'MOCK_ARTISTS' "$MOCK_API" && ok || fail_msg "MOCK_ARTISTS not found"

# Check composePersonalizedStream exists
grep -q 'function composePersonalizedStream' "$MOCK_API" && ok || fail_msg "composePersonalizedStream not found"

# Check priorityRankValue exists
grep -q 'function priorityRankValue' "$MOCK_API" && ok || fail_msg "priorityRankValue not found"

# Check POST /mock/add-content route
grep -q '/mock/add-content' "$MOCK_API" && ok || fail_msg "POST /mock/add-content route missing"

# Check DELETE /mock/content route
grep -q '/mock/content' "$MOCK_API" && ok || fail_msg "DELETE /mock/content route missing"

# Verify all 6 categories are represented in pool
for cat in artwork broadcast curatorial blog news content; do
  grep -q "\"$cat\"" "$MOCK_API" && ok || fail_msg "category '$cat' not in content pool"
done

# Verify artist IDs in pool match MOCK_ARTISTS
for artist in vessel sandman jessy kinema spool link typo; do
  grep -q "\"$artist\"" "$MOCK_API" && ok || fail_msg "artist '$artist' not in pool"
done

# Verify injectedContent array exists
grep -q 'const injectedContent' "$MOCK_API" && ok || fail_msg "injectedContent array not found"

echo "  ($pass passed, $fail failed)"

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Content item shape validation
# ─────────────────────────────────────────────────────────────────────────────
step_header "Content item shape validation"

node -e "
const fs = require('fs');
const src = fs.readFileSync('$MOCK_API', 'utf-8');

// Extract MOCK_CONTENT_POOL items by parsing the source
const poolMatch = src.match(/const MOCK_CONTENT_POOL = \[([\s\S]*?)\];/);
if (!poolMatch) { console.error('Cannot extract MOCK_CONTENT_POOL'); process.exit(1); }

// Quick check: count items by id: pattern
const ids = poolMatch[1].match(/\{[^}]*id:\s*\"[^\"]+\"/g) || [];
console.log('  Pool items found: ' + ids.length);

// Check various content types present
const srcLower = src.toLowerCase();
const checks = [
  ['image type', srcLower.includes('type: \"image\"')],
  ['video type', srcLower.includes('type: \"video\"')],
  ['audio type', srcLower.includes('type: \"audio\"')],
  ['generative type', srcLower.includes('type: \"generative\"')],
  ['blog_post type', srcLower.includes('type: \"blog_post\"')],
  ['news type', srcLower.includes('type: \"news\"')],
  ['broadcast_message type', srcLower.includes('type: \"broadcast_message\"')],
  ['curatorial type', srcLower.includes('type: \"curatorial\"')],
  ['announcement type', srcLower.includes('type: \"announcement\"')],
  ['targeted item exists', srcLower.includes('targeting:')],
  ['scheduled (future) item', src.includes('startsAt: new Date(Date.now() + 86400000)')],
  ['expired item in pool', src.includes('expiresAt: new Date(Date.now() - 86400000)')]
];

let p = 0, f = 0;
for (const [label, check] of checks) {
  if (check) { p++; } else { f++; console.error('  FAIL: ' + label); }
}
console.log('  Shape checks: ' + p + ' passed, ' + f + ' failed');
if (f > 0) process.exit(1);
" 2>&1 && ok || fail_msg "content item shape validation"

echo "  ($pass passed, $fail failed)"

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Start mock API and register devices
# ─────────────────────────────────────────────────────────────────────────────
step_header "Start mock API and register devices"

AUTOPOIESIS_API_BASE_URL="http://127.0.0.1:$PORT" \
  MOCK_API_PORT="$PORT" \
  node "$MOCK_API" &
MOCK_PID=$!
sleep 1

# Register device A (no owner)
curl -sf -X POST "http://127.0.0.1:$PORT/frames/device/register" \
  -H "Content-Type: application/json" \
  -d '{"deviceName":"Frame-A","softwareVersion":"0.1.1"}' \
  -o "$TMP/reg-a.json"
DEVICE_A_ID=$(node -pe "JSON.parse(require('fs').readFileSync('$TMP/reg-a.json','utf-8')).device.deviceId")
DEVICE_A_KEY=$(node -pe "JSON.parse(require('fs').readFileSync('$TMP/reg-a.json','utf-8')).device.deviceApiKey")

[ -n "$DEVICE_A_ID" ] && [ "$DEVICE_A_ID" != "undefined" ] && ok || fail_msg "device A registration"
[ -n "$DEVICE_A_KEY" ] && [ "$DEVICE_A_KEY" != "undefined" ] && ok || fail_msg "device A key"

# Pair device A
curl -sf -X POST "http://127.0.0.1:$PORT/mock/pair-device/$DEVICE_A_ID" -o "$TMP/pair-a.json"
PAIR_OK=$(node -pe "JSON.parse(require('fs').readFileSync('$TMP/pair-a.json','utf-8')).ok")
[ "$PAIR_OK" = "true" ] && ok || fail_msg "device A pairing"

# Register device B (no owner yet)
curl -sf -X POST "http://127.0.0.1:$PORT/frames/device/register" \
  -H "Content-Type: application/json" \
  -d '{"deviceName":"Frame-B","softwareVersion":"0.1.1"}' \
  -o "$TMP/reg-b.json"
DEVICE_B_ID=$(node -pe "JSON.parse(require('fs').readFileSync('$TMP/reg-b.json','utf-8')).device.deviceId")
DEVICE_B_KEY=$(node -pe "JSON.parse(require('fs').readFileSync('$TMP/reg-b.json','utf-8')).device.deviceApiKey")

[ -n "$DEVICE_B_ID" ] && [ "$DEVICE_B_ID" != "undefined" ] && ok || fail_msg "device B registration"

# Pair device B
curl -sf -X POST "http://127.0.0.1:$PORT/mock/pair-device/$DEVICE_B_ID" -o "$TMP/pair-b.json"
PAIR_B=$(node -pe "JSON.parse(require('fs').readFileSync('$TMP/pair-b.json','utf-8')).ok")
[ "$PAIR_B" = "true" ] && ok || fail_msg "device B pairing"

echo "  Device A: $DEVICE_A_ID"
echo "  Device B: $DEVICE_B_ID"
echo "  ($pass passed, $fail failed)"

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: Default stream (no owner, no preferences) returns diverse content
# ─────────────────────────────────────────────────────────────────────────────
step_header "Default stream returns diverse content"

curl -sf "http://127.0.0.1:$PORT/frames/device/$DEVICE_A_ID/stream" \
  -H "x-frame-device-key: $DEVICE_A_KEY" \
  -o "$TMP/stream-a1.json"

node -e "
const d = JSON.parse(require('fs').readFileSync('$TMP/stream-a1.json','utf-8'));
let p = 0, f = 0;
const chk = (label, cond) => { if (cond) p++; else { f++; console.error('  FAIL: ' + label); } };

chk('ok=true', d.ok === true);
chk('has items array', Array.isArray(d.items));
chk('has multiple items', d.items.length > 2);
chk('has polling', d.polling && typeof d.polling === 'object');
chk('pollAfterSeconds present', typeof d.polling.pollAfterSeconds === 'number');
chk('minPollSeconds present', typeof d.polling.minPollSeconds === 'number');
chk('staleAfter present', typeof d.polling.staleAfter === 'number');
chk('has settings', d.settings && typeof d.settings === 'object');
chk('generatedAt present', typeof d.generatedAt === 'string');

// Check categories present
const cats = new Set(d.items.map(i => i.category || 'unknown'));
chk('has artwork items', cats.has('artwork'));
chk('has broadcast items', cats.has('broadcast') || cats.has('content') || d.items.some(i => i.type === 'broadcast_message'));
chk('has curatorial/blog/news', cats.has('curatorial') || cats.has('blog') || cats.has('news'));

// Check no expired items (expired-001 should be filtered)
const expired = d.items.filter(i => i.id === 'art-expired-001');
chk('expired item filtered out', expired.length === 0);

// Check no future-scheduled items (art-scheduled-001 is future)
const future = d.items.filter(i => i.id === 'art-scheduled-001');
chk('future item filtered out', future.length === 0);

// Check premium-targeted items filtered (no owner = no premium tier)
const premiumOnly = d.items.filter(i => i.id === 'art-vessel-002' || i.id === 'bcast-targeted-001');
chk('premium-targeted items filtered out', premiumOnly.length === 0);

// Check items have required fields
for (const item of d.items) {
  chk('item has id: ' + item.id, typeof item.id === 'string' && item.id.length > 0);
  chk('item has type: ' + item.id, typeof item.type === 'string');
}

console.log('  Checks: ' + p + ' passed, ' + f + ' failed, items: ' + d.items.length);
if (f > 0) process.exit(1);
" 2>&1 && ok || fail_msg "default stream content diversity"

echo "  ($pass passed, $fail failed)"

# ─────────────────────────────────────────────────────────────────────────────
# Step 6: Artist preference boosting
# ─────────────────────────────────────────────────────────────────────────────
step_header "Artist preference boosting"

# Set owner preferences for device A with active artists
curl -sf -X POST "http://127.0.0.1:$PORT/mock/set-owner-preferences/user-a" \
  -H "Content-Type: application/json" \
  -d '{"preferences":{"activeArtists":["vessel","jessy"],"streamCategories":["artwork"]}}' \
  -o "$TMP/prefs-a.json"

# Need to give device A an owner
# Re-pair with owner
curl -sf -X POST "http://127.0.0.1:$PORT/mock/pair-device/$DEVICE_A_ID" \
  -H "Content-Type: application/json" \
  -d '{"ownerUserId":"user-a"}' \
  -o "$TMP/pair-a2.json"

# Get stream with artist preferences
curl -sf "http://127.0.0.1:$PORT/frames/device/$DEVICE_A_ID/stream" \
  -H "x-frame-device-key: $DEVICE_A_KEY" \
  -o "$TMP/stream-a2.json"

node -e "
const d = JSON.parse(require('fs').readFileSync('$TMP/stream-a2.json','utf-8'));
let p = 0, f = 0;
const chk = (label, cond) => { if (cond) p++; else { f++; console.error('  FAIL: ' + label); } };

chk('ok=true', d.ok === true);
chk('has items', d.items.length > 0);

// Check that vessel/jessy artworks appear (boosted to front)
const artworkItems = d.items.filter(i => i.category === 'artwork');
const vesselItems = artworkItems.filter(i => i.artistId === 'vessel');
const jessyItems = artworkItems.filter(i => i.artistId === 'jessy');
chk('vessel artwork present', vesselItems.length > 0);
chk('jessy artwork present', jessyItems.length > 0);

// Check artist-boosted items appear before non-boosted
if (artworkItems.length >= 3) {
  const firstBoosted = artworkItems.findIndex(i => i.artistId === 'vessel' || i.artistId === 'jessy');
  const firstOther = artworkItems.findIndex(i => i.artistId !== 'vessel' && i.artistId !== 'jessy');
  if (firstOther >= 0 && firstBoosted >= 0) {
    chk('boosted artists before others', firstBoosted < firstOther);
  } else {
    // All items are boosted or all are non-boosted, still OK
    chk('boosted artists before others (N/A: all same)', true);
  }
}

// Check owner preferences in response
chk('ownerPreferences present', d.ownerPreferences && typeof d.ownerPreferences === 'object');
chk('ownerPreferencesUpdatedAt present', typeof d.ownerPreferencesUpdatedAt === 'string');

console.log('  Checks: ' + p + ' passed, ' + f + ' failed');
if (f > 0) process.exit(1);
" 2>&1 && ok || fail_msg "artist preference boosting"

echo "  ($pass passed, $fail failed)"

# ─────────────────────────────────────────────────────────────────────────────
# Step 7: Subscription tier targeting and polling
# ─────────────────────────────────────────────────────────────────────────────
step_header "Subscription tier targeting and polling"

# Add a premium user
curl -sf -X POST "http://127.0.0.1:$PORT/mock/add-user" \
  -H "Content-Type: application/json" \
  -d '{"userId":"user-premium","subscriber":{"subscriptionId":"sub-premium-001","plan":"frames_premium","status":"active"}}' \
  -o "$TMP/add-premium.json"

# Pair device B to premium user
curl -sf -X POST "http://127.0.0.1:$PORT/mock/pair-device/$DEVICE_B_ID" \
  -H "Content-Type: application/json" \
  -d '{"ownerUserId":"user-premium"}' \
  -o "$TMP/pair-b2.json"

# Get stream for premium device
curl -sf "http://127.0.0.1:$PORT/frames/device/$DEVICE_B_ID/stream" \
  -H "x-frame-device-key: $DEVICE_B_KEY" \
  -o "$TMP/stream-b1.json"

node -e "
const d = JSON.parse(require('fs').readFileSync('$TMP/stream-b1.json','utf-8'));
let p = 0, f = 0;
const chk = (label, cond) => { if (cond) p++; else { f++; console.error('  FAIL: ' + label); } };

chk('ok=true', d.ok === true);
chk('has items', d.items.length > 0);

// Premium user should see premium-targeted items
const premiumItems = d.items.filter(i => i.id === 'art-vessel-002' || i.id === 'bcast-targeted-001');
chk('premium-targeted items visible', premiumItems.length >= 1);

// Premium polling should be faster
chk('premium pollAfterSeconds < 300', d.polling.pollAfterSeconds < 300);
chk('premium staleAfter < 900', d.polling.staleAfter < 900);

console.log('  Checks: ' + p + ' passed, ' + f + ' failed, premium items: ' + premiumItems.length);
if (f > 0) process.exit(1);
" 2>&1 && ok || fail_msg "subscription tier targeting"

echo "  ($pass passed, $fail failed)"

# ─────────────────────────────────────────────────────────────────────────────
# Step 8: Content injection via POST /mock/add-content
# ─────────────────────────────────────────────────────────────────────────────
step_header "Content injection via POST /mock/add-content"

# Inject custom content
curl -sf -X POST "http://127.0.0.1:$PORT/mock/add-content" \
  -H "Content-Type: application/json" \
  -d '[{"id":"injected-001","type":"image","category":"artwork","title":"Injected Artwork","artist":"Test Artist","artistId":"test-artist","cacheEligible":true,"priority":"high"},{"id":"injected-bcast-001","type":"broadcast_message","category":"broadcast","title":"Injected Broadcast","body":"Test broadcast","priority":"critical"}]' \
  -o "$TMP/inject-result.json"

node -e "
const d = JSON.parse(require('fs').readFileSync('$TMP/inject-result.json','utf-8'));
let p = 0, f = 0;
const chk = (label, cond) => { if (cond) p++; else { f++; console.error('  FAIL: ' + label); } };

chk('ok=true', d.ok === true);
chk('added contains injected-001', d.added.includes('injected-001'));
chk('added contains injected-bcast-001', d.added.includes('injected-bcast-001'));
chk('injectedTotal is 2', d.injectedTotal === 2);

console.log('  Checks: ' + p + ' passed, ' + f + ' failed');
if (f > 0) process.exit(1);
" 2>&1 && ok || fail_msg "content injection response"

# Verify injected items appear in stream
curl -sf "http://127.0.0.1:$PORT/frames/device/$DEVICE_A_ID/stream" \
  -H "x-frame-device-key: $DEVICE_A_KEY" \
  -o "$TMP/stream-a3.json"

node -e "
const d = JSON.parse(require('fs').readFileSync('$TMP/stream-a3.json','utf-8'));
let p = 0, f = 0;
const chk = (label, cond) => { if (cond) p++; else { f++; console.error('  FAIL: ' + label); } };

const injected = d.items.filter(i => i.id === 'injected-001' || i.id === 'injected-bcast-001');
chk('injected items appear in stream', injected.length >= 1);

// Critical priority injected broadcast should be near the front
const bcastIdx = d.items.findIndex(i => i.id === 'injected-bcast-001');
const artIdx = d.items.findIndex(i => i.id === 'injected-001');
if (bcastIdx >= 0 && artIdx >= 0) {
  chk('critical broadcast before high artwork', bcastIdx < artIdx);
} else {
  chk('critical broadcast before high artwork (N/A)', true);
}

console.log('  Checks: ' + p + ' passed, ' + f + ' failed');
if (f > 0) process.exit(1);
" 2>&1 && ok || fail_msg "injected items in stream"

echo "  ($pass passed, $fail failed)"

# ─────────────────────────────────────────────────────────────────────────────
# Step 9: Broadcast command inclusion in stream
# ─────────────────────────────────────────────────────────────────────────────
step_header "Broadcast command inclusion in stream"

# Clear injected content
curl -sf -X DELETE "http://127.0.0.1:$PORT/mock/content" -o "$TMP/clear.json"

# Queue a show_broadcast command
curl -sf -X POST "http://127.0.0.1:$PORT/mock/queue-command/$DEVICE_A_ID" \
  -H "Content-Type: application/json" \
  -d '{"type":"show_broadcast","payload":{"broadcastId":"cmd-bcast-001","title":"Command Broadcast","body":"Sent via command queue","priority":"emergency"}}' \
  -o "$TMP/cmd-bcast.json"

# Get stream and verify broadcast command item appears
curl -sf "http://127.0.0.1:$PORT/frames/device/$DEVICE_A_ID/stream" \
  -H "x-frame-device-key: $DEVICE_A_KEY" \
  -o "$TMP/stream-a4.json"

node -e "
const d = JSON.parse(require('fs').readFileSync('$TMP/stream-a4.json','utf-8'));
let p = 0, f = 0;
const chk = (label, cond) => { if (cond) p++; else { f++; console.error('  FAIL: ' + label); } };

const cmdBcast = d.items.find(i => i.id === 'cmd-bcast-001');
chk('command broadcast in stream', !!cmdBcast);
if (cmdBcast) {
  chk('command broadcast is broadcast_message type', cmdBcast.type === 'broadcast_message');
  chk('command broadcast has correct title', cmdBcast.title === 'Command Broadcast');
  chk('command broadcast has body', cmdBcast.body === 'Sent via command queue');
  chk('command broadcast is emergency priority', cmdBcast.priority === 'emergency');
}

// Emergency should be first item
if (d.items.length > 1 && cmdBcast) {
  chk('emergency broadcast is first item', d.items[0].id === 'cmd-bcast-001');
}

console.log('  Checks: ' + p + ' passed, ' + f + ' failed');
if (f > 0) process.exit(1);
" 2>&1 && ok || fail_msg "broadcast command in stream"

echo "  ($pass passed, $fail failed)"

# ─────────────────────────────────────────────────────────────────────────────
# Step 10: Device-specific targeting
# ─────────────────────────────────────────────────────────────────────────────
step_header "Device-specific targeting"

# Inject item targeted to device B only
curl -sf -X POST "http://127.0.0.1:$PORT/mock/add-content" \
  -H "Content-Type: application/json" \
  -d "{\"id\":\"device-b-only-001\",\"type\":\"image\",\"category\":\"artwork\",\"title\":\"Device B Exclusive\",\"artist\":\"Vessel\",\"artistId\":\"vessel\",\"cacheEligible\":true,\"priority\":\"normal\",\"targeting\":{\"deviceIds\":[\"$DEVICE_B_ID\"]}}"

# Check device A does NOT see it
curl -sf "http://127.0.0.1:$PORT/frames/device/$DEVICE_A_ID/stream" \
  -H "x-frame-device-key: $DEVICE_A_KEY" \
  -o "$TMP/stream-a5.json"

# Check device B DOES see it
curl -sf "http://127.0.0.1:$PORT/frames/device/$DEVICE_B_ID/stream" \
  -H "x-frame-device-key: $DEVICE_B_KEY" \
  -o "$TMP/stream-b2.json"

node -e "
const dA = JSON.parse(require('fs').readFileSync('$TMP/stream-a5.json','utf-8'));
const dB = JSON.parse(require('fs').readFileSync('$TMP/stream-b2.json','utf-8'));
let p = 0, f = 0;
const chk = (label, cond) => { if (cond) p++; else { f++; console.error('  FAIL: ' + label); } };

const inA = dA.items.filter(i => i.id === 'device-b-only-001');
const inB = dB.items.filter(i => i.id === 'device-b-only-001');

chk('device-targeted item NOT in device A stream', inA.length === 0);
chk('device-targeted item IS in device B stream', inB.length === 1);

console.log('  Checks: ' + p + ' passed, ' + f + ' failed');
if (f > 0) process.exit(1);
" 2>&1 && ok || fail_msg "device-specific targeting"

# Clear injected content
curl -sf -X DELETE "http://127.0.0.1:$PORT/mock/content" -o /dev/null

echo "  ($pass passed, $fail failed)"

# ─────────────────────────────────────────────────────────────────────────────
# Step 11: Exclusion targeting
# ─────────────────────────────────────────────────────────────────────────────
step_header "Exclusion targeting"

# Inject item excluding device A
curl -sf -X POST "http://127.0.0.1:$PORT/mock/add-content" \
  -H "Content-Type: application/json" \
  -d "{\"id\":\"exclude-a-001\",\"type\":\"news\",\"category\":\"news\",\"title\":\"Not for A\",\"body\":\"Excluded from device A\",\"cacheEligible\":false,\"priority\":\"normal\",\"targeting\":{\"excludeDeviceIds\":[\"$DEVICE_A_ID\"]}}"

curl -sf "http://127.0.0.1:$PORT/frames/device/$DEVICE_A_ID/stream" \
  -H "x-frame-device-key: $DEVICE_A_KEY" \
  -o "$TMP/stream-a6.json"

curl -sf "http://127.0.0.1:$PORT/frames/device/$DEVICE_B_ID/stream" \
  -H "x-frame-device-key: $DEVICE_B_KEY" \
  -o "$TMP/stream-b3.json"

node -e "
const dA = JSON.parse(require('fs').readFileSync('$TMP/stream-a6.json','utf-8'));
const dB = JSON.parse(require('fs').readFileSync('$TMP/stream-b3.json','utf-8'));
let p = 0, f = 0;
const chk = (label, cond) => { if (cond) p++; else { f++; console.error('  FAIL: ' + label); } };

const inA = dA.items.filter(i => i.id === 'exclude-a-001');
const inB = dB.items.filter(i => i.id === 'exclude-a-001');

chk('excluded item NOT in device A', inA.length === 0);
chk('excluded item IS in device B', inB.length === 1);

console.log('  Checks: ' + p + ' passed, ' + f + ' failed');
if (f > 0) process.exit(1);
" 2>&1 && ok || fail_msg "exclusion targeting"

# Clear
curl -sf -X DELETE "http://127.0.0.1:$PORT/mock/content" -o /dev/null

echo "  ($pass passed, $fail failed)"

# ─────────────────────────────────────────────────────────────────────────────
# Step 12: Trial-tier polling and degraded subscription
# ─────────────────────────────────────────────────────────────────────────────
step_header "Trial-tier polling and degraded subscription"

# Add trial user
curl -sf -X POST "http://127.0.0.1:$PORT/mock/add-user" \
  -H "Content-Type: application/json" \
  -d '{"userId":"user-trial","subscriber":{"subscriptionId":"sub-trial-001","plan":"frames_trial","status":"trial"}}' \
  -o "$TMP/add-trial.json"

# Register and pair device C
curl -sf -X POST "http://127.0.0.1:$PORT/frames/device/register" \
  -H "Content-Type: application/json" \
  -d '{"deviceName":"Frame-C","softwareVersion":"0.1.1"}' \
  -o "$TMP/reg-c.json"
DEVICE_C_ID=$(node -pe "JSON.parse(require('fs').readFileSync('$TMP/reg-c.json','utf-8')).device.deviceId")
DEVICE_C_KEY=$(node -pe "JSON.parse(require('fs').readFileSync('$TMP/reg-c.json','utf-8')).device.deviceApiKey")

curl -sf -X POST "http://127.0.0.1:$PORT/mock/pair-device/$DEVICE_C_ID" \
  -H "Content-Type: application/json" \
  -d "{\"ownerUserId\":\"user-trial\"}" \
  -o "$TMP/pair-c.json"

curl -sf "http://127.0.0.1:$PORT/frames/device/$DEVICE_C_ID/stream" \
  -H "x-frame-device-key: $DEVICE_C_KEY" \
  -o "$TMP/stream-c1.json"

node -e "
const d = JSON.parse(require('fs').readFileSync('$TMP/stream-c1.json','utf-8'));
let p = 0, f = 0;
const chk = (label, cond) => { if (cond) p++; else { f++; console.error('  FAIL: ' + label); } };

chk('ok=true', d.ok === true);

// Trial user should have slower polling
chk('trial pollAfterSeconds > 300', d.polling.pollAfterSeconds > 300);
chk('trial staleAfter > 900', d.polling.staleAfter > 900);

// Trial user should NOT see premium-targeted items
const premiumItems = d.items.filter(i => i.id === 'art-vessel-002' || i.id === 'bcast-targeted-001');
chk('premium items filtered for trial user', premiumItems.length === 0);

// Trial user should see non-targeted content
chk('trial user has content', d.items.length > 0);

console.log('  Checks: ' + p + ' passed, ' + f + ' failed');
if (f > 0) process.exit(1);
" 2>&1 && ok || fail_msg "trial-tier polling"

# Now degrade subscription to expired
curl -sf -X POST "http://127.0.0.1:$PORT/mock/transition-subscription/user-trial" \
  -H "Content-Type: application/json" \
  -d '{"status":"cancelled"}' \
  -o "$TMP/trans-c1.json"

# Note: trial->cancelled is valid; then cancelled->expired
curl -sf -X POST "http://127.0.0.1:$PORT/mock/transition-subscription/user-trial" \
  -H "Content-Type: application/json" \
  -d '{"status":"expired"}' \
  -o "$TMP/trans-c2.json" 2>/dev/null || true

curl -sf "http://127.0.0.1:$PORT/frames/device/$DEVICE_C_ID/stream" \
  -H "x-frame-device-key: $DEVICE_C_KEY" \
  -o "$TMP/stream-c2.json"

node -e "
const d = JSON.parse(require('fs').readFileSync('$TMP/stream-c2.json','utf-8'));
let p = 0, f = 0;
const chk = (label, cond) => { if (cond) p++; else { f++; console.error('  FAIL: ' + label); } };

// Expired user still gets stream (degraded but not blocked)
chk('ok=true even when expired', d.ok === true);
chk('still has items', d.items.length > 0);

// Premium-targeted items still filtered
const premiumItems = d.items.filter(i => i.id === 'art-vessel-002' || i.id === 'bcast-targeted-001');
chk('premium items filtered for expired user', premiumItems.length === 0);

console.log('  Checks: ' + p + ' passed, ' + f + ' failed');
if (f > 0) process.exit(1);
" 2>&1 && ok || fail_msg "degraded subscription stream"

echo "  ($pass passed, $fail failed)"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  Feed Stream Composition Check Complete"
echo "  Steps: $step/12 | Passed: $pass | Failed: $fail"
echo "============================================"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
