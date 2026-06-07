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

PORT="${AUTOPOIESIS_FEED_CURSOR_CHECK_PORT:-$(pick_port)}"
API_PORT="${AUTOPOIESIS_FEED_CURSOR_CHECK_API_PORT:-$(pick_port)}"
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
  echo "feed cursor check failed: $*" >&2
  if [[ -f "$TMP_DIR/server.log" ]]; then
    echo "--- local-ui log ---" >&2
    sed -n '1,180p' "$TMP_DIR/server.log" >&2
  fi
  exit 1
}

mkdir -p "$TMP_DIR/data" "$TMP_DIR/log" "$TMP_DIR/cache"

# --- Seed device, preferences, pairing ---
node - "$TMP_DIR/data" "$API_URL/api" <<'NODE'
const fs = require("fs");
const dataDir = process.argv[2];
const apiBaseUrl = process.argv[3];

fs.writeFileSync(dataDir + "/device.json", JSON.stringify({
  deviceId: "rpi-feed-cursor-check",
  deviceName: "Feed Cursor Check Frame",
  ownerUserId: "user-cursor-owner",
  paired: true,
  firstRunComplete: true,
  onboardingComplete: true,
  remoteEnabled: true,
  apiBaseUrl,
  framesUrl: "http://127.0.0.1:1/display",
  deviceApiKey: "feed-cursor-check-secret"
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
  pairingCode: "CURSOR-1",
  mock: false,
  status: "paired"
}, null, 2) + "\n");
NODE

# --- Mock hosted API ---
node - "$API_PORT" >"$TMP_DIR/api.log" 2>&1 <<'NODE' &
const http = require("http");
const port = Number(process.argv[2]);
let streamVersion = 1;

function send(res, status, payload) {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(payload));
}

function streamItems(version) {
  const base = [
    { id: "art-1", type: "artwork", title: "First Art", mediaUrl: "https://example.test/art1.jpg", cacheAllowed: true, priority: "normal" },
    { id: "art-2", type: "artwork", title: "Second Art", mediaUrl: "https://example.test/art2.jpg", cacheAllowed: true, priority: "normal" },
    { id: "art-3", type: "artwork", title: "Third Art", mediaUrl: "https://example.test/art3.jpg", cacheAllowed: true, priority: "normal" },
    { id: "blog-1", type: "blog", title: "Blog Post", body: "A blog note.", priority: "low" },
    { id: "broadcast-1", type: "curatorial_announcement", title: "Curatorial Note", body: "High priority.", priority: "high" }
  ];
  if (version >= 2) {
    base.push({ id: "art-4-new", type: "artwork", title: "New Art After Sync", mediaUrl: "https://example.test/art4.jpg", cacheAllowed: true, priority: "normal" });
    base.push({ id: "news-1-new", type: "news", title: "Fresh News", body: "Breaking.", priority: "normal" });
  }
  return base;
}

http.createServer((req, res) => {
  const url = new URL(req.url, "http://127.0.0.1");
  if (req.method === "GET" && url.pathname === "/__health") return send(res, 200, { ok: true });
  if (req.method === "POST" && url.pathname === "/__bump-version") { streamVersion += 1; return send(res, 200, { ok: true, streamVersion }); }
  if (req.method === "POST" && url.pathname.endsWith("/heartbeat")) {
    return send(res, 200, { ok: true, commands: [] });
  }
  if (req.method === "GET" && url.pathname.endsWith("/stream")) {
    return send(res, 200, {
      ok: true,
      schemaVersion: 1,
      generatedAt: "2026-06-06T14:25:00.000Z",
      stream: { profile: "living-stream", source: "cursor-check" },
      polling: { pollAfterSeconds: 900, minPollSeconds: 300, staleAfter: "2026-06-06T15:25:00.000Z" },
      items: streamItems(streamVersion)
    });
  }
  return send(res, 404, { error: "not_found", path: url.pathname });
}).listen(port, "127.0.0.1");
NODE
API_PID="$!"

for _ in {1..50}; do
  if curl -fsS "$API_URL/__health" >/dev/null 2>&1; then break; fi
  sleep 0.1
done
curl -fsS "$API_URL/__health" >/dev/null || fail "mock Frames API did not start"

# --- Start local UI ---
AUTOPOIESIS_DATA_DIR="$TMP_DIR/data" \
AUTOPOIESIS_LOG_DIR="$TMP_DIR/log" \
AUTOPOIESIS_CACHE_DIR="$TMP_DIR/cache" \
AUTOPOIESIS_PORT="$PORT" \
AUTOPOIESIS_API_TIMEOUT_MS=800 \
AUTOPOIESIS_LAUNCH_PROBE_TIMEOUT_MS=100 \
  node "$ROOT_DIR/local-ui/server.js" >"$TMP_DIR/server.log" 2>&1 &
SERVER_PID="$!"

for _ in {1..50}; do
  if curl -fsS "$BASE_URL/local/status" >/dev/null 2>&1; then break; fi
  sleep 0.1
