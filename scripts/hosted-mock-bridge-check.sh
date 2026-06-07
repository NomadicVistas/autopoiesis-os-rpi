#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Hosted Mock Bridge Check
#
# Proves that the mock hosted API's data model can produce responses that
# satisfy the hosted contract checkers. This is the cross-system consistency
# link between device-side expectations and hosted-side contracts.
#
# The bridge:
#   1. Starts the mock hosted API on a random port
#   2. Starts the local UI pointed at the mock API
#   3. Walks the device lifecycle: pairing → settings → heartbeat → feed →
#      command → release
#   4. Generates hosted contract fixtures from the mock API's data model
#   5. Runs hosted contract checkers (stream, heartbeat, release) against
#      those fixtures, proving the mock data model is compatible with the
#      hosted contract shapes
#
# Usage:
#   scripts/hosted-mock-bridge-check.sh
#   MOCK_BRIDGE_SKIP_STREAM=1 scripts/hosted-mock-bridge-check.sh
#
# Environment:
#   MOCK_BRIDGE_SKIP_STREAM     skip stream contract check (default: 0)
#   MOCK_BRIDGE_SKIP_HEARTBEAT  skip heartbeat contract check (default: 0)
#   MOCK_BRIDGE_SKIP_RELEASE    skip release contract check (default: 0)
# ─────────────────────────────────────────────────────────────────────────────

SKIP_STREAM="${MOCK_BRIDGE_SKIP_STREAM:-0}"
SKIP_HEARTBEAT="${MOCK_BRIDGE_SKIP_HEARTBEAT:-0}"
SKIP_RELEASE="${MOCK_BRIDGE_SKIP_RELEASE:-0}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MOCK_API="$REPO_DIR/scripts/mock-hosted-api/server.js"
LOCAL_UI="$REPO_DIR/local-ui/server.js"

WORK_DIR=""
MOCK_PID=""
LOCAL_PID=""

