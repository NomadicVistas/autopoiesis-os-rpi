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

PORT="${AUTOPOIESIS_STREAM_PLAYBACK_CHECK_PORT:-$(pick_port)}"
API_PORT="${AUTOPOIESIS_STREAM_PLAYBACK_CHECK_API_PORT:-$(pick_port)}"
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
  echo "stream playback check failed: $*" >&2
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
  deviceId: "rpi-stream-playback-check",
  deviceName: "Stream Playback Check Frame",
  paired: true,
  firstRunComplete: true,
  onboardingComplete: true,
  remoteEnabled: true,
  apiBaseUrl,
  framesUrl: "http://127.0.0.1:1/display",
  deviceApiKey: "stream-playback-check-secret"
}, null, 2) + "\n");

fs.writeFileSync(dataDir + "/preferences.json", JSON.stringify({
  language: "en",
  displayMode: "local-feed",
  streamProfile: "artist-focus",
  activeArtists: ["sandman"],
  streamCategories: ["artwork", "blog"],
  allowImages: true,
  allowVideos: true,
  allowSoundWorks: true,
  allowGenerativeWorks: true,
  autoplay: true,
  videoAutoplay: true,
  soundAutoplay: true,
  soundEnabled: true,
  volume: 55,
  imageDuration: 12,
  showArtworkInfoOnTap: true,
  updatedAt: "2026-06-06T13:10:00.000Z"
}, null, 2) + "\n");

fs.writeFileSync(dataDir + "/pairing.json", JSON.stringify({
  pairingCode: "STREAM-1",
  mock: false,
  status: "paired"
}, null, 2) + "\n");
NODE

node - "$API_PORT" >"$TMP_DIR/api.log" 2>&1 <<'NODE' &
const http = require("http");
const port = Number(process.argv[2]);
let streamAvailable = true;
const calls = [];
const likes = [];

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

function streamItems() {
  return [
    {
      id: "art-sandman",
      type: "artwork",
      title: "Recursive Dusk",
      artist: "Sandman",
      artistId: "sandman",
      mediaUrl: "https://example.test/recursive-dusk.jpg",
      infoUrl: "https://autopoiesis.art/artworks/art-sandman",
      exhibitionUrl: "https://autopoiesis.art/exhibitions/dream-systems",
      cacheAllowed: true,
      priority: "normal"
    },
    {
      id: "video-sandman",
      type: "video",
      title: "Nocturne Loop",
      artist: "Sandman",
      artistId: "sandman",
      mediaUrl: "https://example.test/nocturne.mp4",
      durationSeconds: 7,
      cacheAllowed: true,
      priority: "normal"
    },
    {
      id: "blog-sandman",
      type: "blog",
      title: "Dream Systems Note",
      artist: "Sandman",
      artistId: "sandman",
      body: "A short curatorial note for the local dashboard.",
      blogUrl: "https://autopoiesis.art/blog/dream-systems",
      cacheAllowed: false,
      priority: "low"
    },
    {
      id: "art-vessel",
      type: "artwork",
      title: "Cell Boundary",
      artist: "Vessel",
      artistId: "vessel",
      mediaUrl: "https://example.test/cell-boundary.jpg",
      cacheAllowed: true,
      priority: "normal"
    },
    {
      id: "news-sandman",
      type: "news",
      title: "System News",
      artist: "Sandman",
      artistId: "sandman",
      body: "Filtered by stream category.",
      cacheAllowed: false,
      priority: "normal"
    }
  ];
}

