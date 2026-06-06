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

PORT="${AUTOPOIESIS_EVENTS_INGESTION_CHECK_PORT:-$(pick_port)}"
API_PORT="${AUTOPOIESIS_EVENTS_INGESTION_CHECK_API_PORT:-$(pick_port)}"
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
  echo "events ingestion check failed: $*" >&2
  if [[ -f "$TMP_DIR/server.log" ]]; then
    echo "--- local-ui log ---" >&2
    sed -n '1,180p' "$TMP_DIR/server.log" >&2
  fi
  if [[ -f "$TMP_DIR/api.log" ]]; then
    echo "--- mock API log ---" >&2
    sed -n '1,180p' "$TMP_DIR/api.log" >&2
  fi
  if [[ -f "$TMP_DIR/first-heartbeat.json" ]]; then
    echo "--- first heartbeat response ---" >&2
    sed -n '1,120p' "$TMP_DIR/first-heartbeat.json" >&2
  fi
  if [[ -f "$TMP_DIR/mock-after-first.json" ]]; then
    echo "--- mock API state ---" >&2
    sed -n '1,180p' "$TMP_DIR/mock-after-first.json" >&2
  fi
  exit 1
}

mkdir -p "$TMP_DIR/data" "$TMP_DIR/log" "$TMP_DIR/cache"

node - "$TMP_DIR/data" "$API_URL/api" <<'NODE'
const fs = require("fs");
const dataDir = process.argv[2];
const apiBaseUrl = process.argv[3];

fs.writeFileSync(dataDir + "/device.json", JSON.stringify({
  deviceId: "rpi-events-ingestion-check",
  deviceName: "Events Ingestion Check Frame",
  paired: true,
  firstRunComplete: true,
  remoteEnabled: true,
  apiBaseUrl,
  framesUrl: "http://127.0.0.1:1/frames",
  deviceApiKey: "events-ingestion-check-secret"
}, null, 2) + "\n");

fs.writeFileSync(dataDir + "/preferences.json", JSON.stringify({
  displayMode: "local-feed",
  allowImages: true,
  allowVideos: true,
  allowSoundWorks: true,
  allowGenerativeWorks: true,
  updatedAt: "2026-06-06T10:00:00.000Z"
}, null, 2) + "\n");

fs.writeFileSync(dataDir + "/state.json", JSON.stringify({
  currentMode: "frame",
  networkOnline: true,
  networkType: "ethernet"
}, null, 2) + "\n");

fs.writeFileSync(dataDir + "/pairing.json", JSON.stringify({
  pairingCode: "EVT-0001",
  mock: false,
  status: "paired"
}, null, 2) + "\n");

fs.writeFileSync(dataDir + "/command-audit.json", JSON.stringify([
  {
    commandId: "cmd_ingest_1",
    commandType: "sync_settings",
    status: "completed",
    risk: "low",
    approved: true,
    completedAt: "2026-06-06T10:00:00.000Z"
  }
], null, 2) + "\n");

fs.writeFileSync(dataDir + "/delivery-log.json", JSON.stringify([
  {
    eventId: "delivery_ingest_1",
    eventType: "feed_synced",
    itemId: "feed_ingest_1",
    status: "synced",
    totalItems: 1,
    eligibleItems: 1,
    cacheEligibleItems: 1,
    observedAt: "2026-06-06T11:00:00.000Z"
  }
], null, 2) + "\n");

fs.writeFileSync(dataDir + "/release-log.json", JSON.stringify([
  {
    eventId: "release_ingest_1",
    eventType: "release_checked",
    status: "current",
    version: "0.1.1",
    currentVersion: "0.1.1",
    observedAt: "2026-06-06T12:00:00.000Z"
  }
], null, 2) + "\n");
NODE

node - "$API_PORT" >"$TMP_DIR/api.log" 2>&1 <<'NODE' &
const http = require("http");
const port = Number(process.argv[2]);
let mode = "latest";
let requests = [];

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

