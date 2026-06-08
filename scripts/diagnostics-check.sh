#!/usr/bin/env bash
# diagnostics-check.sh — isolated gate for scripts/diagnostics.sh
#
# Validates the standalone diagnostics CLI tool without needing
# a Raspberry Pi or running appliance services.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DIAG="$ROOT_DIR/scripts/diagnostics.sh"
APP_DIR="$ROOT_DIR"
DATA_DIR=""
INSTALL_DIR=""
LOG_DIR=""
PASS=0; FAIL=0; SKIP=0

step() { printf '\n=== Step %s: %s ===\n' "$1" "$2"; }
pass() { PASS=$((PASS + 1)); echo "  ✓ $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ FAIL: $*" >&2; }
skip() { SKIP=$((SKIP + 1)); echo "  ○ SKIP: $*"; }

setup_env() {
  DATA_DIR="$(mktemp -d)"
  INSTALL_DIR="$(mktemp -d)"
  LOG_DIR="$(mktemp -d)"
  mkdir -p "$INSTALL_DIR/cache/artworks" "$DATA_DIR"
}
cleanup_env() {
  rm -rf "$DATA_DIR" "$INSTALL_DIR" "$LOG_DIR" 2>/dev/null || true
}

run_diag() {
  AUTOPOIESIS_APP_DIR="$APP_DIR" \
  AUTOPOIESIS_DATA_DIR="$DATA_DIR" \
  AUTOPOIESIS_INSTALL_DIR="$INSTALL_DIR" \
  AUTOPOIESIS_LOG_DIR="$LOG_DIR" \
  AUTOPOIESIS_LOCAL_URL="http://127.0.0.1:19999" \
  timeout 30 bash "$DIAG" "$@"
}

echo "diagnostics-check — isolated gate for diagnostics.sh"

# ── Step 1: syntax validation ────────────────────────────────────────────────

step 1 "Syntax validation"
bash -n "$DIAG" && pass "bash syntax OK" || fail "bash syntax error"
node --check "$ROOT_DIR/local-ui/server.js" 2>/dev/null && pass "local-ui/server.js syntax OK" || true

# ── Step 2: help output ─────────────────────────────────────────────────────

step 2 "Help output"
HELP_OUT="$(run_diag --help 2>&1)" || true
echo "$HELP_OUT" | grep -q "diagnostics.sh" && pass "help mentions script name" || fail "help missing script name"
echo "$HELP_OUT" | grep -q "\-\-json" && pass "help mentions --json" || fail "help missing --json"
echo "$HELP_OUT" | grep -q "\-\-quick" && pass "help mentions --quick" || fail "help missing --quick"
echo "$HELP_OUT" | grep -q "\-\-verbose" && pass "help mentions --verbose" || fail "help missing --verbose"

# ── Step 3: invalid argument rejection ───────────────────────────────────────

step 3 "Invalid argument rejection"
RC=0
run_diag --bogus 2>&1 || RC=$?
[[ "$RC" == "2" ]] && pass "--bogus exits 2" || fail "--bogus exit code: $RC (expected 2)"

# ── Step 4: default (text) output in empty environment ──────────────────────

step 4 "Text output in empty environment"
setup_env
OUT="$(run_diag --quick 2>&1)"; RC=$?
echo "$OUT" | grep -q "Autopoiesis Frame Diagnostics" && pass "text header present" || fail "text header missing"
echo "$OUT" | grep -q "System" && pass "System section present" || fail "System section missing"
echo "$OUT" | grep -q "Services" && pass "Services section present" || fail "Services section missing"
echo "$OUT" | grep -q "Network" && pass "Network section present" || fail "Network section missing"
echo "$OUT" | grep -q "Local UI" && pass "Local UI section present" || fail "Local UI section missing"
echo "$OUT" | grep -q "Device" && pass "Device section present" || fail "Device section missing"
echo "$OUT" | grep -q "Cache" && pass "Cache section present" || fail "Cache section missing"
echo "$OUT" | grep -q "Kiosk" && pass "Kiosk section present" || fail "Kiosk section missing"
echo "$OUT" | grep -q "Summary:" && pass "Summary line present" || fail "Summary line missing"
# Should have some failures (no services, no server, no device.json)
echo "$OUT" | grep -q "ISSUES DETECTED" && pass "detects issues in empty env" || fail "should detect issues"
cleanup_env

