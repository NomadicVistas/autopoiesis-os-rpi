#!/usr/bin/env bash
set -euo pipefail

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

PORT="${AUTOPOIESIS_COMMAND_ACK_RETRY_CHECK_PORT:-$(pick_port)}"
API_PORT="${AUTOPOIESIS_COMMAND_ACK_RETRY_CHECK_API_PORT:-$(pick_port)}"
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
  echo "command ack retry check failed: $*" >&2
  if [[ -f "$TMP_DIR/server.log" ]]; then
    echo "--- local-ui log ---" >&2
    sed -n '1,180p' "$TMP_DIR/server.log" >&2
  fi
  if [[ -f "$TMP_DIR/api.log" ]]; then
    echo "--- mock API log ---" >&2
    sed -n '1,180p' "$TMP_DIR/api.log" >&2
  fi
  if [[ -f "$TMP_DIR/mock-state.json" ]]; then
    echo "--- mock API state ---" >&2
    sed -n '1,220p' "$TMP_DIR/mock-state.json" >&2
  fi
  exit 1
}

mkdir -p "$TMP_DIR/data" "$TMP_DIR/log" "$TMP_DIR/cache"

node - "$TMP_DIR/data" "$API_URL/api" <<'NODE'
const fs = require("fs");
const dataDir = process.argv[2];
const apiBaseUrl = process.argv[3];

fs.writeFileSync(dataDir + "/device.json", JSON.stringify({
  deviceId: "rpi-command-ack-retry-check",
  deviceName: "Command Ack Retry Check Frame",
  paired: true,
  firstRunComplete: true,
  remoteEnabled: true,
  apiBaseUrl,
  framesUrl: "http://127.0.0.1:1/frames",
  deviceApiKey: "command-ack-retry-check-secret"
}, null, 2) + "\n");

fs.writeFileSync(dataDir + "/preferences.json", JSON.stringify({
  displayMode: "local-feed",
  volume: 10,
  imageDuration: 60,
  updatedAt: "2026-06-06T10:00:00.000Z"
}, null, 2) + "\n");

fs.writeFileSync(dataDir + "/state.json", JSON.stringify({
  currentMode: "frame",
  networkOnline: true,
  networkType: "ethernet"
}, null, 2) + "\n");

fs.writeFileSync(dataDir + "/pairing.json", JSON.stringify({
  pairingCode: "ACK-0001",
  mock: false,
  status: "paired"
}, null, 2) + "\n");

fs.writeFileSync(dataDir + "/commands.json", JSON.stringify([
  { id: "cmd_initial", commandType: "sync_settings", payload: {} }
], null, 2) + "\n");
NODE

node - "$API_PORT" >"$TMP_DIR/api.log" 2>&1 <<'NODE' &
const http = require("http");
const port = Number(process.argv[2]);
let settings = {
  volume: 51,
  imageDuration: 61,
  updatedAt: "2026-06-06T11:00:00.000Z"
};
let settingsGets = 0;
let heartbeatRequests = [];
let ackRequests = [];
let failures = { oneShot: {}, persistent: {} };

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

function listFor(map, status) {
  const values = map && map[status];
  return Array.isArray(values) ? values : [];
}

function shouldFail(commandId, status) {
  if (listFor(failures.persistent, status).includes(commandId)) return true;
  const oneShot = listFor(failures.oneShot, status);
  if (!oneShot.includes(commandId)) return false;
  failures.oneShot[status] = oneShot.filter(id => id !== commandId);
  return true;
}