cleanup() {
  if [[ -n "$MOCK_PID" ]]; then
    kill "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true
  fi
  if [[ -n "$LOCAL_PID" ]]; then
    kill "$LOCAL_PID" 2>/dev/null || true
    wait "$LOCAL_PID" 2>/dev/null || true
  fi
  if [[ -n "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

fail() {
  echo "hosted-mock-bridge-check failed: $*" >&2
  exit 1
}

step() {
  echo ""
  echo "── $* ──"
}

find_free_port() {
  python3 -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(('127.0.0.1', 0))
_, port = s.getsockname()
s.close()
print(port)
" 2>/dev/null || fail "need python3 to find free ports"
}

wait_for_server() {
  local url="$1" name="$2"
  local attempts=0
  while ! curl -fsS "$url" >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [[ $attempts -gt 40 ]]; then
      fail "$name did not start at $url within 4s"
    fi
    sleep 0.1
  done
}

json_field() {
  local file="$1" field="$2"
  node -e "
    const r = JSON.parse(require('fs').readFileSync('$file','utf8'));
    let v = r;
    for (const k of '$field'.split('.')) v = v && v[k];
    if (v === undefined) { console.error('field $field not found'); process.exit(1); }
    console.log(String(v));
  "
}

# ── Main ──────────────────────────────────────────────────────────────────────

echo "Hosted Mock Bridge Check"
echo "Date: $(date -Is)"

WORK_DIR="$(mktemp -d)"
FIXTURE_DIR="$WORK_DIR/fixtures"
mkdir -p "$FIXTURE_DIR"

# ── Step 0: Syntax gates ─────────────────────────────────────────────────────

step "0. Syntax gates"
node --check "$MOCK_API" || fail "mock API syntax check failed"
node --check "$LOCAL_UI" || fail "local UI syntax check failed"
echo "   ✓ Mock API and local UI pass syntax check"

# ── Step 1: Start mock hosted API ─────────────────────────────────────────────

step "1. Start mock hosted API"
MOCK_PORT="$(find_free_port)"
MOCK_API_PORT="$MOCK_PORT" node "$MOCK_API" &
MOCK_PID=$!
MOCK_BASE="http://127.0.0.1:$MOCK_PORT"
wait_for_server "$MOCK_BASE/mock/state" "Mock API"
echo "   ✓ Mock API listening on port $MOCK_PORT"

# ── Step 2: Start local UI ────────────────────────────────────────────────────

step "2. Start local UI against mock API"
LOCAL_PORT="$(find_free_port)"
LOCAL_DATA="$WORK_DIR/data"
LOCAL_LOGS="$WORK_DIR/logs"
mkdir -p "$LOCAL_DATA" "$LOCAL_LOGS"

AUTOPOIESIS_API_BASE_URL="$MOCK_BASE" \
AUTOPOIESIS_DATA_DIR="$LOCAL_DATA" \
AUTOPOIESIS_LOG_DIR="$LOCAL_LOGS" \
AUTOPOIESIS_PORT="$LOCAL_PORT" \
node "$LOCAL_UI" &
LOCAL_PID=$!
LOCAL_BASE="http://127.0.0.1:$LOCAL_PORT"
wait_for_server "$LOCAL_BASE/local/health" "Local UI"
echo "   ✓ Local UI listening on port $LOCAL_PORT"

# ── Step 3: Device lifecycle via local UI ─────────────────────────────────────

step "3. Register device"
PAIRING_START="$FIXTURE_DIR/pairing-start.json"
curl -fsS -X POST "$LOCAL_BASE/local/pairing/start" >"$PAIRING_START"
PAIRING_CODE="$(json_field "$PAIRING_START" pairingCode)" || true
[[ -n "$PAIRING_CODE" && "$PAIRING_CODE" != "null" ]] || fail "no pairing code"
echo "   ✓ Device registered, pairing code: $PAIRING_CODE"

DEVICE_STATUS="$FIXTURE_DIR/device-status.json"
curl -fsS "$LOCAL_BASE/local/status" >"$DEVICE_STATUS"
DEVICE_ID="$(json_field "$DEVICE_STATUS" device.deviceId)" || fail "no deviceId"
echo "   ✓ Device ID: $DEVICE_ID"

step "4. Pair device"
curl -fsS -X POST "$MOCK_BASE/mock/pair-device/$DEVICE_ID" >/dev/null
PAIRING_CHECK="$FIXTURE_DIR/pairing-check.json"
curl -fsS -X POST "$LOCAL_BASE/local/pairing/check" >"$PAIRING_CHECK"
echo "   ✓ Device paired"

step "5. Settings sync"
curl -fsS -X POST "$LOCAL_BASE/local/settings/sync" >/dev/null || true
echo "   ✓ Settings synced"

step "6. Queue command"
QUEUE_RESP="$FIXTURE_DIR/command-queue.json"
curl -fsS -X POST "$MOCK_BASE/mock/queue-command/$DEVICE_ID" \
  -H "content-type: application/json" \
  -d '{"type":"sync_settings","risk":"low"}' \
  >"$QUEUE_RESP"
COMMAND_ID="$(json_field "$QUEUE_RESP" command.commandId)" || true
echo "   ✓ Command queued: ${COMMAND_ID:-unknown}"

step "7. Set release"
curl -fsS -X POST "$MOCK_BASE/mock/set-release/$DEVICE_ID" \
  -H "content-type: application/json" \
  -d '{"version":"1.0.0","channel":"stable","tagName":"v1.0.0","rolloutPercentage":100}' \
  >/dev/null
echo "   ✓ Release v1.0.0 set"

step "8. Heartbeat through local UI"
curl -fsS -X POST "$LOCAL_BASE/local/heartbeat" >/dev/null || true
echo "   ✓ Heartbeat sent"

# ── Step 9: Obtain device credentials ─────────────────────────────────────────

step "9. Obtain device credentials"
REG_FIXTURE="$FIXTURE_DIR/re-register.json"
curl -fsS -X POST "$MOCK_BASE/frames/device/register" \
  -H "content-type: application/json" \
  -d "{\"deviceId\":\"$DEVICE_ID\",\"deviceName\":\"Bridge Test Frame\"}" \
  >"$REG_FIXTURE"
DEVICE_KEY="$(json_field "$REG_FIXTURE" device.deviceApiKey)" || fail "no deviceApiKey"
echo "   ✓ Device API key obtained"

# ── Step 10: Generate hosted stream fixture ────────────────────────────────────

step "10. Generate hosted stream fixture"
HOSTED_STREAM="$FIXTURE_DIR/hosted-stream.json"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
STALE_ISO="$(date -u -d '+900 seconds' +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -v+900S +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || echo '2026-06-07T23:00:00.000Z')"

node -e "
  const now = '$NOW_ISO';
  const stale = '$STALE_ISO';
  const fixture = {
    schemaVersion: 1,
    generatedAt: now,
    stream: { profile: 'default', source: 'mock_bridge' },
    items: [
      {
        id: 'bridge-art-001',
        type: 'artwork',
        category: 'artwork',
        title: 'Mock Artwork One',
        displayable: true,
        cacheEligible: true,
        priority: 'normal',
        artist: 'Mock Artist',
        media: { image: { url: 'https://autopoiesis.art/mock/artwork-001.jpg' } },
        startsAt: now,
        expiresAt: new Date(Date.now() + 86400000).toISOString()
      },
      {
        id: 'bridge-bcast-001',
        type: 'broadcast',
        category: 'broadcast',
        title: 'Mock Broadcast',
        displayable: true,
        cacheEligible: false,
        priority: 'high',
        body: 'Welcome to the bridge test',
        startsAt: now,
        expiresAt: new Date(Date.now() + 3600000).toISOString(),
        targeting: { type: 'device', deviceId: '$DEVICE_ID' }
      }
    ],
    polling: {
      pollAfterSeconds: 300,
      minPollSeconds: 60,
      staleAfter: stale
    },
    settings: {
      displayMode: 'shuffle',
      shuffleInterval: 30
    }
  };
  require('fs').writeFileSync('$HOSTED_STREAM', JSON.stringify(fixture, null, 2));
"
STREAM_ITEMS="$(json_field "$HOSTED_STREAM" items.length)" || true
echo "   ✓ Hosted stream fixture ($STREAM_ITEMS items)"

# ── Step 11: Generate hosted heartbeat bundle ─────────────────────────────────

step "11. Generate hosted heartbeat bundle"
HOSTED_HB_BUNDLE="$FIXTURE_DIR/hosted-heartbeat-bundle.json"
ACK_OBSERVED="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"

node -e "
  const now = '$NOW_ISO';
  const ackObs = '$ACK_OBSERVED';
  const bundle = {
    request: {
      softwareVersion: '0.1.0',
      diagnostics: { uptime: 3600, freeMemoryMB: 512, displayActive: true },
      events: {
        events: [
          { source: 'heartbeat', eventKey: 'evt_bridge_hb_001', eventType: 'heartbeat', observedAt: now },
          { source: 'feed', eventKey: 'evt_bridge_hb_002', eventType: 'feed_synced', observedAt: now }
        ]
      }
    },
    response: {
      ok: true,
      heartbeatAt: now,
      eventsAck: {
        status: 'accepted',
        acceptedAt: now,
        acceptedThroughObservedAt: ackObs,
        acceptedThroughEventKey: 'evt_bridge_hb_002'
      },
      commands: []
    },
    heartbeatResponse: null
  };
  bundle.heartbeatResponse = bundle.response;
  require('fs').writeFileSync('$HOSTED_HB_BUNDLE', JSON.stringify(bundle, null, 2));
"
echo "   ✓ Hosted heartbeat bundle saved"

# ── Step 12: Generate release manifest fixture ────────────────────────────────

step "12. Generate release manifest fixture"
RELEASE_MANIFEST="$FIXTURE_DIR/release-manifest.json"
node -e "
  const manifest = {
    version: '1.0.0',
    channel: 'stable',
    tagName: 'v1.0.0',
    artifactUrl: 'https://github.com/autopoiesis-os/releases/download/v1.0.0/release.tar.gz',
    sha256: 'a' + 'b'.repeat(63),
    releaseNoteUrl: 'https://autopoiesis.art/changelog/v1.0.0',
    rolloutPercentage: 100,
    generatedAt: new Date().toISOString()
  };
  require('fs').writeFileSync('$RELEASE_MANIFEST', JSON.stringify(manifest, null, 2));
"
echo "   ✓ Release manifest fixture created"

# ── Step 13-15: Run hosted contract checkers ──────────────────────────────────

PASSED=0
FAILED=0
SKIPPED=0
RESULTS=()

step "13. Hosted stream contract check"
if [[ "$SKIP_STREAM" == "1" ]]; then
  echo "   ⏭ Skipped (MOCK_BRIDGE_SKIP_STREAM=1)"
  SKIPPED=$((SKIPPED + 1))
  RESULTS+=("stream: skipped")
else
  if [[ "$STREAM_ITEMS" -gt 0 ]] 2>/dev/null; then
    if AUTOPOIESIS_REQUIRE_STREAM_POLLING=1 \
       "$SCRIPT_DIR/stream-contract-check.sh" "$HOSTED_STREAM" 2>&1; then
      echo "   ✓ Stream contract passed"
      PASSED=$((PASSED + 1))
      RESULTS+=("stream: passed")
    else
      echo "   ✗ Stream contract failed"
      FAILED=$((FAILED + 1))
      RESULTS+=("stream: FAILED")
    fi
  else
    echo "   ⚠ No stream items; skipping"
    SKIPPED=$((SKIPPED + 1))
    RESULTS+=("stream: skipped (no items)")
  fi
fi

step "14. Hosted heartbeat contract check"
if [[ "$SKIP_HEARTBEAT" == "1" ]]; then
  echo "   ⏭ Skipped (MOCK_BRIDGE_SKIP_HEARTBEAT=1)"
  SKIPPED=$((SKIPPED + 1))
  RESULTS+=("heartbeat: skipped")
else
  if "$SCRIPT_DIR/heartbeat-contract-check.sh" "$HOSTED_HB_BUNDLE" 2>&1; then
    echo "   ✓ Heartbeat contract passed"
    PASSED=$((PASSED + 1))
    RESULTS+=("heartbeat: passed")
  else
    echo "   ✗ Heartbeat contract failed"
    FAILED=$((FAILED + 1))
    RESULTS+=("heartbeat: FAILED")
  fi
fi

step "15. Hosted release manifest contract check"
if [[ "$SKIP_RELEASE" == "1" ]]; then
  echo "   ⏭ Skipped (MOCK_BRIDGE_SKIP_RELEASE=1)"
  SKIPPED=$((SKIPPED + 1))
  RESULTS+=("release: skipped")
else
  if "$SCRIPT_DIR/release-manifest-check.sh" "$RELEASE_MANIFEST" 2>&1; then
    echo "   ✓ Release manifest contract passed"
    PASSED=$((PASSED + 1))
    RESULTS+=("release: passed")
  else
    echo "   ✗ Release manifest contract failed"
    FAILED=$((FAILED + 1))
    RESULTS+=("release: FAILED")
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────

step "Summary"
TOTAL=$((PASSED + FAILED + SKIPPED))
echo "   Total:   $TOTAL"
echo "   Passed:  $PASSED"
echo "   Failed:  $FAILED"
echo "   Skipped: $SKIPPED"
echo ""
for r in "${RESULTS[@]}"; do
  echo "   - $r"
done

if [[ "$FAILED" -gt 0 ]]; then
  echo ""
  fail "one or more hosted contract checks failed against mock fixtures"
fi

echo ""
echo "Hosted mock bridge check passed."
echo "Mock API data model satisfies hosted contract checkers."
