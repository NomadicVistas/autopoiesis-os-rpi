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

PORT="${AUTOPOIESIS_FEED_TARGETING_CHECK_PORT:-$(pick_port)}"
API_PORT="${AUTOPOIESIS_FEED_TARGETING_CHECK_API_PORT:-$(pick_port)}"
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
  echo "feed targeting check failed: $*" >&2
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

mkdir -p "$TMP_DIR/data" "$TMP_DIR/log" "$TMP_DIR/cache"

node - "$TMP_DIR/data" "$API_URL/api" <<'NODE'
const fs = require("fs");
const dataDir = process.argv[2];
const apiBaseUrl = process.argv[3];

fs.writeFileSync(dataDir + "/device.json", JSON.stringify({
  deviceId: "rpi-feed-targeting-check",
  deviceName: "Feed Targeting Check Frame",
  ownerUserId: "user-feed-owner",
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
  deviceApiKey: "feed-targeting-check-secret"
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
  updatedAt: "2026-06-06T14:20:00.000Z"
}, null, 2) + "\n");

fs.writeFileSync(dataDir + "/pairing.json", JSON.stringify({
  pairingCode: "TARGET-1",
  mock: false,
  status: "paired"
}, null, 2) + "\n");
NODE

node - "$API_PORT" >"$TMP_DIR/api.log" 2>&1 <<'NODE' &
const http = require("http");
const port = Number(process.argv[2]);

function send(res, status, payload) {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(payload));
}

function streamItems() {
  return [
    {
      id: "art-device-ok",
      type: "artwork",
      title: "Targeted Work",
      artist: "Sandman",
      artistId: "sandman",
      mediaUrl: "https://example.test/targeted-work.jpg",
      cacheAllowed: true,
      priority: "normal",
      targeting: { deviceIds: ["rpi-feed-targeting-check"] }
    },
    {
      id: "art-device-blocked",
      type: "artwork",
      title: "Wrong Device",
      mediaUrl: "https://example.test/wrong-device.jpg",
      priority: "normal",
      targeting: { deviceIds: ["rpi-other-frame"] }
    },
    {
      id: "blog-user-ok",
      type: "blog",
      title: "Owner Note",
      body: "A private owner-targeted note.",
      priority: "normal",
      targeting: { targetType: "user", targetValue: "user-feed-owner" }
    },
    {
      id: "blog-user-blocked",
      type: "blog",
      title: "Wrong Owner",
      body: "This belongs to another owner.",
      priority: "normal",
      targeting: { targetType: "user", targetValue: "user-other" }
    },
    {
      id: "curatorial-sub-ok",
      type: "curatorial_announcement",
      title: "Subscriber Curatorial Note",
      body: "Shown to active subscribers.",
      priority: "high",
      targeting: { subscriptionStatuses: ["active", "trialing"] }
    },
    {
      id: "curatorial-sub-blocked",
      type: "curatorial_announcement",
      title: "Canceled Subscriber Note",
      body: "Should not display here.",
      priority: "high",
      targeting: { subscriptionStatuses: ["canceled"] }
    },
    {
      id: "news-tier-ok",
      type: "news",
      title: "Patron News",
      body: "Tier-targeted news.",
      priority: "normal",
      targeting: { targetType: "tier", value: "patron" }
    },
    {
      id: "news-region-ok",
      type: "news",
      title: "NL Update",
      body: "Regional note.",
      priority: "low",
      targeting: { regions: ["nl", "be"] }
    },
    {
      id: "art-excluded-device",
      type: "artwork",
      title: "Excluded Device",
      mediaUrl: "https://example.test/excluded-device.jpg",
      priority: "normal",
      targeting: { excludeDeviceIds: ["rpi-feed-targeting-check"] }
    },
    {
      id: "art-expired",
      type: "artwork",
      title: "Expired Work",
      mediaUrl: "https://example.test/expired.jpg",
      expiresAt: "2020-01-01T00:00:00.000Z",
      targeting: { deviceIds: ["rpi-feed-targeting-check"] }
    },
    {
      id: "art-future",
      type: "artwork",
      title: "Future Work",
      mediaUrl: "https://example.test/future.jpg",
      startsAt: "2099-01-01T00:00:00.000Z",
      targeting: { deviceIds: ["rpi-feed-targeting-check"] }
    },
    {
      id: "art-cache-disabled",
      type: "artwork",
      title: "Remote Only Work",
      mediaUrl: "https://example.test/remote-only.jpg",
      cacheAllowed: false,
      priority: "normal",
      targeting: { deviceIds: ["rpi-feed-targeting-check"] }
    }
  ];
}