http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://127.0.0.1");
  if (req.method === "GET" && url.pathname === "/__health") return send(res, 200, { ok: true });
  if (req.method === "GET" && url.pathname === "/__state") {
    return send(res, 200, { settings, settingsGets, heartbeatRequests, ackRequests, failures });
  }
  if (req.method === "POST" && url.pathname === "/__settings") {
    const body = await readBody(req);
    settings = { ...(body.settings || {}) };
    return send(res, 200, { ok: true, settings });
  }
  if (req.method === "POST" && url.pathname === "/__failures") {
    const body = await readBody(req);
    failures = {
      oneShot: body.oneShot || {},
      persistent: body.persistent || {}
    };
    return send(res, 200, { ok: true, failures });
  }
  if (url.pathname.endsWith("/heartbeat") && req.method === "POST") {
    heartbeatRequests.push(await readBody(req));
    return send(res, 200, { ok: true, commands: [] });
  }
  if (url.pathname.endsWith("/settings") && req.method === "GET") {
    settingsGets += 1;
    return send(res, 200, { ok: true, settings, updatedAt: settings.updatedAt });
  }
  const ackMatch = url.pathname.match(/\/commands\/([^/]+)\/ack$/);
  if (ackMatch && req.method === "POST") {
    const commandId = decodeURIComponent(ackMatch[1]);
    const body = await readBody(req);
    const status = String(body.status || "");
    ackRequests.push({ commandId, status, body });
    if (shouldFail(commandId, status)) {
      return send(res, 503, { ok: false, error: "forced " + status + " ack failure for " + commandId });
    }
    return send(res, 200, { ok: true, commandId, status });
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
curl -fsS "$BASE_URL/local/status" >"$TMP_DIR/status.json" || fail "local UI did not start"

node - "$TMP_DIR/status.json" <<'NODE'
const fs = require("fs");
const status = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (!status.device || status.device.deviceId !== "rpi-command-ack-retry-check") {
  throw new Error("local UI status did not come from the seeded test device");
}
NODE

curl -fsS -X POST "$API_URL/__failures" \
  -H 'content-type: application/json' \
  -d '{"oneShot":{"acknowledged":["cmd_initial"]}}' >/dev/null || fail "could not configure initial ack failure"
curl -fsS -X POST "$BASE_URL/local/commands/process" >"$TMP_DIR/initial-failed.json" || fail "initial ack failure processing failed"
curl -fsS "$BASE_URL/local/commands/audit" >"$TMP_DIR/audit-initial-failed.json" || fail "initial failed audit request failed"
curl -fsS "$API_URL/__state" >"$TMP_DIR/mock-state.json" || fail "mock state after initial failure failed"

node - "$TMP_DIR/data/commands.json" "$TMP_DIR/data/preferences.json" "$TMP_DIR/audit-initial-failed.json" "$TMP_DIR/mock-state.json" <<'NODE'
const fs = require("fs");
const [commandsPath, preferencesPath, auditPath, mockPath] = process.argv.slice(2);
const commands = JSON.parse(fs.readFileSync(commandsPath, "utf8"));
const preferences = JSON.parse(fs.readFileSync(preferencesPath, "utf8"));
const audit = JSON.parse(fs.readFileSync(auditPath, "utf8"));
const mock = JSON.parse(fs.readFileSync(mockPath, "utf8"));
if (commands.length !== 1 || commands[0].id !== "cmd_initial") throw new Error("initial ack failure did not retain command");
if (!commands[0].localAck || commands[0].localAck.phase !== "acknowledge") throw new Error("initial ack failure did not retain acknowledge retry metadata");
if (preferences.volume !== 10) throw new Error("command executed before initial acknowledgement succeeded");
if (mock.settingsGets !== 0) throw new Error("sync_settings called the settings API before initial acknowledgement succeeded");
if (!audit.entries.length || audit.entries[0].status !== "ack_failed") throw new Error("initial ack failure did not create ack_failed audit entry");
NODE

curl -fsS -X POST "$BASE_URL/local/commands/process" >"$TMP_DIR/initial-retried.json" || fail "initial ack retry processing failed"
curl -fsS "$API_URL/__state" >"$TMP_DIR/mock-state.json" || fail "mock state after initial retry failed"

node - "$TMP_DIR/data/commands.json" "$TMP_DIR/data/preferences.json" "$TMP_DIR/mock-state.json" <<'NODE'
const fs = require("fs");
const [commandsPath, preferencesPath, mockPath] = process.argv.slice(2);
const commands = JSON.parse(fs.readFileSync(commandsPath, "utf8"));
const preferences = JSON.parse(fs.readFileSync(preferencesPath, "utf8"));
const mock = JSON.parse(fs.readFileSync(mockPath, "utf8"));
if (commands.length !== 0) throw new Error("initial ack retry did not clear the command after completion");
if (preferences.volume !== 51) throw new Error("initial ack retry did not execute sync_settings after acknowledgement succeeded");
if (mock.settingsGets !== 1) throw new Error("sync_settings execution count after initial retry was not exactly one");
const cmdAcks = mock.ackRequests.filter(item => item.commandId === "cmd_initial").map(item => item.status);
if (cmdAcks.filter(status => status === "acknowledged").length !== 2 || !cmdAcks.includes("completed")) {
  throw new Error("initial ack retry did not send the expected acknowledgement sequence");
}
NODE

node - "$TMP_DIR/data" <<'NODE'
const fs = require("fs");
const dataDir = process.argv[2];
fs.writeFileSync(dataDir + "/commands.json", JSON.stringify([
  { id: "cmd_final", commandType: "sync_settings", payload: {} }
], null, 2) + "\n");
NODE
curl -fsS -X POST "$API_URL/__settings" \
  -H 'content-type: application/json' \
  -d '{"settings":{"volume":52,"imageDuration":62,"updatedAt":"2026-06-06T12:00:00.000Z"}}' >/dev/null || fail "could not update mock settings for final ack case"
curl -fsS -X POST "$API_URL/__failures" \
  -H 'content-type: application/json' \
  -d '{"oneShot":{"completed":["cmd_final"]}}' >/dev/null || fail "could not configure final ack failure"
curl -fsS -X POST "$BASE_URL/local/commands/process" >"$TMP_DIR/final-failed.json" || fail "final ack failure processing failed"
curl -fsS "$BASE_URL/local/commands/audit" >"$TMP_DIR/audit-final-failed.json" || fail "final failed audit request failed"
curl -fsS "$BASE_URL/local/diagnostics?services=0" >"$TMP_DIR/diagnostics-final-failed.json" || fail "diagnostics after final ack failure failed"
curl -fsS "$API_URL/__state" >"$TMP_DIR/mock-state.json" || fail "mock state after final failure failed"

node - "$TMP_DIR/data/commands.json" "$TMP_DIR/data/preferences.json" "$TMP_DIR/audit-final-failed.json" "$TMP_DIR/diagnostics-final-failed.json" "$TMP_DIR/mock-state.json" <<'NODE'
const fs = require("fs");
const [commandsPath, preferencesPath, auditPath, diagnosticsPath, mockPath] = process.argv.slice(2);
const commands = JSON.parse(fs.readFileSync(commandsPath, "utf8"));
const preferences = JSON.parse(fs.readFileSync(preferencesPath, "utf8"));
const audit = JSON.parse(fs.readFileSync(auditPath, "utf8"));
const diagnosticsResponse = JSON.parse(fs.readFileSync(diagnosticsPath, "utf8"));
const diagnostics = diagnosticsResponse.diagnostics || diagnosticsResponse;
const mock = JSON.parse(fs.readFileSync(mockPath, "utf8"));
if (commands.length !== 1 || commands[0].id !== "cmd_final") throw new Error("final ack failure did not retain command");
if (!commands[0].localAck || commands[0].localAck.phase !== "final" || commands[0].localAck.status !== "completed") {
  throw new Error("final ack failure did not retain final acknowledgement retry metadata");
}
if (preferences.volume !== 52) throw new Error("command did not execute before final acknowledgement failed");
if (mock.settingsGets !== 2) throw new Error("final ack failure should have executed sync_settings exactly once");
if (!audit.entries.length || audit.entries[0].status !== "ack_failed") throw new Error("final ack failure was not visible as ack_failed in command audit");
if (!diagnostics.commandAudit || diagnostics.commandAudit.recentErrors < 1) {
  throw new Error("diagnostics commandAudit did not count the final ack failure as a recent error");
}
NODE

curl -fsS -X POST "$BASE_URL/local/commands/process" >"$TMP_DIR/final-retried.json" || fail "final ack retry processing failed"
curl -fsS "$API_URL/__state" >"$TMP_DIR/mock-state.json" || fail "mock state after final retry failed"

node - "$TMP_DIR/data/commands.json" "$TMP_DIR/data/preferences.json" "$TMP_DIR/mock-state.json" <<'NODE'
const fs = require("fs");
const [commandsPath, preferencesPath, mockPath] = process.argv.slice(2);
const commands = JSON.parse(fs.readFileSync(commandsPath, "utf8"));
const preferences = JSON.parse(fs.readFileSync(preferencesPath, "utf8"));
const mock = JSON.parse(fs.readFileSync(mockPath, "utf8"));
if (commands.length !== 0) throw new Error("final ack retry did not clear the retained command");
if (preferences.volume !== 52) throw new Error("final ack retry re-executed sync_settings unexpectedly");
if (mock.settingsGets !== 2) throw new Error("final ack retry should not call settings API again");
const cmdAcks = mock.ackRequests.filter(item => item.commandId === "cmd_final").map(item => item.status);
if (cmdAcks.filter(status => status === "acknowledged").length !== 1) throw new Error("final ack retry sent an extra initial acknowledgement");
if (cmdAcks.filter(status => status === "completed").length !== 2) throw new Error("final ack retry did not retry only the completed acknowledgement");
NODE

node - "$TMP_DIR/data" <<'NODE'
const fs = require("fs");
const dataDir = process.argv[2];
fs.writeFileSync(dataDir + "/commands.json", JSON.stringify([
  {
    id: "cmd_retry",
    commandType: "sync_settings",
    payload: {},
    localAck: {
      phase: "final",
      status: "completed",
      extra: {},
      attempts: 1,
      firstFailedAt: "2026-06-06T12:30:00.000Z",
      lastFailedAt: "2026-06-06T12:30:00.000Z",
      lastError: "seeded retry failure"
    }
  }
], null, 2) + "\n");
NODE
curl -fsS -X POST "$API_URL/__failures" \
  -H 'content-type: application/json' \
  -d '{"persistent":{"completed":["cmd_retry"]}}' >/dev/null || fail "could not configure persistent final ack retry failure"
curl -fsS -X POST "$BASE_URL/local/commands/process" >"$TMP_DIR/final-retry-failed.json" || fail "final ack retry failure processing failed"
curl -fsS "$BASE_URL/local/commands/audit" >"$TMP_DIR/audit-final-retry-failed.json" || fail "final retry failed audit request failed"
curl -fsS "$API_URL/__state" >"$TMP_DIR/mock-state.json" || fail "mock state after final retry failure failed"

node - "$TMP_DIR/data/commands.json" "$TMP_DIR/audit-final-retry-failed.json" "$TMP_DIR/mock-state.json" <<'NODE'
const fs = require("fs");
const [commandsPath, auditPath, mockPath] = process.argv.slice(2);
const commands = JSON.parse(fs.readFileSync(commandsPath, "utf8"));
const audit = JSON.parse(fs.readFileSync(auditPath, "utf8"));
const mock = JSON.parse(fs.readFileSync(mockPath, "utf8"));
if (commands.length !== 1 || commands[0].id !== "cmd_retry") throw new Error("failed final ack retry did not retain command");
if (!commands[0].localAck || commands[0].localAck.phase !== "final" || commands[0].localAck.attempts !== 2) {
  throw new Error("failed final ack retry did not increment retry metadata");
}
if (!audit.entries.length || audit.entries[0].status !== "ack_retry_failed") throw new Error("failed final ack retry did not create ack_retry_failed audit entry");
const cmdAcks = mock.ackRequests.filter(item => item.commandId === "cmd_retry").map(item => item.status);
if (cmdAcks.length !== 1 || cmdAcks[0] !== "completed") throw new Error("failed final ack retry did not retry only the final acknowledgement");
NODE

echo "command ack retry check passed: initial ack failures retain commands before execution, final ack failures are audited, final retries do not re-execute commands, and retry failures remain visible"