# ── Step 5: text output with device data ─────────────────────────────────────

step 5 "Text output with device data"
setup_env
# Write a device.json
cat > "$DATA_DIR/device.json" <<'DEVJSON'
{
  "deviceId": "test-device-001",
  "paired": true,
  "lastHeartbeatAt": "2026-06-08T08:00:00Z",
  "softwareVersion": "0.1.1"
}
DEVJSON
# Write a state.json
cat > "$DATA_DIR/state.json" <<'STATEJSON'
{
  "currentMode": "living-stream",
  "offline": { "active": false, "reason": null }
}
STATEJSON
# Write cache index with 3 items
cat > "$DATA_DIR/cache-index.json" <<'CACHEJSON'
[
  {"id":"art-1","type":"image","cacheAllowed":true},
  {"id":"art-2","type":"image","cacheAllowed":true},
  {"id":"art-3","type":"video","cacheAllowed":true}
]
CACHEJSON

OUT="$(run_diag --quick 2>&1)"
echo "$OUT" | grep -q "test-device-001" && pass "shows device ID" || fail "device ID missing"
echo "$OUT" | grep -q "Device is paired" && pass "shows paired status" || fail "paired status missing"
echo "$OUT" | grep -q "3 artworks cached" && pass "shows cache count" || fail "cache count wrong"
echo "$OUT" | grep -q "Online mode" && pass "shows online mode" || fail "online mode missing"
cleanup_env

# ── Step 6: offline state detection ──────────────────────────────────────────

step 6 "Offline state detection"
setup_env
cat > "$DATA_DIR/device.json" <<'DEVJSON'
{"deviceId":"offline-test","paired":false}
DEVJSON
cat > "$DATA_DIR/state.json" <<'STATEJSON'
{"currentMode":"living-stream","offline":{"active":true,"reason":"hosted_api_unreachable"}}
STATEJSON
OUT="$(run_diag --quick 2>&1)"
echo "$OUT" | grep -q "offline_mode" && pass "offline mode check present" || fail "offline mode check missing"
echo "$OUT" | grep -qi "offline" && pass "offline state mentioned" || fail "offline state not reported"
cleanup_env

# ── Step 7: JSON output ─────────────────────────────────────────────────────

step 7 "JSON output structure"
setup_env
cat > "$DATA_DIR/device.json" <<'DEVJSON'
{"deviceId":"json-test-001","paired":true,"lastHeartbeatAt":"2026-06-08T09:00:00Z"}
DEVJSON
cat > "$DATA_DIR/state.json" <<'STATEJSON'
{"currentMode":"living-stream","offline":{"active":false}}
STATEJSON

JSON_OUT="$(run_diag --json --quick 2>&1)"
# Validate JSON
echo "$JSON_OUT" | node -e "
  const j = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
  const assert = (cond, msg) => { if (!cond) { console.error('FAIL: ' + msg); process.exit(1); } };
  assert(typeof j.timestamp === 'string' && j.timestamp.length > 0, 'timestamp is a string');
  assert(typeof j.version === 'string', 'version is a string');
  assert(typeof j.system === 'object', 'system is an object');
  assert(typeof j.system.disk === 'object', 'system.disk is an object');
  assert(typeof j.system.memory === 'object', 'system.memory is an object');
  assert(typeof j.network === 'object', 'network is an object');
  assert(typeof j.network.online === 'boolean', 'network.online is boolean');
  assert(typeof j.device === 'object', 'device is an object');
  assert(j.device.id === 'json-test-001', 'device.id matches');
  assert(j.device.paired === true, 'device.paired is true');
  assert(typeof j.cache === 'object', 'cache is an object');
  assert(typeof j.cache.count === 'number', 'cache.count is number');
  assert(typeof j.checks === 'object', 'checks is an object');
  assert(typeof j.checks.total === 'number', 'checks.total is number');
  assert(typeof j.checks.pass === 'number', 'checks.pass is number');
  assert(typeof j.checks.fail === 'number', 'checks.fail is number');
  assert(Array.isArray(j.results), 'results is an array');
  assert(j.results.length > 0, 'results has entries');
  assert(typeof j.healthy === 'boolean', 'healthy is boolean');
  // Validate each result has required fields
  for (const r of j.results) {
    assert(typeof r.status === 'string', 'result.status is string');
    assert(typeof r.name === 'string', 'result.name is string');
    assert(typeof r.message === 'string', 'result.message is string');
    assert('detail' in r, 'result has detail');
  }
  console.log('  ✓ JSON structure validated (' + j.results.length + ' results)');