done
curl -fsS "$BASE_URL/local/status" >/dev/null || fail "local UI did not start"

# --- Step 1: Initial sync should create cursor ---
curl -fsS -X POST "$BASE_URL/local/feed/sync" >"$TMP_DIR/sync1.json" || fail "initial feed sync failed"
curl -fsS "$BASE_URL/local/feed" >"$TMP_DIR/feed1.json" || fail "initial feed request failed"
curl -fsS "$BASE_URL/local/frame-state" >"$TMP_DIR/frame1.json" || fail "initial frame-state request failed"
curl -fsS "$BASE_URL/local/diagnostics" >"$TMP_DIR/diag1.json" || fail "initial diagnostics request failed"

node - "$TMP_DIR/sync1.json" "$TMP_DIR/feed1.json" "$TMP_DIR/frame1.json" "$TMP_DIR/diag1.json" <<'NODE'
const fs = require("fs");
const [syncPath, feedPath, framePath, diagPath] = process.argv.slice(2);
const sync = JSON.parse(fs.readFileSync(syncPath, "utf8"));
const feed = JSON.parse(fs.readFileSync(feedPath, "utf8"));
const frame = JSON.parse(fs.readFileSync(framePath, "utf8"));
const diag = JSON.parse(fs.readFileSync(diagPath, "utf8"));

function fail(message) { throw new Error(message); }

if (!sync.ok || sync.endpoint !== "stream") fail("initial sync did not report stream success");
if (!feed.displayCursor) fail("public feed missing displayCursor");
if (feed.displayCursor.shownCount !== 0) fail("initial displayCursor should show 0 shown items, got " + feed.displayCursor.shownCount);
if (!feed.displayCursor.syncedAt) fail("initial displayCursor missing syncedAt");
if (!frame.displayCursor) fail("frame-state missing displayCursor");
if (frame.displayCursor.shownCount !== 0) fail("frame displayCursor should show 0 shown items");
if (!diag.diagnostics.feed.displayCursor) fail("diagnostics missing feed.displayCursor");
if (diag.diagnostics.feed.displayCursor.shownCount !== 0) fail("diagnostics displayCursor shownCount should be 0");

// Verify priority ordering: broadcast-1 (high) > art-1,2,3 (normal) > blog-1 (low)
const ids = feed.displayQueue.map(item => item.id);
const broadcastIdx = ids.indexOf("broadcast-1");
const art1Idx = ids.indexOf("art-1");
const blogIdx = ids.indexOf("blog-1");
if (broadcastIdx === -1) fail("high-priority curatorial missing from display queue");
if (blogIdx === -1) fail("low-priority blog missing from display queue");
if (broadcastIdx > art1Idx) fail("high-priority broadcast should come before normal artwork");
if (art1Idx > blogIdx) fail("normal artwork should come before low-priority blog");

console.log("step 1 passed: initial sync creates cursor, display queue priority order correct");
NODE

# --- Step 2: Display first two items, verify cursor tracks them ---
curl -fsS -X POST -H "content-type: application/json" -d '{"itemId":"art-1"}' "$BASE_URL/local/frame/display" >"$TMP_DIR/display1.json" || fail "display art-1 failed"
curl -fsS -X POST -H "content-type: application/json" -d '{"itemId":"art-2"}' "$BASE_URL/local/frame/display" >"$TMP_DIR/display2.json" || fail "display art-2 failed"

curl -fsS "$BASE_URL/local/feed" >"$TMP_DIR/feed2.json" || fail "feed after display failed"

node - "$TMP_DIR/display1.json" "$TMP_DIR/display2.json" "$TMP_DIR/feed2.json" <<'NODE'
const fs = require("fs");
const [d1Path, d2Path, feedPath] = process.argv.slice(2);
const d1 = JSON.parse(fs.readFileSync(d1Path, "utf8"));
const d2 = JSON.parse(fs.readFileSync(d2Path, "utf8"));
const feed = JSON.parse(fs.readFileSync(feedPath, "utf8"));

function fail(message) { throw new Error(message); }

if (!d1.ok || d1.eventType !== "feed_item_shown") fail("art-1 display did not return feed_item_shown");
if (!d2.ok || d2.eventType !== "feed_item_shown") fail("art-2 display did not return feed_item_shown");
if (!feed.displayCursor || feed.displayCursor.shownCount !== 2) fail("cursor should show 2 items, got " + (feed.displayCursor ? feed.displayCursor.shownCount : "null"));

// Verify unshown items come before shown items in the display queue
const ids = feed.displayQueue.map(item => item.id);
const art1Idx = ids.indexOf("art-1");
const art2Idx = ids.indexOf("art-2");
const art3Idx = ids.indexOf("art-3");
const broadcastIdx = ids.indexOf("broadcast-1");
const blogIdx = ids.indexOf("blog-1");

