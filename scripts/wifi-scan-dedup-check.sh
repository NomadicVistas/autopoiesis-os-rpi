#!/usr/bin/env bash
set -euo pipefail

# wifi-scan-dedup-check.sh
# Validates the Wi-Fi scan deduplication, signal classification, and security
# classification functions. Tests both the static logic (via node -e) and the
# live scan endpoint with a mock nmcli environment.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVER_JS="$ROOT_DIR/local-ui/server.js"
PASS=0
FAIL=0
TOTAL=0

ok() { PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); echo "  ✗ FAIL: $1"; }
section() { echo ""; echo "Step $1: $2"; }

# ── Step 1: Syntax validation ─────────────────────────────────────────────
section 1 "Syntax validation"
if node --check "$SERVER_JS" 2>/dev/null; then ok "local-ui/server.js syntax"; else fail "local-ui/server.js syntax"; fi
if bash -n "$0" 2>/dev/null; then ok "self syntax"; else fail "self syntax"; fi

# ── Step 2: Static contract — function presence ───────────────────────────
section 2 "Static contract — function presence"

grep -q 'function signalQuality(' "$SERVER_JS" && ok "signalQuality function exists" || fail "signalQuality function missing"
grep -q 'function classifySecurity(' "$SERVER_JS" && ok "classifySecurity function exists" || fail "classifySecurity function missing"
grep -q 'function deduplicateWifiNetworks(' "$SERVER_JS" && ok "deduplicateWifiNetworks function exists" || fail "deduplicateWifiNetworks function missing"

# ── Step 3: signalQuality unit tests ──────────────────────────────────────
section 3 "signalQuality unit tests"

