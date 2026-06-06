#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${AUTOPOIESIS_SETTINGS_SYNC_CHECK_PORT:-3138}"
API_PORT="${AUTOPOIESIS_SETTINGS_SYNC_CHECK_API_PORT:-3139}"
BASE_URL="http://127.0.0.1:${PORT}"
API_URL="http://127.0.0.1:${API_PORT}"
TMP_DIR="$(mktemp -d)"
SERVER_PID=""
API_PID=""

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  if [[ -n "${API_PID:-}" ]] && kill -0 "$API_PID" >/dev/null 2>&1; then
    kill "$API_PID" >/dev/null 2>&1 || true
    wait "$API_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "settings sync check failed: $*" >&2
  if [[ -f "$TMP_DIR/server.log" ]]; then
    echo "--- local-ui log ---" >&2
    sed -n '1,160p' "$TMP_DIR/server.log" >&2
  fi
  if [[ -f "$TMP_DIR/api.log" ]]; then
    echo "--- mock API log ---" >&2
    sed -n '1,160p' "$TMP_DIR/api.log" >&2
  fi
  exit 1
}

mkdir -p "$TMP_DIR/data" "$TMP_DIR/log" "$TMP_DIR/cache"

node - "$TMP_DIR/data" "$API_URL/api" <<'NODE'
const fs = require("fs");
const dataDir = process.argv[2];
const apiBaseUrl = process.argv[3];
fs.writeFileSync(dataDir + "/device.json", JSON.stringify({
  deviceId: "rpi-settings-sync-check",
  deviceName: "Settings Sync Check Frame",
  paired: true,
  firstRunComplete: true,
  remoteEnabled: true,
  apiBaseUrl,
  framesUrl: "http://127.0.0.1:1/frames",
  deviceApiKey: "settings-sync-check-secret",
  settingsUpdatedAt: "2026-06-06T10:00:00.000Z"
}, null, 2) + "\n");
fs.writeFileSync(dataDir + "/preferences.json", JSON.stringify({
  language: "en",
  displayMode: "living-stream",
  allowImages: true,
  allowVideos: true,
  allowSoundWorks: true,
  allowGenerativeWorks: true,
  soundEnabled: false,
  volume: 50,
  imageDuration: 60,
  updatedAt: "2026-06-06T10:00:00.000Z"
}, null, 2) + "\n");
fs.writeFileSync(dataDir + "/pairing.json", JSON.stringify({
  pairingCode: "SYNC-0001",
  mock: false,
  status: "paired"
}, null, 2) + "\n");
NODE

node - "$API_PORT" >"$TMP_DIR/api.log" 2>&1 <<'NODE' &
const http = require("http");
const port = Number(process.argv[2]);
let remoteSettings = {
  imageDuration: 15,
  volume: 15,
  updatedAt: "2026-06-06T09:00:00.000Z"
};
let lastPosted = null;

function send(res, status, payload) {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(payload));
}

function readBody(req) {
  return new Promise(resolve => {
    let body = "";
    req.on("data", chunk => {
      body += chunk;
    });
    req.on("end", () => {
      try {
        resolve(body ? JSON.parse(body) : {});
      } catch {
        resolve({});
      }
    });
  });
}

http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://127.0.0.1");
  if (req.method === "GET" && url.pathname === "/__health") return send(res, 200, { ok: true });
  if (req.method === "GET" && url.pathname === "/__state") {
    return send(res, 200, { remoteSettings, lastPosted });
  }
  if (req.method === "POST" && url.pathname === "/__settings") {
    const body = await readBody(req);
    remoteSettings = { ...(body.settings || {}) };
    return send(res, 200, { ok: true, remoteSettings });
  }
  if (url.pathname.endsWith("/settings")) {
    if (req.method === "GET") return send(res, 200, { ok: true, settings: remoteSettings, updatedAt: remoteSettings.updatedAt });
    if (req.method === "POST") {
      const body = await readBody(req);
      lastPosted = body;
      remoteSettings = { ...(body.settings || {}), updatedAt: (body.settings || {}).updatedAt || new Date().toISOString() };
      return send(res, 200, { ok: true, settings: remoteSettings, updatedAt: remoteSettings.updatedAt });
    }
  }
  if (url.pathname.endsWith("/heartbeat") && req.method === "POST") {
    return send(res, 200, { ok: true, settings: remoteSettings, commands: [] });
  }
  return send(res, 404, { error: "not_found", path: url.pathname });
}).listen(port, "127.0.0.1");
NODE
API_PID="$!"

