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

PORT="${AUTOPOIESIS_BROADCAST_COMMAND_CHECK_PORT:-$(pick_port)}"
API_PORT="${AUTOPOIESIS_BROADCAST_COMMAND_CHECK_API_PORT:-$(pick_port)}"
BASE_URL="http://127.0.0.1:$PORT"
API_URL="http://127.0.0.1:$API_PORT"
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
  echo "broadcast command check failed: $*" >&2
  if [[ -f "$TMP_DIR/server.log" ]]; then
    echo "--- local-ui log ---" >&2
    sed -n '1,180p' "$TMP_DIR/server.log" >&2
  fi
  if [[ -f "$TMP_DIR/api.log" ]]; then
    echo "--- mock API log ---" >&2
    sed -n '1,180p' "$TMP_DIR/api.log" >&2
  fi
  exit 1
}

queue_command() {
  local command_id="$1"
  local payload_kind="$2"
  node - "$TMP_DIR/data" "$command_id" "$payload_kind" <<'NODE'
const fs = require("fs");
const dataDir = process.argv[2];
const commandId = process.argv[3];
const kind = process.argv[4];
const now = new Date().toISOString();

const payloads = {
  wrong_target: {
    id: "broadcast-wrong-target",
    type: "emergency_notice",
    title: "Wrong Target",
    body: "This command should not reach this frame.",
    priority: "critical",
    duration: 3,
    targeting: { deviceIds: ["rpi-other-broadcast-frame"] }
  },
  future: {
    id: "broadcast-future",
    type: "curatorial_announcement",
    title: "Scheduled Broadcast",
    body: "This is accepted but not displayed yet.",
    priority: "high",
    duration: 3,
    startsAt: "2099-01-01T00:00:00.000Z",
    targeting: { deviceIds: ["rpi-broadcast-command-check"] }
  },
  visible: {
    id: "broadcast-visible",
    type: "curatorial_announcement",
    title: "Visible Broadcast",
    body: "This broadcast should render on the local page.",
    mediaUrl: "https://example.test/broadcast.jpg",
    priority: "critical",
    duration: 3,
    targeting: { targetType: "device", targetValue: "rpi-broadcast-command-check" }
  },
  expired: {
    id: "broadcast-expired",
    type: "system_notice",
    title: "Expired Broadcast",
    body: "This expired command must be rejected.",
    priority: "high",
    duration: 3,
    expiresAt: "2020-01-01T00:00:00.000Z",
    targeting: { deviceIds: ["rpi-broadcast-command-check"] }
  }
};

const payload = payloads[kind];
if (!payload) throw new Error("unknown payload kind: " + kind);
payload.authorization = {
  approved: true,
  action: "show_broadcast",
  actorId: "admin-broadcast-check",
  actorRole: "admin",
  authorizedAt: now
};

fs.writeFileSync(dataDir + "/commands.json", JSON.stringify([{
  id: commandId,
  commandType: "show_broadcast",
  payload
}], null, 2) + "\n");
NODE
}

mkdir -p "$TMP_DIR/data" "$TMP_DIR/log" "$TMP_DIR/cache"

node - "$TMP_DIR/data" "$API_URL/api" <<'NODE'
const fs = require("fs");
const dataDir = process.argv[2];
const apiBaseUrl = process.argv[3];

fs.writeFileSync(dataDir + "/device.json", JSON.stringify({
  deviceId: "rpi-broadcast-command-check",
  deviceName: "Broadcast Command Check Frame",
  ownerUserId: "user-broadcast-owner",
  paired: true,
  firstRunComplete: true,
  onboardingComplete: true,
  remoteEnabled: true,
  subscriptionStatus: "active",
  subscriptionTier: "patron",
  region: "nl",
  country: "nl",
  apiBaseUrl,
  framesUrl: "http://127.0.0.1:1/display",
  deviceApiKey: "broadcast-command-check-secret"
}, null, 2) + "\n");