if (art1Idx === -1 || art2Idx === -1 || art3Idx === -1) fail("all artworks should be in queue");
// broadcast-1 is high priority so always comes first
// Among normal items: art-3 (not shown) should come before art-1 and art-2 (shown)
const normalItems = ids.filter(id => !["broadcast-1", "blog-1"].includes(id));
const art3NormalIdx = normalItems.indexOf("art-3");
const art1NormalIdx = normalItems.indexOf("art-1");
const art2NormalIdx = normalItems.indexOf("art-2");
if (art3NormalIdx === -1) fail("art-3 missing from normal items");
if (art3NormalIdx > art1NormalIdx) fail("unshown art-3 should come before shown art-1 in normal band");
if (art3NormalIdx > art2NormalIdx) fail("unshown art-3 should come before shown art-2 in normal band");

console.log("step 2 passed: cursor tracks shown items, unshown items come first in display queue");
NODE

# --- Step 3: Re-display same items - cursor should not double-count ---
curl -fsS -X POST -H "content-type: application/json" -d '{"itemId":"art-1"}' "$BASE_URL/local/frame/display" >"$TMP_DIR/display1b.json" || fail "re-display art-1 failed"

curl -fsS "$BASE_URL/local/feed" >"$TMP_DIR/feed3.json" || fail "feed after re-display failed"

node - "$TMP_DIR/feed3.json" <<'NODE'
const fs = require("fs");
const feed = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));

function fail(message) { throw new Error(message); }

if (!feed.displayCursor || feed.displayCursor.shownCount !== 2) fail("cursor should still show 2 items after re-display, got " + (feed.displayCursor ? feed.displayCursor.shownCount : "null"));

console.log("step 3 passed: re-displaying same item does not inflate cursor count");
NODE

# --- Step 4: Re-sync resets the cursor and new items appear fresh ---
# Bump mock API to add new items
curl -fsS -X POST "$API_URL/__bump-version" >/dev/null || fail "mock version bump failed"

curl -fsS -X POST "$BASE_URL/local/feed/sync" >"$TMP_DIR/sync2.json" || fail "second feed sync failed"
curl -fsS "$BASE_URL/local/feed" >"$TMP_DIR/feed4.json" || fail "feed after re-sync failed"
curl -fsS "$BASE_URL/local/frame-state" >"$TMP_DIR/frame2.json" || fail "frame-state after re-sync failed"
curl -fsS "$BASE_URL/local/diagnostics" >"$TMP_DIR/diag2.json" || fail "diagnostics after re-sync failed"

node - "$TMP_DIR/sync2.json" "$TMP_DIR/feed4.json" "$TMP_DIR/frame2.json" "$TMP_DIR/diag2.json" <<'NODE'
const fs = require("fs");
const [syncPath, feedPath, framePath, diagPath] = process.argv.slice(2);
const sync = JSON.parse(fs.readFileSync(syncPath, "utf8"));
const feed = JSON.parse(fs.readFileSync(feedPath, "utf8"));
const frame = JSON.parse(fs.readFileSync(framePath, "utf8"));
const diag = JSON.parse(fs.readFileSync(diagPath, "utf8"));

function fail(message) { throw new Error(message); }

if (!sync.ok) fail("second sync should succeed");
// Cursor should be reset after re-sync
if (!feed.displayCursor) fail("feed missing displayCursor after re-sync");
if (feed.displayCursor.shownCount !== 0) fail("cursor should be reset to 0 after re-sync, got " + feed.displayCursor.shownCount);
if (feed.displayCursor.syncedAt !== feed.syncedAt) fail("cursor syncedAt should match feed syncedAt");

// New items should be present
const ids = feed.displayQueue.map(item => item.id);
if (!ids.includes("art-4-new")) fail("new artwork missing from display queue after re-sync");
if (!ids.includes("news-1-new")) fail("new news item missing from display queue after re-sync");

// All items should have equal footing (no shown bias) since cursor reset
if (!frame.displayCursor || frame.displayCursor.shownCount !== 0) fail("frame displayCursor should also be reset");
if (!diag.diagnostics.feed.displayCursor || diag.diagnostics.feed.displayCursor.shownCount !== 0) fail("diagnostics cursor should be reset");
if (diag.diagnostics.feed.displayCursor.syncedAt !== feed.displayCursor.syncedAt) fail("diagnostics cursor syncedAt should match feed");

console.log("step 4 passed: re-sync resets cursor, all items start fresh including new items");
NODE

# --- Step 5: Support bundle includes cursor ---
curl -fsS "$BASE_URL/local/support-bundle?services=0&limit=5" >"$TMP_DIR/support.json" || fail "support-bundle request failed"

node - "$TMP_DIR/support.json" <<'NODE'
const fs = require("fs");
const support = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));

function fail(message) { throw new Error(message); }

if (!support.summary) fail("support bundle missing summary");
if (!support.summary.feedCursor) fail("support bundle summary missing feedCursor");
if (typeof support.summary.feedCursor.shownCount !== "number") fail("support bundle feedCursor.shownCount missing");

console.log("step 5 passed: support bundle includes feed cursor summary");
NODE

echo "feed cursor check passed: cursor creation, shown tracking, display queue reordering, re-sync reset, diagnostics, and support bundle propagation are coherent"
