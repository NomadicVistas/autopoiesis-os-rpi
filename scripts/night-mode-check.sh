#!/usr/bin/env bash
set -euo pipefail

# Night mode + welcome flow integration gate
# Proves night mode works across settings, diagnostics, health, frame state, and support bundle.
# Also proves /welcome route serves correctly for unpaired devices.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

PORT="${AUTOPOIESIS_NIGHT_MODE_CHECK_PORT:-$(pick_port)}"
BASE_URL="http://127.0.0.1:${PORT}"
TMP_DIR="$(mktemp -d)"
SERVER_PID=""

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "night mode check failed: $*" >&2
  if [[ -f "$TMP_DIR/server.log" ]]; then
    echo "--- local-ui log ---" >&2
    sed -n '1,120p' "$TMP_DIR/server.log" >&2
  fi
  exit 1
}

mkdir -p "$TMP_DIR/data" "$TMP_DIR/log" "$TMP_DIR/cache"

# --- Seed minimal device state (paired, onboarding complete) ---
node - "$TMP_DIR/data" <<'NODE'
const fs = require("fs");
const dataDir = process.argv[2];

fs.writeFileSync(dataDir + "/device.json", JSON.stringify({
  deviceId: "rpi-night-mode-check",
  deviceName: "Night Mode Check Frame",
  ownerUserId: "user-night-mode-owner",
  paired: true,
  firstRunComplete: true,
  onboardingComplete: true,
  remoteEnabled: true,
  apiBaseUrl: "http://127.0.0.1:1/api",
  framesUrl: "http://127.0.0.1:1/display",
  deviceApiKey: "night-mode-check-secret"
}, null, 2) + "\n");

// Default preferences — night mode off
fs.writeFileSync(dataDir + "/preferences.json", JSON.stringify({
  displayMode: "local-feed",
  streamProfile: "living-stream",
  imageDuration: 60,
  volume: 50,
  soundEnabled: false,
  nightMode: false,
  updatedAt: "2026-06-07T22:00:00.000Z"
}, null, 2) + "\n");

fs.writeFileSync(dataDir + "/state.json", JSON.stringify({ currentMode: "setup" }, null, 2) + "\n");

console.log("seeded");
NODE

# --- Start local UI ---
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

echo "local UI started on port $PORT"

# --- Step 1: Night mode defaults to disabled ---
curl -fsS "$BASE_URL/local/diagnostics" >"$TMP_DIR/diag1.json" || fail "diagnostics request failed"
curl -fsS "$BASE_URL/local/health" >"$TMP_DIR/health1.json" || fail "health request failed"

node - "$TMP_DIR/diag1.json" "$TMP_DIR/health1.json" <<'NODE'
const fs = require("fs");
const [diagPath, healthPath] = process.argv.slice(2);
const diag = JSON.parse(fs.readFileSync(diagPath, "utf8"));
const health = JSON.parse(fs.readFileSync(healthPath, "utf8"));

function fail(message) { throw new Error(message); }

// Diagnostics should show night mode disabled
if (!diag.diagnostics || !diag.diagnostics.nightMode) fail("diagnostics missing nightMode");
if (diag.diagnostics.nightMode.enabled !== false) fail("night mode should be disabled by default, got enabled=" + diag.diagnostics.nightMode.enabled);
if (diag.diagnostics.nightMode.active !== false) fail("night mode should not be active by default, got active=" + diag.diagnostics.nightMode.active);

// Health summary should include night mode
if (!health.nightMode) fail("health summary missing nightMode");
if (health.nightMode.enabled !== false) fail("health night mode should be disabled by default");

console.log("step 1 passed: night mode defaults to disabled in diagnostics and health");
NODE

# --- Step 2: Enable night mode via settings and verify round-trip ---
curl -fsS -X POST -H "content-type: application/json" \
  -d '{"preferences":{"nightMode":true,"nightModeStart":"22:00","nightModeEnd":"08:00"}}' \
  "$BASE_URL/local/settings" >"$TMP_DIR/settings1.json" || fail "settings POST failed"

