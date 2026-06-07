#!/usr/bin/env bash
set -euo pipefail

# Night mode timer enforcement gate
# Proves:
# 1. The night-mode-apply.sh script syntax and dry-run mode
# 2. The systemd service and timer files exist with correct paths
# 3. The timer fires every minute (OnCalendar=*:0/1)
# 4. The install-systemd-units.sh enables and starts the night-mode timer
# 5. The apply endpoint returns displayOn state after enforcement
# 6. The night-mode service has security hardening directives

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "night-mode-timer-check failed: $*" >&2
  if [[ -f "$TMP_DIR/server.log" ]]; then
    echo "--- local-ui log (last 40 lines) ---" >&2
    tail -40 "$TMP_DIR/server.log" >&2
  fi
  exit 1
}

pick_port() {
  node - <<'NODE'
const net = require("net");
const server = net.createServer();
server.listen(0, "127.0.0.1", () => {
  console.log(server.address().port);
  server.close();
});
NODE
}

mkdir -p "$TMP_DIR/data" "$TMP_DIR/log" "$TMP_DIR/cache"

echo "=== Step 1: night-mode-apply.sh syntax ==="
bash -n "$ROOT_DIR/scripts/night-mode-apply.sh" || fail "night-mode-apply.sh has syntax errors"
echo "step 1 passed"

echo "=== Step 2: night-mode-apply.sh dry-run ==="
AUTOPOIESIS_NIGHT_MODE_DRY_RUN=1 \
AUTOPOIESIS_LOCAL_URL="http://127.0.0.1:3030" \
"$ROOT_DIR/scripts/night-mode-apply.sh" 2>&1 | grep -q "dry-run: would POST" \
  || fail "dry-run mode should print the URL it would POST"
echo "step 2 passed"

echo "=== Step 3: systemd service file exists and has correct ExecStart ==="
SERVICE_FILE="$ROOT_DIR/services/autopoiesis-night-mode.service"
[[ -f "$SERVICE_FILE" ]] || fail "service file not found: $SERVICE_FILE"
grep -q "ExecStart=/opt/autopoiesis-os/app/scripts/night-mode-apply.sh" "$SERVICE_FILE" \
  || fail "service ExecStart should point to night-mode-apply.sh"
grep -q "After=autopoiesis-setup.service" "$SERVICE_FILE" \
  || fail "service should depend on autopoiesis-setup.service"
echo "step 3 passed"

echo "=== Step 4: systemd timer file exists and fires every minute ==="
TIMER_FILE="$ROOT_DIR/timers/autopoiesis-night-mode.timer"
[[ -f "$TIMER_FILE" ]] || fail "timer file not found: $TIMER_FILE"
grep -q 'OnCalendar=\*:0/1' "$TIMER_FILE" \
  || fail "timer should use OnCalendar=*:0/1 for every-minute firing"
grep -q "Persistent=true" "$TIMER_FILE" \
  || fail "timer should be persistent to catch up after sleep"
echo "step 4 passed"

echo "=== Step 5: service has frame-user security hardening ==="
grep -q "ProtectSystem=strict" "$SERVICE_FILE" || fail "missing ProtectSystem=strict"
grep -q "NoNewPrivileges=true" "$SERVICE_FILE" || fail "missing NoNewPrivileges=true"
grep -q "MemoryDenyWriteExecute=true" "$SERVICE_FILE" || fail "missing MemoryDenyWriteExecute=true"
grep -q "ReadWritePaths=/var/log/autopoiesis-os" "$SERVICE_FILE" || fail "missing ReadWritePaths for log dir"
grep -q "User=frame" "$SERVICE_FILE" || fail "missing User=frame"
echo "step 5 passed"

echo "=== Step 6: install-systemd-units.sh enables and starts night-mode timer ==="
grep -q "autopoiesis-night-mode.timer" "$ROOT_DIR/scripts/install-systemd-units.sh" \
  || fail "install-systemd-units.sh should reference autopoiesis-night-mode.timer in enable"