http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://127.0.0.1");
  calls.push({ method: req.method, path: url.pathname });
  if (req.method === "GET" && url.pathname === "/__health") return send(res, 200, { ok: true });
  if (req.method === "GET" && url.pathname === "/__state") return send(res, 200, { calls, likes, streamAvailable });
  if (req.method === "POST" && url.pathname === "/__stream-mode") {
    const body = await readBody(req);
    streamAvailable = body.available !== false;
    return send(res, 200, { ok: true, streamAvailable });
  }
  if (req.method === "GET" && url.pathname.endsWith("/stream")) {
    if (!streamAvailable) return send(res, 404, { error: "stream_unavailable" });
    return send(res, 200, {
      ok: true,
      schemaVersion: 1,
      generatedAt: "2026-06-06T13:15:00.000Z",
      stream: { profile: "artist-focus", source: "mock-stream" },
      settings: {
        streamProfile: "artist-focus",
        activeArtists: ["sandman"],
        streamCategories: ["artwork", "blog"],
        imageDuration: 12,
        updatedAt: "2026-06-06T13:15:00.000Z"
      },
      items: streamItems()
    });
  }
  if (req.method === "GET" && url.pathname.endsWith("/feed")) {
    return send(res, 200, {
      ok: true,
      generatedAt: "2026-06-06T13:16:00.000Z",
      items: [{
        id: "legacy-art-sandman",
        type: "artwork",
        title: "Legacy Dream",
        artist: "Sandman",
        artistId: "sandman",
        mediaUrl: "https://example.test/legacy-dream.jpg",
        cacheAllowed: true
      }]
    });
  }
  const likeMatch = url.pathname.match(/\/frames\/artworks\/([^/]+)\/like$/);
  if (req.method === "POST" && likeMatch) {
    const body = await readBody(req);
    likes.push({ artworkId: decodeURIComponent(likeMatch[1]), body });
    return send(res, 200, { ok: true, liked: true });
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

curl -fsS -X POST "$BASE_URL/local/feed/sync" >"$TMP_DIR/stream-sync.json" || fail "stream feed sync failed"
curl -fsS "$BASE_URL/local/feed" >"$TMP_DIR/feed.json" || fail "local feed request failed"
curl -fsS "$BASE_URL/local/frame-state" >"$TMP_DIR/frame-state.json" || fail "frame-state request failed"
curl -fsS "$BASE_URL/dashboard" >"$TMP_DIR/dashboard.html" || fail "dashboard request failed"
curl -fsS "$BASE_URL/frame" >"$TMP_DIR/frame.html" || fail "frame request failed"

node - "$TMP_DIR/stream-sync.json" "$TMP_DIR/feed.json" "$TMP_DIR/frame-state.json" "$TMP_DIR/dashboard.html" "$TMP_DIR/frame.html" <<'NODE'
const fs = require("fs");
const [syncPath, feedPath, framePath, dashboardPath, frameHtmlPath] = process.argv.slice(2);
const sync = JSON.parse(fs.readFileSync(syncPath, "utf8"));
const feed = JSON.parse(fs.readFileSync(feedPath, "utf8"));
const frame = JSON.parse(fs.readFileSync(framePath, "utf8"));
const dashboard = fs.readFileSync(dashboardPath, "utf8");
const frameHtml = fs.readFileSync(frameHtmlPath, "utf8");

function fail(message) {
  throw new Error(message);
}

if (sync.endpoint !== "stream" || sync.fallbackReason) fail("feed sync did not prefer the stream endpoint");
if (!Array.isArray(feed.items) || !Array.isArray(feed.displayQueue)) fail("public feed shape is incomplete");
const frameIds = frame.items.map(item => item.id);
if (!frameIds.includes("art-sandman")) fail("allowed artwork missing from frame queue");
if (!frameIds.includes("video-sandman")) fail("allowed video missing from frame queue");
if (!frameIds.includes("blog-sandman")) fail("allowed blog missing from frame queue");
if (frameIds.includes("art-vessel")) fail("artist preference filter did not remove Vessel item");
if (frameIds.includes("news-sandman")) fail("stream category filter did not remove news item");
if (frame.items.some(item => !Number.isFinite(Number(item.displayMs)) || Number(item.displayMs) <= 0)) fail("frame item displayMs is missing");
const imageItem = frame.items.find(item => item.id === "art-sandman");
const videoItem = frame.items.find(item => item.id === "video-sandman");
if (!imageItem || Number(imageItem.displayMs) !== 12000) fail("image displayMs did not follow preferences.imageDuration");
if (!videoItem || Number(videoItem.displayMs) !== 7000) fail("video displayMs did not follow item durationSeconds");
if (!frame.playback || frame.playback.ready !== true) fail("frame playback readiness is not true for playable stream items");
if (!dashboard.includes("Playable stream items") || !dashboard.includes("artist-focus")) fail("dashboard did not expose stream status");
if (!frameHtml.includes("/local/frame/like") || frameHtml.includes("stream-playback-check-secret")) fail("frame HTML missing like action or leaked device key");
NODE

curl -fsS -X POST "$BASE_URL/local/frame/like" \
  -H 'content-type: application/json' \
  -d '{"itemId":"art-sandman"}' >"$TMP_DIR/like.json" || fail "frame like request failed"
curl -fsS "$BASE_URL/local/delivery-log?limit=10" >"$TMP_DIR/delivery.json" || fail "delivery log request failed"
curl -fsS "$BASE_URL/local/frame-state" >"$TMP_DIR/liked-frame-state.json" || fail "liked frame-state request failed"
curl -fsS "$API_URL/__state" >"$TMP_DIR/mock-state.json" || fail "mock API state request failed"

node - "$TMP_DIR/like.json" "$TMP_DIR/delivery.json" "$TMP_DIR/liked-frame-state.json" "$TMP_DIR/mock-state.json" "$TMP_DIR/data/state.json" <<'NODE'
const fs = require("fs");
const [likePath, deliveryPath, framePath, mockPath, statePath] = process.argv.slice(2);
const like = JSON.parse(fs.readFileSync(likePath, "utf8"));
const delivery = JSON.parse(fs.readFileSync(deliveryPath, "utf8"));
const frame = JSON.parse(fs.readFileSync(framePath, "utf8"));
const mock = JSON.parse(fs.readFileSync(mockPath, "utf8"));
const state = JSON.parse(fs.readFileSync(statePath, "utf8"));

function fail(message) {
  throw new Error(message);
}

if (!like.ok || like.itemId !== "art-sandman" || like.remote.ok !== true) fail("like response did not confirm local and remote like");
if (!Array.isArray(state.likedArtworkIds) || !state.likedArtworkIds.includes("art-sandman")) fail("local liked artwork state was not persisted");
if (!frame.items.find(item => item.id === "art-sandman" && item.liked === true)) fail("liked frame-state did not mark the item liked");
if (!delivery.entries.some(entry => entry.eventType === "feed_item_liked" && entry.itemId === "art-sandman")) fail("delivery log did not record feed_item_liked");
if (!mock.likes.some(entry => entry.artworkId === "art-sandman" && entry.body.deviceId === "rpi-stream-playback-check")) fail("mock API did not receive artwork like");
NODE

curl -fsS -X POST "$API_URL/__stream-mode" \
  -H 'content-type: application/json' \
  -d '{"available":false}' >/dev/null || fail "mock stream mode update failed"
curl -fsS -X POST "$BASE_URL/local/feed/sync" >"$TMP_DIR/fallback-sync.json" || fail "fallback feed sync failed"
curl -fsS "$BASE_URL/local/frame-state" >"$TMP_DIR/fallback-frame-state.json" || fail "fallback frame-state request failed"

node - "$TMP_DIR/fallback-sync.json" "$TMP_DIR/fallback-frame-state.json" "$TMP_DIR/mock-state.json" <<'NODE'
const fs = require("fs");
const [syncPath, framePath] = process.argv.slice(2);
const sync = JSON.parse(fs.readFileSync(syncPath, "utf8"));
const frame = JSON.parse(fs.readFileSync(framePath, "utf8"));
if (sync.endpoint !== "feed" || !sync.fallbackReason) throw new Error("legacy feed fallback was not reported");
if (!frame.items.some(item => item.id === "legacy-art-sandman")) throw new Error("legacy feed fallback item did not reach frame-state");
NODE

echo "stream playback check passed: stream sync, preference filtering, dashboard, player timing, like forwarding, and legacy feed fallback are coherent"