fs.writeFileSync(dataDir + "/preferences.json", JSON.stringify({
  displayMode: "local-feed",
  streamProfile: "living-stream",
  streamCategories: ["artwork", "broadcast", "curatorial", "blog", "news"],
  activeArtists: [],
  allowImages: true,
  allowVideos: true,
  allowSoundWorks: true,
  allowGenerativeWorks: true,
  imageDuration: 9,
  updatedAt: "2026-06-06T18:25:00.000Z"
}, null, 2) + "\n");

fs.writeFileSync(dataDir + "/pairing.json", JSON.stringify({
  pairingCode: "BCAST-1",
  mock: false,
  status: "paired"
}, null, 2) + "\n");

fs.writeFileSync(dataDir + "/feed.json", JSON.stringify({
  syncedAt: "2026-06-06T18:25:00.000Z",
  source: "fixture",
  items: [{
    id: "fallback-art",
    source: "feed",
    type: "artwork",
    title: "Fallback Work",
    mediaUrl: "https://example.test/fallback.jpg",
    priority: "normal",
    cacheAllowed: true
  }]
}, null, 2) + "\n");
NODE

node - "$API_PORT" >"$TMP_DIR/api.log" 2>&1 <<'NODE' &
const http = require("http");
const port = Number(process.argv[2]);
const acks = [];
let heartbeatCount = 0;

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
  if (req.method === "GET" && url.pathname === "/__state") return send(res, 200, { acks, heartbeatCount });
  if (req.method === "POST" && url.pathname.endsWith("/heartbeat")) {
    heartbeatCount += 1;
    return send(res, 200, { ok: true, commands: [] });
  }
  const ackMatch = url.pathname.match(/\/commands\/([^/]+)\/ack$/);
  if (req.method === "POST" && ackMatch) {
    const body = await readBody(req);
    acks.push({ commandId: decodeURIComponent(ackMatch[1]), status: body.status || null, body });
    return send(res, 200, { ok: true });
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

queue_command "cmd-wrong-target" wrong_target
curl -fsS -X POST "$BASE_URL/local/commands/process" >"$TMP_DIR/wrong-target-process.json" || fail "wrong-target command processing failed"
curl -fsS "$BASE_URL/local/commands/audit?limit=5" >"$TMP_DIR/wrong-target-audit.json" || fail "wrong-target audit fetch failed"

node - "$TMP_DIR/wrong-target-process.json" "$TMP_DIR/wrong-target-audit.json" "$TMP_DIR/data/current-broadcast.json" <<'NODE'
const fs = require("fs");
const [processPath, auditPath, broadcastPath] = process.argv.slice(2);
const processed = JSON.parse(fs.readFileSync(processPath, "utf8"));
const audit = JSON.parse(fs.readFileSync(auditPath, "utf8"));
function fail(message) { throw new Error(message); }
const result = processed.results.find(entry => entry.commandId === "cmd-wrong-target");
if (!result || !result.result || result.result.ok !== false || !String(result.result.error || "").includes("target")) {
  fail("wrong-target command was not rejected by targeting");
}
if (fs.existsSync(broadcastPath)) fail("wrong-target command wrote current-broadcast.json");
if (!audit.entries.some(entry => entry.commandId === "cmd-wrong-target" && entry.status === "error")) {
  fail("wrong-target command did not produce an audit error");
}
NODE

queue_command "cmd-future" future
curl -fsS -X POST "$BASE_URL/local/commands/process" >"$TMP_DIR/future-process.json" || fail "future command processing failed"
curl -fsS -D "$TMP_DIR/future-launch.headers" -o /dev/null "$BASE_URL/launch?local=1" || fail "future launch route failed"
curl -fsS "$BASE_URL/broadcast" >"$TMP_DIR/future-broadcast.html" || fail "future broadcast route failed"
curl -fsS "$BASE_URL/local/delivery-log?limit=20" >"$TMP_DIR/future-delivery.json" || fail "future delivery fetch failed"

node - "$TMP_DIR/future-process.json" "$TMP_DIR/future-launch.headers" "$TMP_DIR/future-broadcast.html" "$TMP_DIR/future-delivery.json" "$TMP_DIR/data/current-broadcast.json" <<'NODE'
const fs = require("fs");
const [processPath, headersPath, htmlPath, deliveryPath, broadcastPath] = process.argv.slice(2);
const processed = JSON.parse(fs.readFileSync(processPath, "utf8"));
const headers = fs.readFileSync(headersPath, "utf8");
const html = fs.readFileSync(htmlPath, "utf8");
const delivery = JSON.parse(fs.readFileSync(deliveryPath, "utf8"));
const stored = JSON.parse(fs.readFileSync(broadcastPath, "utf8"));
function fail(message) { throw new Error(message); }
const result = processed.results.find(entry => entry.commandId === "cmd-future");
if (!result || !result.result || result.result.ok !== true || result.result.scheduled !== true) {
  fail("future broadcast was not accepted as scheduled");
}
if (!headers.includes("location: /frame") && !headers.includes("Location: /frame")) {
  fail("future broadcast interrupted launch before startsAt");
}
if (!html.includes("No active broadcast")) fail("future broadcast rendered before startsAt");
if (stored.id !== "broadcast-future" || stored.shownAt || stored.shownEventAt) fail("future broadcast was marked shown too early");
if (delivery.entries.some(entry => entry.eventType === "broadcast_shown")) fail("future broadcast wrote broadcast_shown too early");
NODE

queue_command "cmd-visible" visible
curl -fsS -X POST "$BASE_URL/local/commands/process" >"$TMP_DIR/visible-process.json" || fail "visible command processing failed"
curl -fsS "$BASE_URL/local/delivery-log?limit=20" >"$TMP_DIR/pre-display-delivery.json" || fail "pre-display delivery fetch failed"
curl -fsS -D "$TMP_DIR/visible-launch.headers" -o /dev/null "$BASE_URL/launch?local=1" || fail "visible launch route failed"
curl -fsS "$BASE_URL/broadcast" >"$TMP_DIR/visible-broadcast.html" || fail "visible broadcast route failed"
curl -fsS "$BASE_URL/local/delivery-log?limit=20" >"$TMP_DIR/post-display-delivery.json" || fail "post-display delivery fetch failed"

node - "$TMP_DIR/visible-process.json" "$TMP_DIR/pre-display-delivery.json" "$TMP_DIR/visible-launch.headers" "$TMP_DIR/visible-broadcast.html" "$TMP_DIR/post-display-delivery.json" "$TMP_DIR/data/current-broadcast.json" <<'NODE'
const fs = require("fs");
const [processPath, preDeliveryPath, headersPath, htmlPath, postDeliveryPath, broadcastPath] = process.argv.slice(2);
const processed = JSON.parse(fs.readFileSync(processPath, "utf8"));
const preDelivery = JSON.parse(fs.readFileSync(preDeliveryPath, "utf8"));
const headers = fs.readFileSync(headersPath, "utf8");
const html = fs.readFileSync(htmlPath, "utf8");
const postDelivery = JSON.parse(fs.readFileSync(postDeliveryPath, "utf8"));
const stored = JSON.parse(fs.readFileSync(broadcastPath, "utf8"));
function fail(message) { throw new Error(message); }
const result = processed.results.find(entry => entry.commandId === "cmd-visible");
if (!result || !result.result || result.result.ok !== true || result.result.scheduled !== false) {
  fail("visible broadcast command did not complete");
}
if (preDelivery.entries.some(entry => entry.eventType === "broadcast_shown" && entry.itemId === "broadcast-visible")) {
  fail("visible broadcast was marked shown before /broadcast rendered");
}
if (!headers.includes("location: /broadcast") && !headers.includes("Location: /broadcast")) {
  fail("active broadcast did not route launch to /broadcast");
}
if (!html.includes("Visible Broadcast") || html.includes("broadcast-command-check-secret")) {
  fail("broadcast page did not render the visible broadcast or leaked the device key");
}
const shown = postDelivery.entries.filter(entry => entry.eventType === "broadcast_shown" && entry.itemId === "broadcast-visible");
if (shown.length !== 1 || shown[0].commandId !== "cmd-visible") fail("broadcast_shown was not recorded exactly once on display");
if (!stored.shownAt || !stored.shownEventAt) fail("stored broadcast did not record display timestamps");
NODE

curl -fsS -X POST "$BASE_URL/local/broadcast/dismiss" >"$TMP_DIR/dismiss.json" || fail "dismiss request failed"
curl -fsS "$BASE_URL/broadcast" >"$TMP_DIR/dismissed-broadcast.html" || fail "dismissed broadcast route failed"
curl -fsS -D "$TMP_DIR/dismissed-launch.headers" -o /dev/null "$BASE_URL/launch?local=1" || fail "dismissed launch route failed"
curl -fsS "$BASE_URL/local/delivery-log?limit=20" >"$TMP_DIR/dismiss-delivery.json" || fail "dismiss delivery fetch failed"

node - "$TMP_DIR/dismiss.json" "$TMP_DIR/dismissed-broadcast.html" "$TMP_DIR/dismissed-launch.headers" "$TMP_DIR/dismiss-delivery.json" <<'NODE'
const fs = require("fs");
const [dismissPath, htmlPath, headersPath, deliveryPath] = process.argv.slice(2);
const dismissed = JSON.parse(fs.readFileSync(dismissPath, "utf8"));
const html = fs.readFileSync(htmlPath, "utf8");
const headers = fs.readFileSync(headersPath, "utf8");
const delivery = JSON.parse(fs.readFileSync(deliveryPath, "utf8"));
function fail(message) { throw new Error(message); }
if (!dismissed.ok || dismissed.broadcastId !== "broadcast-visible") fail("dismiss response did not name the visible broadcast");
if (!html.includes("No active broadcast")) fail("dismissed broadcast still rendered as active");
if (!headers.includes("location: /frame") && !headers.includes("Location: /frame")) {
  fail("dismissed broadcast still interrupted local launch");
}
if (!delivery.entries.some(entry => entry.eventType === "broadcast_dismissed" && entry.itemId === "broadcast-visible")) {
  fail("broadcast_dismissed was not recorded");
}
NODE

queue_command "cmd-expired" expired
curl -fsS -X POST "$BASE_URL/local/commands/process" >"$TMP_DIR/expired-process.json" || fail "expired command processing failed"
curl -fsS "$BASE_URL/local/commands/audit?limit=10" >"$TMP_DIR/expired-audit.json" || fail "expired audit fetch failed"
curl -fsS "$API_URL/__state" >"$TMP_DIR/mock-state.json" || fail "mock API state fetch failed"

node - "$TMP_DIR/expired-process.json" "$TMP_DIR/expired-audit.json" "$TMP_DIR/mock-state.json" <<'NODE'
const fs = require("fs");
const [processPath, auditPath, mockPath] = process.argv.slice(2);
const processed = JSON.parse(fs.readFileSync(processPath, "utf8"));
const audit = JSON.parse(fs.readFileSync(auditPath, "utf8"));
const mock = JSON.parse(fs.readFileSync(mockPath, "utf8"));
function fail(message) { throw new Error(message); }
const result = processed.results.find(entry => entry.commandId === "cmd-expired");
if (!result || !result.result || result.result.ok !== false || !String(result.result.error || "").includes("expired")) {
  fail("expired command was not rejected");
}
if (!audit.entries.some(entry => entry.commandId === "cmd-expired" && entry.status === "error")) {
  fail("expired command did not produce an audit error");
}
for (const commandId of ["cmd-wrong-target", "cmd-future", "cmd-visible", "cmd-expired"]) {
  const statuses = mock.acks.filter(entry => entry.commandId === commandId).map(entry => entry.status);
  if (!statuses.includes("acknowledged")) fail(commandId + " was not acknowledged");
}
if (!mock.acks.some(entry => entry.commandId === "cmd-visible" && entry.status === "completed")) {
  fail("visible command did not send completed acknowledgement");
}
if (!mock.acks.some(entry => entry.commandId === "cmd-expired" && entry.status === "error")) {
  fail("expired command did not send error acknowledgement");
}
NODE

echo "broadcast command check passed: command-delivered broadcasts respect targeting, scheduling, display-time delivery logs, dismissal, expiry, and command acknowledgements"