http.createServer((req, res) => {
  const url = new URL(req.url, "http://127.0.0.1");
  if (req.method === "GET" && url.pathname === "/__health") return send(res, 200, { ok: true });
  if (req.method === "GET" && url.pathname.endsWith("/stream")) {
    return send(res, 200, {
      ok: true,
      schemaVersion: 1,
      generatedAt: "2026-06-06T14:25:00.000Z",
      stream: {
        profile: "living-stream",
        source: "targeting-check",
        polling: {
          pollAfterSeconds: 900,
          minPollSeconds: 300,
          maxPollSeconds: 3600,
          nextPollAt: "2026-06-06T14:40:00.000Z",
          staleAfter: "2026-06-06T15:25:00.000Z",
          reason: "targeting-check"
        }
      },
      items: streamItems(),
      broadcasts: [
        {
          id: "broadcast-device-ok",
          type: "emergency_notice",
          title: "Targeted Broadcast",
          body: "A high-priority broadcast for this device.",
          priority: "critical",
          duration: 20,
          targeting: { targetType: "device", targetValue: "rpi-feed-targeting-check" }
        },
        {
          id: "broadcast-device-blocked",
          type: "emergency_notice",
          title: "Wrong Broadcast",
          body: "This broadcast targets another device.",
          priority: "critical",
          targeting: { targetType: "device", targetValue: "rpi-other-frame" }
        }
      ]
    });
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

curl -fsS -X POST "$BASE_URL/local/feed/sync" >"$TMP_DIR/sync.json" || fail "feed sync failed"
curl -fsS "$BASE_URL/local/feed" >"$TMP_DIR/feed.json" || fail "local feed request failed"
curl -fsS "$BASE_URL/local/diagnostics" >"$TMP_DIR/diagnostics.json" || fail "diagnostics request failed"
curl -fsS "$BASE_URL/local/frame-state" >"$TMP_DIR/frame-state.json" || fail "frame-state request failed"
curl -fsS -X POST -H "content-type: application/json" -d '{"itemId":"broadcast-device-ok"}' "$BASE_URL/local/frame/display" >"$TMP_DIR/display.json" || fail "broadcast display acknowledgement failed"
curl -fsS "$BASE_URL/local/delivery-log?limit=10" >"$TMP_DIR/delivery.json" || fail "delivery-log request failed"
curl -fsS "$BASE_URL/local/events/export?limit=10" >"$TMP_DIR/events.json" || fail "events export request failed"
if [[ ! -f "$TMP_DIR/data/feed-cache.json" ]]; then
  echo "--- sync response ---" >&2
  cat "$TMP_DIR/sync.json" >&2 || true
  echo >&2
  echo "--- feed response ---" >&2
  cat "$TMP_DIR/feed.json" >&2 || true
  echo >&2
  fail "feed cache manifest was not written"
fi

node - "$TMP_DIR/sync.json" "$TMP_DIR/feed.json" "$TMP_DIR/diagnostics.json" "$TMP_DIR/frame-state.json" "$TMP_DIR/display.json" "$TMP_DIR/delivery.json" "$TMP_DIR/events.json" "$TMP_DIR/data/feed-cache.json" <<'NODE'
const fs = require("fs");
const [syncPath, feedPath, diagnosticsPath, framePath, displayPath, deliveryPath, eventsPath, cachePath] = process.argv.slice(2);
const sync = JSON.parse(fs.readFileSync(syncPath, "utf8"));
const feed = JSON.parse(fs.readFileSync(feedPath, "utf8"));
const diagnostics = JSON.parse(fs.readFileSync(diagnosticsPath, "utf8"));
const frame = JSON.parse(fs.readFileSync(framePath, "utf8"));
const display = JSON.parse(fs.readFileSync(displayPath, "utf8"));
const delivery = JSON.parse(fs.readFileSync(deliveryPath, "utf8"));
const events = JSON.parse(fs.readFileSync(eventsPath, "utf8"));
const cache = JSON.parse(fs.readFileSync(cachePath, "utf8"));

function fail(message) {
  throw new Error(message);
}

const visibleIds = new Set(feed.displayQueue.map(item => item.id));
const expectedVisible = [
  "broadcast-device-ok",
  "curatorial-sub-ok",
  "art-device-ok",
  "blog-user-ok",
  "news-tier-ok",
  "news-region-ok",
  "art-cache-disabled"
];
const expectedHidden = [
  "broadcast-device-blocked",
  "art-device-blocked",
  "blog-user-blocked",
  "curatorial-sub-blocked",
  "art-excluded-device",
  "art-expired",
  "art-future"
];

if (sync.endpoint !== "stream") fail("feed sync did not use stream endpoint");
if (sync.totalItems !== 14) fail("unexpected normalized item count: " + sync.totalItems);
if (!sync.polling || sync.polling.pollAfterSeconds !== 900 || sync.polling.nextPollAt !== "2026-06-06T14:40:00.000Z") {
  fail("feed sync response did not preserve stream polling cadence");
}
if (!feed.polling || feed.polling.minPollSeconds !== 300 || feed.polling.maxPollSeconds !== 3600) {
  fail("public local feed did not expose redacted stream polling bounds");
}
if (!diagnostics.diagnostics || !diagnostics.diagnostics.feed || !diagnostics.diagnostics.feed.polling || diagnostics.diagnostics.feed.polling.staleAfter !== "2026-06-06T15:25:00.000Z") {
  fail("diagnostics did not include stream polling freshness metadata");
}
for (const id of expectedVisible) {
  if (!visibleIds.has(id)) fail("expected targeted item missing: " + id);
}
for (const id of expectedHidden) {
  if (visibleIds.has(id)) fail("non-targeted or inactive item was displayed: " + id);
}
if (feed.displayQueue[0].id !== "broadcast-device-ok") fail("critical targeted broadcast was not first in the display queue");
if (feed.displayQueue[1].id !== "curatorial-sub-ok") fail("high-priority curatorial item did not follow the critical broadcast");
if (feed.items.some(item => Object.prototype.hasOwnProperty.call(item, "visibility"))) fail("public feed leaked targeting visibility");
if (frame.items.some(item => item.id === "broadcast-device-blocked")) fail("frame-state included blocked broadcast");
if (frame.items.some(item => item.id === "art-expired" || item.id === "art-future")) fail("frame-state included expired or future item");
if (!frame.playback || frame.playback.ready !== true) fail("frame playback was not ready for targeted playable items");
if (!display.ok || display.itemId !== "broadcast-device-ok" || display.eventType !== "broadcast_shown") {
  fail("mixed-stream broadcast display acknowledgement did not return broadcast_shown");
}

const cacheIds = new Set((cache.items || []).map(item => item.id));
if (!cacheIds.has("art-device-ok")) fail("cache manifest missed targeted cache-eligible artwork");
if (cacheIds.has("art-cache-disabled")) fail("cache manifest included cacheAllowed=false item");
if (cacheIds.has("art-device-blocked") || cacheIds.has("art-expired") || cacheIds.has("art-future")) {
  fail("cache manifest included blocked, expired, or future item");
}

const synced = delivery.entries.find(entry => entry.eventType === "feed_synced");
if (!synced) fail("delivery log missed feed_synced event");
if (synced.pollAfterSeconds !== 900 || synced.nextPollAt !== "2026-06-06T14:40:00.000Z") {
  fail("feed_synced delivery evidence did not include polling cadence");
}
if (!synced.categories || synced.categories.broadcast !== 1 || synced.categories.artwork !== 2) {
  fail("feed_synced category counts did not reflect eligible mixed stream");
}
const shown = delivery.entries.find(entry => entry.eventType === "broadcast_shown" && entry.itemId === "broadcast-device-ok");
if (!shown) fail("mixed-stream broadcast display did not write broadcast_shown delivery evidence");
if (delivery.entries.some(entry => entry.eventType === "feed_item_shown" && entry.itemId === "broadcast-device-ok")) {
  fail("mixed-stream broadcast display was logged as a generic feed item");
}
const exported = (events.events || []).find(entry => entry.source === "display_delivery" && entry.eventType === "broadcast_shown" && entry.itemId === "broadcast-device-ok");
if (!exported) fail("events export did not expose mixed-stream broadcast_shown evidence");
if (exported.itemSource !== "broadcast") fail("mixed-stream broadcast event did not preserve broadcast source");
NODE

echo "feed targeting check passed: local stream targeting, expiry/start filtering, priority order, polling metadata, public redaction, broadcast display evidence, and cache eligibility are coherent"