for _ in {1..50}; do
  if curl -fsS "$API_URL/__health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
curl -fsS "$API_URL/__health" >/dev/null || fail "mock Frames API did not start"

AUTOPOIESIS_DATA_DIR="$TMP_DIR/data" \
AUTOPOIESIS_LOG_DIR="$TMP_DIR/log" \
AUTOPOIESIS_CACHE_DIR="$TMP_DIR/cache" \
AUTOPOIESIS_PORT="$PORT" \
AUTOPOIESIS_API_TIMEOUT_MS=800 \
AUTOPOIESIS_LAUNCH_PROBE_TIMEOUT_MS=100 \
  node "$ROOT_DIR/local-ui/server.js" >"$TMP_DIR/server.log" 2>&1 &
SERVER_PID="$!"

for _ in {1..50}; do
  if curl -fsS "$BASE_URL/local/status" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
curl -fsS "$BASE_URL/local/status" >/dev/null || fail "local UI did not start"

curl -fsS -X POST "$BASE_URL/local/settings/sync" >"$TMP_DIR/stale-sync.json" || fail "stale settings sync request failed"
curl -fsS "$BASE_URL/local/diagnostics?services=0" >"$TMP_DIR/stale-diagnostics.json" || fail "stale diagnostics request failed"
curl -fsS "$BASE_URL/local/health?services=0" >"$TMP_DIR/stale-health.json" || fail "stale health request failed"

node - "$TMP_DIR/data/preferences.json" "$TMP_DIR/stale-sync.json" "$TMP_DIR/stale-diagnostics.json" "$TMP_DIR/stale-health.json" <<'NODE'
const fs = require("fs");
const [preferencesPath, syncPath, diagnosticsPath, healthPath] = process.argv.slice(2);
const preferences = JSON.parse(fs.readFileSync(preferencesPath, "utf8"));
const sync = JSON.parse(fs.readFileSync(syncPath, "utf8"));
const diagnosticsResponse = JSON.parse(fs.readFileSync(diagnosticsPath, "utf8"));
const diagnostics = diagnosticsResponse.diagnostics || diagnosticsResponse;
const health = JSON.parse(fs.readFileSync(healthPath, "utf8"));
const issueCodes = ((health.health || {}).issues || []).map(issue => issue.code);
if (preferences.imageDuration !== 60) throw new Error("stale remote settings overwrote local preferences");
if (!sync.sync || sync.sync.conflict !== true || sync.sync.reason !== "remote_settings_stale") {
  throw new Error("stale remote settings did not report a conflict");
}
if (!diagnostics.settingsSync || diagnostics.settingsSync.status !== "local_newer" || diagnostics.settingsSync.conflict !== true) {
  throw new Error("diagnostics did not expose local_newer settings conflict");
}
if (!issueCodes.includes("settings_conflict")) {
  throw new Error("health did not expose settings_conflict issue");
}
NODE

curl -fsS -X POST "$API_URL/__settings" \
  -H 'content-type: application/json' \
  -d '{"settings":{"imageDuration":120,"volume":20,"updatedAt":"2026-06-06T11:00:00.000Z"}}' >/dev/null || fail "mock settings update failed"
curl -fsS -X POST "$BASE_URL/local/settings/sync" >"$TMP_DIR/newer-sync.json" || fail "newer settings sync request failed"
curl -fsS "$BASE_URL/local/diagnostics?services=0" >"$TMP_DIR/newer-diagnostics.json" || fail "newer diagnostics request failed"