function ackFor(body) {
  if (mode === "stale") {
    return {
      status: "accepted",
      acceptedAt: "2026-06-06T12:10:00.000Z",
      acceptedThroughObservedAt: "2026-06-06T09:00:00.000Z",
      acceptedThroughEventKey: "stale:event",
      counts: { received: Array.isArray((body.events || {}).events) ? body.events.events.length : 0 }
    };
  }
  const events = Array.isArray((body.events || {}).events) ? body.events.events : [];
  const latest = events[0] || {};
  return {
    status: "accepted",
    acceptedAt: "2026-06-06T12:05:00.000Z",
    acceptedThroughObservedAt: latest.observedAt || null,
    acceptedThroughEventKey: latest.eventKey || null,
    sourceCursors: (body.events || {}).sourceCursors || null,
    counts: { received: events.length }
  };
}

http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://127.0.0.1");
  if (req.method === "GET" && url.pathname === "/__health") return send(res, 200, { ok: true });
  if (req.method === "GET" && url.pathname === "/__state") return send(res, 200, { mode, requests });
  if (req.method === "POST" && url.pathname === "/__mode") {
    const body = await readBody(req);
    mode = body.mode || "latest";
    return send(res, 200, { ok: true, mode });
  }
  if (req.method === "POST" && url.pathname.endsWith("/heartbeat")) {
    const body = await readBody(req);
    requests.push({
      receivedAt: new Date().toISOString(),
      eventIngestionCursor: body.eventIngestionCursor || null,
      events: body.events || null
    });
    return send(res, 200, { ok: true, eventsAck: ackFor(body), commands: [] });
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
AUTOPOIESIS_HEARTBEAT_EVENT_LIMIT=10 \
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
if (!status.device || status.device.deviceId !== "rpi-events-ingestion-check") {
  throw new Error("local UI status did not come from the seeded test device");
}
NODE

curl -fsS -X POST "$BASE_URL/local/heartbeat" >"$TMP_DIR/first-heartbeat.json" || fail "first heartbeat failed"
curl -fsS "$BASE_URL/local/diagnostics?services=0" >"$TMP_DIR/diagnostics-after-ack.json" || fail "diagnostics after ack failed"
curl -fsS "$BASE_URL/local/support-bundle?services=0&eventLimit=10" >"$TMP_DIR/support-after-ack.json" || fail "support bundle after ack failed"
curl -fsS "$API_URL/__state" >"$TMP_DIR/mock-after-first.json" || fail "mock state after first heartbeat failed"
[[ -f "$TMP_DIR/data/event-cursor.json" ]] || fail "event cursor was not written after accepted heartbeat"

node - "$TMP_DIR/data/event-cursor.json" "$TMP_DIR/data/device.json" "$TMP_DIR/diagnostics-after-ack.json" "$TMP_DIR/support-after-ack.json" "$TMP_DIR/mock-after-first.json" <<'NODE'
const fs = require("fs");
const [cursorPath, devicePath, diagnosticsPath, supportPath, mockPath] = process.argv.slice(2);
const cursor = JSON.parse(fs.readFileSync(cursorPath, "utf8"));
const device = JSON.parse(fs.readFileSync(devicePath, "utf8"));
const diagnosticsResponse = JSON.parse(fs.readFileSync(diagnosticsPath, "utf8"));
const diagnostics = diagnosticsResponse.diagnostics || diagnosticsResponse;
const support = JSON.parse(fs.readFileSync(supportPath, "utf8"));
const mock = JSON.parse(fs.readFileSync(mockPath, "utf8"));
const serialized = JSON.stringify({ cursor, diagnostics, support, mock });
if (serialized.includes("events-ingestion-check-secret")) throw new Error("device key value leaked into public contract");
if (!cursor.ok || cursor.kind !== "autopoiesis_frame_event_ingestion_cursor") throw new Error("event cursor was not persisted");
if (cursor.acceptedThroughObservedAt !== "2026-06-06T12:00:00.000Z") throw new Error("cursor did not store newest accepted observedAt");
if (!cursor.acceptedThroughEventKey || !cursor.acceptedThroughEventKey.startsWith("release:")) throw new Error("cursor did not store newest accepted event key");
if (!cursor.replaySince || Date.parse(cursor.replaySince) >= Date.parse(cursor.acceptedThroughObservedAt)) throw new Error("cursor replay window did not precede accepted timestamp");
if (device.lastEventIngestionAckStatus !== "accepted") throw new Error("device did not record accepted event ack status");
if (!diagnostics.eventIngestion || diagnostics.eventIngestion.status !== "accepted") throw new Error("diagnostics did not expose accepted event ingestion");
if (!support.summary || !support.summary.eventIngestion || support.summary.eventIngestion.status !== "accepted") throw new Error("support summary did not expose accepted event ingestion");
if (!Array.isArray(mock.requests) || mock.requests.length !== 1) throw new Error("mock API did not receive first heartbeat");
const first = mock.requests[0];
if (first.eventIngestionCursor !== null) throw new Error("first heartbeat should not include a previous cursor");
if (!first.events || !Array.isArray(first.events.events) || first.events.events.length !== 3) throw new Error("first heartbeat did not export all seeded events");
NODE

curl -fsS -X POST "$API_URL/__mode" -H 'content-type: application/json' -d '{"mode":"stale"}' >/dev/null || fail "mock stale mode failed"
curl -fsS -X POST "$BASE_URL/local/heartbeat" >"$TMP_DIR/stale-heartbeat.json" || fail "stale heartbeat failed"
curl -fsS "$API_URL/__state" >"$TMP_DIR/mock-after-stale.json" || fail "mock state after stale heartbeat failed"
curl -fsS "$BASE_URL/local/events/export?limit=10" >"$TMP_DIR/events-after-stale.json" || fail "event export after stale ack failed"

node - "$TMP_DIR/data/event-cursor.json" "$TMP_DIR/data/device.json" "$TMP_DIR/mock-after-stale.json" "$TMP_DIR/events-after-stale.json" <<'NODE'
const fs = require("fs");
const [cursorPath, devicePath, mockPath, eventsPath] = process.argv.slice(2);
const cursor = JSON.parse(fs.readFileSync(cursorPath, "utf8"));
const device = JSON.parse(fs.readFileSync(devicePath, "utf8"));
const mock = JSON.parse(fs.readFileSync(mockPath, "utf8"));
const events = JSON.parse(fs.readFileSync(eventsPath, "utf8"));
if (cursor.acceptedThroughObservedAt !== "2026-06-06T12:00:00.000Z") throw new Error("stale ack overwrote the newer cursor");
if (device.lastEventIngestionAckStatus !== "stale_event_ingestion_ack") throw new Error("device did not record stale ack rejection status");
if (!Array.isArray(mock.requests) || mock.requests.length !== 2) throw new Error("mock API did not receive second heartbeat");
const second = mock.requests[1];
if (!second.eventIngestionCursor || second.eventIngestionCursor.acceptedThroughObservedAt !== "2026-06-06T12:00:00.000Z") {
  throw new Error("second heartbeat did not include the accepted cursor");
}
if (!second.events || second.events.since !== cursor.replaySince) throw new Error("second heartbeat did not use cursor replaySince");
if (!Array.isArray(second.events.events) || second.events.events.length !== 1) {
  throw new Error("second heartbeat did not bound replay to the overlap window");
}
if (!events.ingestionCursor || events.ingestionCursor.acceptedThroughObservedAt !== "2026-06-06T12:00:00.000Z") {
  throw new Error("events export did not expose the retained ingestion cursor");
}
NODE

echo "Autopoiesis Frame events ingestion cursor check passed"