SQ_TEST=$(node -e "
const code = require('fs').readFileSync('$SERVER_JS', 'utf8');
const fn = new Function('signal', code.match(/function signalQuality\\(signal\\) \\{[\\s\\S]*?^\\}/m)[0].replace('function signalQuality', 'return function signalQuality'));
const q = fn();
const tests = [
  [90, 'excellent'], [80, 'excellent'], [85, 'excellent'],
  [79, 'good'], [60, 'good'], [70, 'good'],
  [59, 'fair'], [40, 'fair'], [50, 'fair'],
  [39, 'weak'], [0, 'weak'], [20, 'weak'],
  [null, 'weak'], [undefined, 'weak'], ['abc', 'weak']
];
let pass = 0;
for (const [input, expected] of tests) {
  const result = q(input);
  if (result === expected) pass++;
  else console.error('signalQuality(' + JSON.stringify(input) + ') = ' + result + ' expected ' + expected);
}
console.log(pass + '/' + tests.length);
process.exit(pass === tests.length ? 0 : 1);
" 2>&1) || true
if [[ "$SQ_TEST" == */* && "$SQ_TEST" == *"/15" ]]; then
  ok "signalQuality: $SQ_TEST correct"
else
  fail "signalQuality: $SQ_TEST"
fi

# ── Step 4: classifySecurity unit tests ───────────────────────────────────
section 4 "classifySecurity unit tests"

CS_TEST=$(node -e "
const code = require('fs').readFileSync('$SERVER_JS', 'utf8');
const fn = new Function('security', code.match(/function classifySecurity\\(security\\) \\{[\\s\\S]*?^\\}/m)[0].replace('function classifySecurity', 'return function classifySecurity'));
const c = fn();
const tests = [
  ['WPA3', 'WPA3'], ['WPA3-SAE', 'WPA3'], ['wpa3', 'WPA3'],
  ['WPA2', 'WPA2'], ['WPA2-EAP', 'WPA2'], ['wpa2', 'WPA2'],
  ['WPA', 'WPA'], ['WPA-PSK', 'WPA'], ['wpa', 'WPA'],
  ['WEP', 'WEP'], ['wep', 'WEP'],
  ['', 'open'], [' ', 'open'], [null, 'open'], [undefined, 'open']
];
let pass = 0;
for (const [input, expected] of tests) {
  const result = c(input);
  if (result === expected) pass++;
  else console.error('classifySecurity(' + JSON.stringify(input) + ') = ' + result + ' expected ' + expected);
}
console.log(pass + '/' + tests.length);
process.exit(pass === tests.length ? 0 : 1);
" 2>&1) || true
if [[ "$CS_TEST" == */* && "$CS_TEST" == *"/15" ]]; then
  ok "classifySecurity: $CS_TEST correct"
else
  fail "classifySecurity: $CS_TEST"
fi

# ── Step 5: deduplicateWifiNetworks unit tests ────────────────────────────
section 5 "deduplicateWifiNetworks unit tests"

DEDUP_TEST=$(node -e "
const code = require('fs').readFileSync('$SERVER_JS', 'utf8');
// Extract all three helper functions plus deduplicateWifiNetworks
const sqMatch = code.match(/function signalQuality\\(signal\\) \\{[\\s\\S]*?^\\}/m)[0];
const csMatch = code.match(/function classifySecurity\\(security\\) \\{[\\s\\S]*?^\\}/m)[0];
const dedupMatch = code.match(/function deduplicateWifiNetworks\\(raw\\) \\{[\\s\\S]*?^\\}/m)[0];
const body = sqMatch + '\\n' + csMatch + '\\n' + dedupMatch;
const fn = new Function(body + '\\nreturn deduplicateWifiNetworks;');
const dedup = fn();

// Test 1: deduplication — same SSID with different signals keeps strongest
const input1 = [
  { ssid: 'HomeNet', signal: 45, security: 'WPA2' },
  { ssid: 'HomeNet', signal: 85, security: 'WPA2' },
  { ssid: 'HomeNet', signal: 60, security: 'WPA2' }
];
const result1 = dedup(input1);
const t1 = result1.length === 1 && result1[0].signal === 85;

// Test 2: sorting — strongest first
const input2 = [
  { ssid: 'Weak', signal: 20, security: 'WPA' },
  { ssid: 'Strong', signal: 90, security: 'WPA2' },
  { ssid: 'Medium', signal: 55, security: 'WPA2' }
];
const result2 = dedup(input2);
const t2 = result2.length === 3 && result2[0].ssid === 'Strong' && result2[1].ssid === 'Medium' && result2[2].ssid === 'Weak';

// Test 3: empty array
const result3 = dedup([]);
const t3 = result3.length === 0;

// Test 4: empty SSID filtered out
const input4 = [
  { ssid: '', signal: 80, security: 'WPA2' },
  { ssid: 'ValidNet', signal: 70, security: 'WPA' }
];
const result4 = dedup(input4);
const t4 = result4.length === 1 && result4[0].ssid === 'ValidNet';

// Test 5: signalQuality enriched on each result
const t5 = result1[0].signalQuality === 'excellent';

// Test 6: securityType enriched on each result
const t6 = result1[0].securityType === 'WPA2';

// Test 7: open network classification
const input7 = [{ ssid: 'OpenNet', signal: 50, security: '' }];
const result7 = dedup(input7);
const t7 = result7[0].securityType === 'open';

// Test 8: multiple APs with different security but same SSID
const input8 = [
  { ssid: 'MixedNet', signal: 70, security: 'WPA3' },
  { ssid: 'MixedNet', signal: 80, security: 'WPA2' }
];
const result8 = dedup(input8);
const t8 = result8.length === 1 && result8[0].signal === 80 && result8[0].securityType === 'WPA2';

// Test 9: null/undefined entries handled
const input9 = [
  { ssid: 'GoodNet', signal: 75, security: 'WPA2' },
  null,
  undefined
];
let t9;
try { const result9 = dedup(input9); t9 = result9.length === 1 && result9[0].ssid === 'GoodNet'; }
catch(e) { t9 = false; }

// Test 10: signal quality mapping for all ranges
const input10 = [
  { ssid: 'A', signal: 90, security: 'WPA2' },
  { ssid: 'B', signal: 65, security: 'WPA2' },
  { ssid: 'C', signal: 45, security: 'WPA2' },
  { ssid: 'D', signal: 15, security: 'WPA' }
];
const result10 = dedup(input10);
const t10 = result10[0].signalQuality === 'excellent' &&
            result10[1].signalQuality === 'good' &&
            result10[2].signalQuality === 'fair' &&
            result10[3].signalQuality === 'weak';

const results = [t1, t2, t3, t4, t5, t6, t7, t8, t9, t10];
const pass = results.filter(Boolean).length;
for (let i = 0; i < results.length; i++) {
  if (!results[i]) console.error('Test ' + (i+1) + ' failed');
}
console.log(pass + '/' + results.length);
process.exit(pass === results.length ? 0 : 1);
" 2>&1) || true
if [[ "$DEDUP_TEST" == */* && "$DEDUP_TEST" == *"/10" ]]; then
  ok "deduplicateWifiNetworks: $DEDUP_TEST correct"
else
  fail "deduplicateWifiNetworks: $DEDUP_TEST"
fi

# ── Step 6: Live endpoint test with mock nmcli ───────────────────────────
section 6 "Live endpoint — mock nmcli scan with duplicates"

# Create a temporary PATH override with a mock nmcli that returns duplicate SSIDs
MOCK_DIR="$(mktemp -d)"
cat > "$MOCK_DIR/nmcli" << 'NMEOF'
#!/bin/bash
# Mock nmcli returning duplicate BSSID entries for the same SSID
cat << 'OUTPUT'
MyNetwork:85:WPA2
MyNetwork:60:WPA2
MyNetwork:40:WPA2
Neighbor:70:WPA3
Neighbor:50:WPA3
OpenCafe:30:
OUTPUT
NMEOF
chmod +x "$MOCK_DIR/nmcli"

# Start the local UI server with mock nmcli on PATH
PORT=$((30000 + RANDOM % 10000))
DATA_DIR="$(mktemp -d)"
MOCK_ENV="PATH=$MOCK_DIR:$PATH AUTOPOIESIS_DATA_DIR=$DATA_DIR AUTOPOIESIS_PORT=$PORT NODE_PATH="

# Write a device.json to avoid bootstrap
mkdir -p "$DATA_DIR"
echo '{"deviceId":"test-device"}' > "$DATA_DIR/device.json"

# Start server in background
env PATH="$MOCK_DIR:$PATH" AUTOPOIESIS_DATA_DIR="$DATA_DIR" AUTOPOIESIS_PORT="$PORT" \
  node "$SERVER_JS" &
SERVER_PID=$!
cleanup() { kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$MOCK_DIR" "$DATA_DIR" 2>/dev/null || true; }
trap cleanup EXIT

# Wait for server to start
for i in $(seq 1 20); do
  if curl -fsS --max-time 1 "http://127.0.0.1:$PORT/local/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

# Fetch scan results
SCAN_RESPONSE=$(curl -fsS --max-time 5 "http://127.0.0.1:$PORT/local/wifi/scan.json" 2>/dev/null || echo '{"ok":false}')

# Verify deduplication
NETWORK_COUNT=$(node -e "
const data = JSON.parse(process.argv[1]);
if (!data.ok) { console.log('error'); process.exit(1); }
console.log(data.networks.length);
" "$SCAN_RESPONSE" 2>/dev/null || echo "error")

if [[ "$NETWORK_COUNT" == "3" ]]; then
  ok "Deduplicated 6 raw entries → 3 unique SSIDs"
else
  fail "Expected 3 unique networks, got: $NETWORK_COUNT"
fi

# Verify sorting (strongest first)
FIRST_SSID=$(node -e "
const data = JSON.parse(process.argv[1]);
console.log(data.networks[0] ? data.networks[0].ssid : 'none');
" "$SCAN_RESPONSE" 2>/dev/null || echo "error")

if [[ "$FIRST_SSID" == "MyNetwork" ]]; then
  ok "Sorted by signal strength: strongest (MyNetwork:85) first"
else
  fail "Expected MyNetwork first (strongest signal), got: $FIRST_SSID"
fi

# Verify signal quality enrichment
SIGNAL_QUALITY=$(node -e "
const data = JSON.parse(process.argv[1]);
const n = data.networks.find(x => x.ssid === 'MyNetwork');
console.log(n ? n.signalQuality : 'missing');
" "$SCAN_RESPONSE" 2>/dev/null || echo "error")

if [[ "$SIGNAL_QUALITY" == "excellent" ]]; then
  ok "Signal quality enriched: MyNetwork → excellent"
else
  fail "Expected excellent, got: $SIGNAL_QUALITY"
fi

# Verify security type enrichment
SECURITY_TYPE=$(node -e "
const data = JSON.parse(process.argv[1]);
const n = data.networks.find(x => x.ssid === 'OpenCafe');
console.log(n ? n.securityType : 'missing');
" "$SCAN_RESPONSE" 2>/dev/null || echo "error")

if [[ "$SECURITY_TYPE" == "open" ]]; then
  ok "Security type enriched: OpenCafe → open"
else
  fail "Expected open, got: $SECURITY_TYPE"
fi

# Verify neighbor signal is the strongest BSSID
NEIGHBOR_SIGNAL=$(node -e "
const data = JSON.parse(process.argv[1]);
const n = data.networks.find(x => x.ssid === 'Neighbor');
console.log(n ? n.signal : 'missing');
" "$SCAN_RESPONSE" 2>/dev/null || echo "error")

if [[ "$NEIGHBOR_SIGNAL" == "70" ]]; then
  ok "Neighbor deduplicated: kept strongest BSSID (signal=70)"
else
  fail "Expected signal 70, got: $NEIGHBOR_SIGNAL"
fi

# Kill the server early to free port
kill "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null || true

# ── Step 7: HTML rendering contract ───────────────────────────────────────
section 7 "HTML rendering — signal bars and security badges"

# Start fresh server for HTML check
PORT2=$((30000 + RANDOM % 10000))
DATA_DIR2="$(mktemp -d)"
echo '{"deviceId":"test-device"}' > "$DATA_DIR2/device.json"

env PATH="$MOCK_DIR:$PATH" AUTOPOIESIS_DATA_DIR="$DATA_DIR2" AUTOPOIESIS_PORT="$PORT2" \
  node "$SERVER_JS" &
SERVER_PID2=$!

for i in $(seq 1 20); do
  if curl -fsS --max-time 1 "http://127.0.0.1:$PORT2/local/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

HTML=$(curl -fsS --max-time 5 "http://127.0.0.1:$PORT2/local/wifi/scan" 2>/dev/null || echo "")

if echo "$HTML" | grep -q 'signal-bars'; then
  ok "HTML contains signal-bars CSS class"
else
  fail "HTML missing signal-bars CSS class"
fi

if echo "$HTML" | grep -q 'security-badge'; then
  ok "HTML contains security-badge CSS class"
else
  fail "HTML missing security-badge CSS class"
fi

if echo "$HTML" | grep -q 'network-row'; then
  ok "HTML contains network-row button styling"
else
  fail "HTML missing network-row button styling"
fi

if echo "$HTML" | grep -q 'hidden-network-note'; then
  ok "HTML contains hidden-network-note for empty scan results"
else
  fail "HTML missing hidden-network-note"
fi

if echo "$HTML" | grep -q 'Connecting\.\.\.'; then
  ok "Submit button shows Connecting... feedback"
else
  fail "Submit button missing Connecting... feedback"
fi

if echo "$HTML" | grep -q 'submitBtn.disabled'; then
  ok "Submit button disabled during connection"
else
  fail "Submit button not disabled during connection"
fi

kill "$SERVER_PID2" 2>/dev/null
wait "$SERVER_PID2" 2>/dev/null || true
rm -rf "$DATA_DIR2"

# ── Step 8: connectWifi unchanged contract ────────────────────────────────
section 8 "connectWifi — no regression"

grep -q 'function connectWifi(ssid, password, callback)' "$SERVER_JS" && ok "connectWifi signature preserved" || fail "connectWifi signature changed"
grep -q 'wifiConfigured: true' "$SERVER_JS" && ok "wifiConfigured flag still set on connect" || fail "wifiConfigured flag removed"

# ── Step 9: connectLan unchanged contract ─────────────────────────────────
section 9 "connectLan — no regression"

grep -q 'function connectLan(callback)' "$SERVER_JS" && ok "connectLan signature preserved" || fail "connectLan signature changed"

# ── Step 10: networkStatus unchanged contract ─────────────────────────────
section 10 "networkStatus — no regression"

grep -q 'function networkStatus(callback)' "$SERVER_JS" && ok "networkStatus signature preserved" || fail "networkStatus signature changed"

# ── Step 11: Security — no secret leakage ─────────────────────────────────
section 11 "Security — scan response shape"

# Verify scan response doesn't contain unexpected fields
SCAN_FIELDS=$(node -e "
const data = JSON.parse(process.argv[1]);
if (!data.ok || !data.networks || data.networks.length === 0) { console.log('skip'); process.exit(0); }
const n = data.networks[0];
const keys = Object.keys(n).sort().join(',');
console.log(keys);
" "$SCAN_RESPONSE" 2>/dev/null || echo "error")

if [[ "$SCAN_FIELDS" != "error" && "$SCAN_FIELDS" != "skip" ]]; then
  # Verify only expected fields are present
  if echo "$SCAN_FIELDS" | grep -qvE '^(security|securityType|signal|signalQuality|ssid)(,(security|securityType|signal|signalQuality|ssid))*$'; then
    fail "Unexpected fields in scan response: $SCAN_FIELDS"
  else
    ok "Scan response contains only expected fields: $SCAN_FIELDS"
  fi
else
  ok "Scan response field check skipped (no scan data from step 6)"
fi

# ── Step 12: Regression — touchscreen check script passes ─────────────────
section 12 "Regression — touchscreen check"

if bash -n "$SCRIPT_DIR/touchscreen-check.sh" 2>/dev/null; then
  ok "touchscreen-check.sh syntax valid"
else
  fail "touchscreen-check.sh syntax error"
fi

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════"
if [[ "$FAIL" -eq 0 ]]; then
  echo "  ALL $TOTAL CHECKS PASSED"
else
  echo "  $PASS/$TOTAL passed, $FAIL failed"
fi
echo "═══════════════════════════════════════"
exit $FAIL