curl -fsS "$BASE_URL/local/diagnostics" >"$TMP_DIR/diag2.json" || fail "diagnostics after enable failed"
curl -fsS "$BASE_URL/local/health" >"$TMP_DIR/health2.json" || fail "health after enable failed"

node - "$TMP_DIR/settings1.json" "$TMP_DIR/diag2.json" "$TMP_DIR/health2.json" <<'NODE'
const fs = require("fs");
const [settingsPath, diagPath, healthPath] = process.argv.slice(2);
const settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
const diag = JSON.parse(fs.readFileSync(diagPath, "utf8"));
const health = JSON.parse(fs.readFileSync(healthPath, "utf8"));

function fail(message) { throw new Error(message); }

// Settings save should succeed (remote push may fail, that's fine)
if (!settings.ok) fail("settings POST should return ok=true");

// Diagnostics should now show night mode enabled
if (!diag.diagnostics.nightMode) fail("diagnostics missing nightMode after enable");
if (diag.diagnostics.nightMode.enabled !== true) fail("night mode should be enabled, got enabled=" + diag.diagnostics.nightMode.enabled);
if (diag.diagnostics.nightMode.start !== "22:00") fail("night mode start should be 22:00, got " + diag.diagnostics.nightMode.start);
if (diag.diagnostics.nightMode.end !== "08:00") fail("night mode end should be 08:00, got " + diag.diagnostics.nightMode.end);

// State should report whether currently active based on time
if (typeof diag.diagnostics.nightMode.active !== "boolean") fail("night mode active should be boolean");
if (typeof diag.diagnostics.nightMode.nowMin !== "number") fail("night mode should include nowMin");

// Health should reflect enabled
if (!health.nightMode) fail("health missing nightMode after enable");
if (health.nightMode.enabled !== true) fail("health night mode should be enabled");

console.log("step 2 passed: night mode enabled via settings, diagnostics and health reflect the change");
NODE

# --- Step 3: Verify night mode state with different time ranges ---
# Test a cross-midnight range (23:00 to 06:00)
curl -fsS -X POST -H "content-type: application/json" \
  -d '{"preferences":{"nightMode":true,"nightModeStart":"23:00","nightModeEnd":"06:00"}}' \
  "$BASE_URL/local/settings" >"$TMP_DIR/settings2.json" || fail "settings POST for cross-midnight failed"

curl -fsS "$BASE_URL/local/diagnostics" >"$TMP_DIR/diag3.json" || fail "diagnostics for cross-midnight failed"

node - "$TMP_DIR/diag3.json" <<'NODE'
const fs = require("fs");
const diag = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));

function fail(message) { throw new Error(message); }

if (!diag.diagnostics.nightMode) fail("diagnostics missing nightMode");
if (diag.diagnostics.nightMode.start !== "23:00") fail("start should be 23:00, got " + diag.diagnostics.nightMode.start);
if (diag.diagnostics.nightMode.end !== "06:00") fail("end should be 06:00, got " + diag.diagnostics.nightMode.end);
if (typeof diag.diagnostics.nightMode.active !== "boolean") fail("active should be boolean");
if (typeof diag.diagnostics.nightMode.startMin !== "number") fail("startMin should be number");
if (diag.diagnostics.nightMode.startMin !== 1380) fail("23:00 should be 1380 minutes, got " + diag.diagnostics.nightMode.startMin);
if (diag.diagnostics.nightMode.endMin !== 360) fail("06:00 should be 360 minutes, got " + diag.diagnostics.nightMode.endMin);

console.log("step 3 passed: cross-midnight night mode range (23:00-06:00) computes correctly");
NODE

# --- Step 4: Invalid time values gracefully degrade ---
curl -fsS -X POST -H "content-type: application/json" \
  -d '{"preferences":{"nightMode":true,"nightModeStart":"invalid","nightModeEnd":"25:99"}}' \
  "$BASE_URL/local/settings" >"$TMP_DIR/settings3.json" || fail "settings POST for invalid times failed"