# Check both enable and start
ENABLE_COUNT="$(grep -c "autopoiesis-night-mode.timer" "$ROOT_DIR/scripts/install-systemd-units.sh")"
[[ "$ENABLE_COUNT" -ge 2 ]] || fail "install-systemd-units.sh should reference night-mode timer in both enable and start blocks"
echo "step 6 passed"

echo "=== Step 7: apply endpoint returns displayOn state ==="

PORT="${AUTOPOIESIS_NIGHT_MODE_TIMER_CHECK_PORT:-$(pick_port)}"
BASE_URL="http://127.0.0.1:${PORT}"

# Seed device state — paired, night mode enabled
node - "$TMP_DIR/data" <<'NODE'
const fs = require("fs");
const dataDir = process.argv[2];

fs.writeFileSync(dataDir + "/device.json", JSON.stringify({
  deviceId: "rpi-night-mode-timer-check",
  deviceName: "Night Mode Timer Check",
  ownerUserId: "user-nm-timer-owner",
  paired: true,
  firstRunComplete: true,
  onboardingComplete: true,
  remoteEnabled: true,
  apiBaseUrl: "http://127.0.0.1:1/api",
  framesUrl: "http://127.0.0.1:1/display",
  deviceApiKey: "nm-timer-check-secret"
}, null, 2) + "\n");

fs.writeFileSync(dataDir + "/preferences.json", JSON.stringify({
  displayMode: "local-feed",
  streamProfile: "living-stream",
  imageDuration: 60,
  volume: 50,
  soundEnabled: false,
  nightMode: true,
  nightModeStart: "22:00",
  nightModeEnd: "08:00",
  updatedAt: "2026-06-08T00:00:00.000Z"
}, null, 2) + "\n");

fs.writeFileSync(dataDir + "/state.json", JSON.stringify({ currentMode: "online" }, null, 2) + "\n");

console.log("seeded");
NODE

# Start local UI
AUTOPOIESIS_PORT="$PORT" \
AUTOPOIESIS_DATA_DIR="$TMP_DIR/data" \
AUTOPOIESIS_CACHE_DIR="$TMP_DIR/cache" \
AUTOPOIESIS_LOG_DIR="$TMP_DIR/log" \
AUTOPOIESIS_VCGENCMD_BIN="/bin/false" \
node "$ROOT_DIR/local-ui/server.js" >"$TMP_DIR/server.log" 2>&1 &
SERVER_PID=$!

for i in $(seq 1 30); do
  if curl -fsS "$BASE_URL/local/health" >/dev/null 2>&1; then break; fi
  sleep 0.2
done
curl -fsS "$BASE_URL/local/health" >/dev/null || fail "local UI did not start"

# Call apply endpoint and verify response includes displayOn
APPLY_RESPONSE="$(curl -fsS -X POST "$BASE_URL/local/night-mode/apply")"

node - "$APPLY_RESPONSE" <<'NODE'
const resp = JSON.parse(process.argv[2]);
function fail(msg) { throw new Error(msg); }

if (resp.ok !== true) fail("apply should return ok=true, got " + resp.ok);
if (!resp.nightMode) fail("apply should return nightMode object");
if (typeof resp.nightMode.enabled !== "boolean") fail("nightMode.enabled should be boolean");
if (typeof resp.nightMode.active !== "boolean") fail("nightMode.active should be boolean");
if (typeof resp.nightMode.displayOn !== "boolean") fail("nightMode.displayOn should be boolean");

console.log("apply response: enabled=" + resp.nightMode.enabled +
  " active=" + resp.nightMode.active +
  " displayOn=" + resp.nightMode.displayOn);
console.log("step 7 passed: apply endpoint returns displayOn state");
NODE