node - "$TMP_DIR/data/preferences.json" "$TMP_DIR/newer-sync.json" "$TMP_DIR/newer-diagnostics.json" <<'NODE'
const fs = require("fs");
const [preferencesPath, syncPath, diagnosticsPath] = process.argv.slice(2);
const preferences = JSON.parse(fs.readFileSync(preferencesPath, "utf8"));
const sync = JSON.parse(fs.readFileSync(syncPath, "utf8"));
const diagnosticsResponse = JSON.parse(fs.readFileSync(diagnosticsPath, "utf8"));
const diagnostics = diagnosticsResponse.diagnostics || diagnosticsResponse;
if (preferences.imageDuration !== 120 || preferences.volume !== 20) {
  throw new Error("newer remote settings were not applied");
}
if (preferences.updatedAt !== "2026-06-06T11:00:00.000Z") {
  throw new Error("newer remote updatedAt was not persisted");
}
if (!sync.sync || sync.sync.applied !== true || sync.sync.conflict !== false) {
  throw new Error("newer remote settings did not report applied=true");
}
if (!diagnostics.settingsSync || diagnostics.settingsSync.conflict !== false) {
  throw new Error("diagnostics did not clear settings conflict");
}
NODE

curl -fsS -X POST "$BASE_URL/local/settings" \
  -H 'content-type: application/json' \
  -d '{"preferences":{"volume":77,"updatedAt":"2026-06-06T12:00:00.000Z"}}' >"$TMP_DIR/local-push.json" || fail "local settings push failed"
curl -fsS "$API_URL/__state" >"$TMP_DIR/mock-state.json" || fail "mock API state request failed"

node - "$TMP_DIR/data/preferences.json" "$TMP_DIR/local-push.json" "$TMP_DIR/mock-state.json" <<'NODE'
const fs = require("fs");
const [preferencesPath, pushPath, mockPath] = process.argv.slice(2);
const preferences = JSON.parse(fs.readFileSync(preferencesPath, "utf8"));
const push = JSON.parse(fs.readFileSync(pushPath, "utf8"));
const mock = JSON.parse(fs.readFileSync(mockPath, "utf8"));
if (preferences.volume !== 77 || preferences.updatedAt !== "2026-06-06T12:00:00.000Z") {
  throw new Error("local settings save did not persist the explicit updatedAt");
}
if (!push.remote || push.remote.ok !== true) throw new Error("local settings push did not reach the mock API");
if (!mock.lastPosted || !mock.lastPosted.settings || mock.lastPosted.settings.volume !== 77) {
  throw new Error("mock API did not receive the local settings payload");
}
if (mock.lastPosted.settings.updatedAt !== "2026-06-06T12:00:00.000Z") {
  throw new Error("local settings push did not include updatedAt");
}
NODE

curl -fsS -X POST "$API_URL/__settings" \
  -H 'content-type: application/json' \
  -d '{"settings":{"imageDuration":30,"volume":30,"updatedAt":"2026-06-06T11:30:00.000Z"}}' >/dev/null || fail "mock stale heartbeat settings update failed"
curl -fsS -X POST "$BASE_URL/local/heartbeat" >"$TMP_DIR/heartbeat.json" || fail "heartbeat request failed"
curl -fsS "$BASE_URL/local/diagnostics?services=0" >"$TMP_DIR/heartbeat-diagnostics.json" || fail "heartbeat diagnostics request failed"

node - "$TMP_DIR/data/preferences.json" "$TMP_DIR/heartbeat-diagnostics.json" <<'NODE'
const fs = require("fs");
const [preferencesPath, diagnosticsPath] = process.argv.slice(2);
const preferences = JSON.parse(fs.readFileSync(preferencesPath, "utf8"));
const diagnosticsResponse = JSON.parse(fs.readFileSync(diagnosticsPath, "utf8"));
const diagnostics = diagnosticsResponse.diagnostics || diagnosticsResponse;
if (preferences.volume !== 77 || preferences.updatedAt !== "2026-06-06T12:00:00.000Z") {
  throw new Error("stale heartbeat settings overwrote local preferences");
}
if (!diagnostics.settingsSync || diagnostics.settingsSync.status !== "local_newer" || diagnostics.settingsSync.source !== "heartbeat") {
  throw new Error("heartbeat stale settings did not record a local_newer conflict");
}
NODE

echo "settings sync check passed: stale remote payloads are rejected, newer remote settings apply, local pushes include updatedAt, and stale heartbeat settings preserve local preferences"