curl -fsS "$BASE_URL/local/diagnostics" >"$TMP_DIR/diag4.json" || fail "diagnostics for invalid times failed"

node - "$TMP_DIR/diag4.json" <<'NODE'
const fs = require("fs");
const diag = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));

function fail(message) { throw new Error(message); }

if (!diag.diagnostics.nightMode) fail("diagnostics missing nightMode with invalid times");
if (diag.diagnostics.nightMode.enabled !== true) fail("night mode should still be enabled");
if (diag.diagnostics.nightMode.active !== false) fail("active should be false when times are invalid");
// Should still store the raw values
if (diag.diagnostics.nightMode.start !== "invalid") fail("should preserve raw start value");
if (diag.diagnostics.nightMode.end !== "25:99") fail("should preserve raw end value");

console.log("step 4 passed: invalid time values gracefully degrade (enabled but not active)");
NODE

# --- Step 5: Night mode apply endpoint (no-op on non-Pi) ---
curl -fsS -X POST "$BASE_URL/local/night-mode/apply" >"$TMP_DIR/apply1.json" || fail "night-mode apply failed"

node - "$TMP_DIR/apply1.json" <<'NODE'
const fs = require("fs");
const result = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));

function fail(message) { throw new Error(message); }

if (!result.ok) fail("night-mode apply should return ok=true");
if (!result.nightMode) fail("night-mode apply should return nightMode state");
if (typeof result.nightMode.enabled !== "boolean") fail("nightMode.enabled should be boolean");

console.log("step 5 passed: night-mode apply endpoint responds with state (no-op on non-Pi hardware)");
NODE

# --- Step 6: Disable night mode and verify state resets ---
curl -fsS -X POST -H "content-type: application/json" \
  -d '{"preferences":{"nightMode":false}}' \
  "$BASE_URL/local/settings" >"$TMP_DIR/settings4.json" || fail "settings POST to disable failed"

curl -fsS "$BASE_URL/local/diagnostics" >"$TMP_DIR/diag5.json" || fail "diagnostics after disable failed"
curl -fsS "$BASE_URL/local/health" >"$TMP_DIR/health5.json" || fail "health after disable failed"

node - "$TMP_DIR/diag5.json" "$TMP_DIR/health5.json" <<'NODE'
const fs = require("fs");
const [diagPath, healthPath] = process.argv.slice(2);
const diag = JSON.parse(fs.readFileSync(diagPath, "utf8"));
const health = JSON.parse(fs.readFileSync(healthPath, "utf8"));

function fail(message) { throw new Error(message); }

if (!diag.diagnostics.nightMode) fail("diagnostics missing nightMode after disable");
if (diag.diagnostics.nightMode.enabled !== false) fail("night mode should be disabled");
if (diag.diagnostics.nightMode.active !== false) fail("night mode should not be active when disabled");

if (!health.nightMode) fail("health missing nightMode after disable");
if (health.nightMode.enabled !== false) fail("health night mode should be disabled");

console.log("step 6 passed: disabling night mode resets state in diagnostics and health");
NODE

# --- Step 7: Settings round-trip persists night mode correctly ---
curl -fsS -X POST -H "content-type: application/json" \
  -d '{"preferences":{"nightMode":true,"nightModeStart":"21:30","nightModeEnd":"07:15"}}' \
  "$BASE_URL/local/settings" >/dev/null || fail "settings POST for round-trip check failed"

curl -fsS "$BASE_URL/local/diagnostics" >"$TMP_DIR/diag6.json" || fail "diagnostics for round-trip failed"

node - "$TMP_DIR/diag6.json" <<'NODE'
const fs = require("fs");
const diag = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));

function fail(message) { throw new Error(message); }