echo "=== Step 8: night-mode-apply.sh logs apply result ==="
# Run the apply script against the running local UI
AUTOPOIESIS_LOCAL_URL="$BASE_URL" \
AUTOPOIESIS_LOG_DIR="$TMP_DIR/log" \
"$ROOT_DIR/scripts/night-mode-apply.sh" 2>&1 || true

grep -q "night-mode-apply: applied:" "$TMP_DIR/log/heartbeat.log" \
  || fail "night-mode-apply.sh should log the apply result to heartbeat.log"
echo "step 8 passed"

echo "=== Step 9: night-mode-apply.sh handles unreachable local UI gracefully ==="
# Stop the server
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

# Clear previous log
: > "$TMP_DIR/log/heartbeat.log"

AUTOPOIESIS_LOCAL_URL="http://127.0.0.1:1" \
AUTOPOIESIS_LOG_DIR="$TMP_DIR/log" \
AUTOPOIESIS_NIGHT_MODE_CURL_TIMEOUT=2 \
"$ROOT_DIR/scripts/night-mode-apply.sh" 2>&1 || true

grep -q "night-mode-apply: apply endpoint unreachable" "$TMP_DIR/log/heartbeat.log" \
  || fail "should log unreachable when local UI is down"
echo "step 9 passed"

echo "=== Step 10: apply endpoint without night mode (disabled) ==="
# Restart with night mode disabled
node - "$TMP_DIR/data" <<'NODE'
const fs = require("fs");
const dataDir = process.argv[2];
const prefs = JSON.parse(fs.readFileSync(dataDir + "/preferences.json", "utf8"));
prefs.nightMode = false;
delete prefs._nightModeDisplayOn;
fs.writeFileSync(dataDir + "/preferences.json", JSON.stringify(prefs, null, 2) + "\n");
console.log("night mode disabled");
NODE

PORT="${AUTOPOIESIS_NIGHT_MODE_TIMER_CHECK_PORT:-$(pick_port)}"
BASE_URL="http://127.0.0.1:${PORT}"

AUTOPOIESIS_PORT="$PORT" \
AUTOPOIESIS_DATA_DIR="$TMP_DIR/data" \
AUTOPOIESIS_CACHE_DIR="$TMP_DIR/cache" \
AUTOPOIESIS_LOG_DIR="$TMP_DIR/log" \
AUTOPOIESIS_VCGENCMD_BIN="/bin/false" \
node "$ROOT_DIR/local-ui/server.js" >"$TMP_DIR/server2.log" 2>&1 &
SERVER_PID=$!

for i in $(seq 1 30); do
  if curl -fsS "$BASE_URL/local/health" >/dev/null 2>&1; then break; fi
  sleep 0.2
done
curl -fsS "$BASE_URL/local/health" >/dev/null || fail "local UI did not restart"

APPLY_RESPONSE2="$(curl -fsS -X POST "$BASE_URL/local/night-mode/apply")"

node - "$APPLY_RESPONSE2" <<'NODE'
const resp = JSON.parse(process.argv[2]);
function fail(msg) { throw new Error(msg); }

if (resp.ok !== true) fail("apply should return ok=true even when disabled");
if (resp.nightMode.enabled !== false) fail("nightMode.enabled should be false when disabled");
if (resp.nightMode.displayOn !== true) fail("displayOn should default to true when night mode is disabled");

console.log("step 10 passed: apply endpoint returns displayOn=true when night mode is disabled");
NODE

echo ""
echo "night-mode-timer-check passed: all 10 steps"
echo "  1. Script syntax valid"
echo "  2. Dry-run mode works"
echo "  3. Service file has correct ExecStart and dependency"
echo "  4. Timer fires every minute with Persistent=true"
echo "  5. Service has frame-user security hardening"
echo "  6. Installer enables and starts the timer"
echo "  7. Apply endpoint returns displayOn state"
echo "  8. Apply script logs result to heartbeat.log"
echo "  9. Apply script handles unreachable local UI gracefully"
echo " 10. Apply endpoint returns displayOn=true when night mode is disabled"