" && pass "JSON structure valid" || fail "JSON structure invalid"
cleanup_env

# ── Step 8: --verbose output ─────────────────────────────────────────────────

step 8 "Verbose output"
setup_env
cat > "$DATA_DIR/device.json" <<'DEVJSON'
{"deviceId":"verbose-test","paired":false}
DEVJSON
OUT="$(run_diag --verbose --quick 2>&1)"
echo "$OUT" | grep -q "Version:" && pass "system info in verbose" || fail "system info missing in verbose"
echo "$OUT" | grep -q "not installed" && pass "service details in verbose" || fail "service details missing in verbose"
cleanup_env

# ── Step 9: log error scanning ───────────────────────────────────────────────

step 9 "Log error scanning"
setup_env
mkdir -p "$LOG_DIR"
echo "2026-06-08 normal message" > "$LOG_DIR/heartbeat.log"
echo "2026-06-08 error something failed" >> "$LOG_DIR/heartbeat.log"
echo "2026-06-08 another error" >> "$LOG_DIR/heartbeat.log"
OUT="$(run_diag 2>&1)"
echo "$OUT" | grep -q "logs" && pass "logs section present" || fail "logs section missing"
echo "$OUT" | grep -qi "error" && pass "error count reported" || fail "errors not detected"
cleanup_env

# ── Step 10: exit code reflects failures ─────────────────────────────────────

step 10 "Exit code behavior"
setup_env
# Empty environment → should have failures → exit 1
RC=0
run_diag --quick >/dev/null 2>&1 || RC=$?
[[ "$RC" == "1" ]] && pass "exit 1 when failures present" || fail "expected exit 1, got $RC"
cleanup_env

# ── Step 11: all services check categories present ──────────────────────────

step 11 "All check categories present"
setup_env
OUT="$(run_diag --quick 2>&1)"
# Check that all expected check names appear
for name in disk_space cpu_temp network local_ui device_id cache offline_mode kiosk_process; do
  echo "$OUT" | grep -q "$name" && pass "check '$name' present" || fail "check '$name' missing"
done
cleanup_env

# ── Step 12: security — no secrets in output ─────────────────────────────────

step 12 "Security — no secrets in output"
setup_env
cat > "$DATA_DIR/device.json" <<'DEVJSON'
{"deviceId":"sec-test","paired":true,"deviceApiKey":"super-secret-key-12345"}
DEVJSON
OUT="$(run_diag --quick 2>&1)"
echo "$OUT" | grep -q "super-secret-key-12345" && fail "API key leaked in text output" || pass "no API key leak in text output"
JSON_OUT="$(run_diag --json --quick 2>&1)"
echo "$JSON_OUT" | grep -q "super-secret-key-12345" && fail "API key leaked in JSON output" || pass "no API key leak in JSON output"
cleanup_env

# ── summary ──────────────────────────────────────────────────────────────────

echo ""
echo "==========================================="
echo "diagnostics-check: $PASS pass, $FAIL fail, $SKIP skip"
echo "==========================================="

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