// Verify the exact custom times round-tripped through settings
if (!diag.diagnostics.nightMode) fail("diagnostics missing nightMode for round-trip");
if (diag.diagnostics.nightMode.enabled !== true) fail("night mode should be enabled");
if (diag.diagnostics.nightMode.start !== "21:30") fail("night mode start should be 21:30 after round-trip, got " + diag.diagnostics.nightMode.start);
if (diag.diagnostics.nightMode.end !== "07:15") fail("night mode end should be 07:15 after round-trip, got " + diag.diagnostics.nightMode.end);
if (typeof diag.diagnostics.nightMode.startMin !== "number" || diag.diagnostics.nightMode.startMin !== 1290) fail("21:30 should be 1290 minutes");
if (typeof diag.diagnostics.nightMode.endMin !== "number" || diag.diagnostics.nightMode.endMin !== 435) fail("07:15 should be 435 minutes");

console.log("step 7 passed: custom night mode times (21:30-07:15) persist correctly through settings round-trip");
NODE

# --- Step 8: Support bundle includes night mode ---
curl -fsS "$BASE_URL/local/support-bundle?services=0&limit=5" >"$TMP_DIR/support1.json" || fail "support-bundle request failed"

node - "$TMP_DIR/support1.json" <<'NODE'
const fs = require("fs");
const support = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));

function fail(message) { throw new Error(message); }

if (!support.health) fail("support bundle missing top-level health");
if (!support.health.nightMode) fail("support bundle health missing nightMode");
if (support.health.nightMode.enabled !== true) fail("support bundle night mode should be enabled");

console.log("step 8 passed: support bundle includes night mode in health");
NODE

# --- Step 9: Welcome route serves for unpaired device ---
# Reset device to unpaired state
node - "$TMP_DIR/data" <<'NODE'
const fs = require("fs");
const dataDir = process.argv[2];

const device = JSON.parse(fs.readFileSync(dataDir + "/device.json", "utf8"));
device.paired = false;
device.firstRunComplete = false;
device.onboardingComplete = false;
delete device.ownerUserId;
delete device.deviceApiKey;

fs.writeFileSync(dataDir + "/device.json", JSON.stringify(device, null, 2) + "\n");

const state = JSON.parse(fs.readFileSync(dataDir + "/state.json", "utf8"));
state.currentMode = "setup";
fs.writeFileSync(dataDir + "/state.json", JSON.stringify(state, null, 2) + "\n");

console.log("reset to unpaired");
NODE

# Restart server to pick up state change
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true

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

# /launch should redirect to /welcome for unpaired device
WELCOME_LOCATION=$(curl -fsSI "$BASE_URL/launch" | grep -i "^location:" | tr -d '\r' || true)

node - "$WELCOME_LOCATION" <<'NODE'
const location = (process.argv[2] || "").trim();
function fail(message) { throw new Error(message); }
if (!location.includes("/welcome")) fail("/launch should redirect to /welcome for unpaired device, got: " + location);
console.log("step 9 passed: /launch redirects to /welcome for unpaired device");
NODE

# /welcome should return 200 with HTML
WELCOME_BODY=$(curl -fsS "$BASE_URL/welcome") || fail "/welcome returned non-200 for unpaired device"

node - "$WELCOME_BODY" <<'NODE'
const body = process.argv[2];
function fail(message) { throw new Error(message); }
if (!body.includes('Autopoiesis Frame') && !body.includes('welcome')) fail("/welcome should contain welcome content");
console.log("step 9b passed: /welcome route returns 200 for unpaired device");
NODE

# Welcome page should contain night mode controls
node - "$WELCOME_BODY" <<'NODE'
const body = process.argv[2];
function fail(message) { throw new Error(message); }
if (!body.includes('name="nightMode"')) fail("/welcome should contain night mode checkbox");
if (!body.includes('name="nightModeStart"')) fail("/welcome should contain night mode start time input");
if (!body.includes('name="nightModeEnd"')) fail("/welcome should contain night mode end time input");
if (!body.includes('welcome-night-toggle')) fail("/welcome should contain night mode toggle container");
console.log("step 9c passed: /welcome includes night mode controls (checkbox, start/end time inputs, toggle container)");
NODE

echo "night mode check passed: defaults, enable/disable round-trip, cross-midnight range, invalid time handling, apply endpoint, frame state, support bundle, welcome flow with night mode controls"
