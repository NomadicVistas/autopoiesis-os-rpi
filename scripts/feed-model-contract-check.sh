#!/usr/bin/env bash
# feed-model-contract-check.sh
# Validates the content feed model contract: normalized item shape, content type
# classification, eligibility pipeline, mixed queue composition, cache eligibility,
# priority ranking, expiry/scheduling, and per-category display timing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVER="$REPO_DIR/local-ui/server.js"

PASS=0
FAIL=0
TOTAL=0

ok()   { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "  ✗ FAIL: $1"; }

echo "=== Feed Model Contract Check ==="
echo ""

# ── Step 1: Syntax validation ────────────────────────────────────────────
echo "Step 1: Syntax validation"
node --check "$SERVER" 2>/dev/null && ok "local-ui/server.js syntax" || fail "local-ui/server.js syntax error"
bash -n "$0" 2>/dev/null && ok "self syntax" || fail "self syntax error"
echo ""

# ── Step 2: Normalized feed item shape ───────────────────────────────────
echo "Step 2: Normalized feed item shape (required fields)"
node - "$SERVER" <<'NODE'
const fs = require("fs");
const vm = require("vm");

const src = fs.readFileSync(process.argv[2], "utf8");

// Extract normalizeFeedItem and dependencies via eval in isolated scope
let pass = 0, fail = 0, total = 0;
const ok = (m) => { total++; pass++; console.log("  ✓ " + m); };
const fl = (m) => { total++; fail++; console.log("  ✗ FAIL: " + m); };

// We just need to parse the function text and verify it returns the expected fields
const fnMatch = src.match(/function normalizeFeedItem\(raw,\s*source,\s*index/);
if (!fnMatch) { fl("normalizeFeedItem function found"); process.exit(1); }
ok("normalizeFeedItem function found");

// Extract the return block to verify all required fields are present
const returnIdx = src.indexOf("return {", src.indexOf("function normalizeFeedItem"));
const closingIdx = src.indexOf("};", returnIdx);
const returnBlock = src.substring(returnIdx, closingIdx + 2);

const requiredFields = [
  "id", "source", "type", "title", "artist", "artistId", "body",
  "url", "mediaUrl", "thumbnailUrl", "duration", "soundRequired",
  "cacheAllowed", "priority", "visibility", "createdAt", "startsAt",
  "expiresAt", "dismissible", "order"
];

for (const field of requiredFields) {
  if (returnBlock.includes(field + ":") || returnBlock.includes(field + " ||") || returnBlock.includes(field + ")") || returnBlock.includes(",\n    " + field + ",") || returnBlock.includes("\n    " + field + ",")) {
    ok("normalizeFeedItem output includes '" + field + "'");
  } else {
    fl("normalizeFeedItem output missing '" + field + "'");
  }
}

// Verify id is always a string
if (returnBlock.includes("String(id)")) {
  ok("normalizeFeedItem coerces id to String");
} else {
  fl("normalizeFeedItem should coerce id to String");
}

// Verify null items are rejected
if (src.includes("if (!raw || typeof raw !== \"object\") return null;")) {
  ok("normalizeFeedItem rejects null/non-object input");
} else {
  fl("normalizeFeedItem should reject null/non-object input");
}

// Verify missing id returns null
if (src.match(/if\s*\(!id\)\s*return\s*null/)) {
  ok("normalizeFeedItem rejects items without id");
} else {
  fl("normalizeFeedItem should reject items without id");
}

process.exit(fail > 0 ? 1 : 0);
NODE
[ $? -eq 0 ] && ok "Step 2 passed" || fail "Step 2 failed"
echo ""

# ── Step 3: Content type classification ──────────────────────────────────
echo "Step 3: Content type classification (feedItemCategory)"
node - "$SERVER" <<'NODE'
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8");

let pass = 0, fail = 0, total = 0;
const ok = (m) => { total++; pass++; console.log("  ✓ " + m); };
const fl = (m) => { total++; fail++; console.log("  ✗ FAIL: " + m); };

const fnIdx = src.indexOf("function feedItemCategory(item");
if (fnIdx === -1) { fl("feedItemCategory function found"); process.exit(1); }
ok("feedItemCategory function found");

// Verify all six recognized categories
const categories = ["broadcast", "curatorial", "artwork", "blog", "news", "content"];
for (const cat of categories) {
  const expected = "\"" + cat + "\"";
  const block = src.substring(fnIdx, fnIdx + 1500);
  if (block.includes(expected)) {
    ok("feedItemCategory returns '" + cat + "'");
  } else {
    fl("feedItemCategory should return '" + cat + "'");
  }
}

// Verify broadcast takes precedence (source check before type check)
const sourceCheck = src.indexOf('source === "broadcast"', fnIdx);
const typeCheck = src.indexOf('type.includes("artwork")', fnIdx);
if (sourceCheck > 0 && typeCheck > 0 && sourceCheck < typeCheck) {
  ok("broadcast category checked before artwork");
} else {
  fl("broadcast category should take precedence over artwork");
}

// Verify image/video/audio/sound/generative → artwork
const artworkTypes = ["image", "video", "audio", "sound", "generative"];
for (const t of artworkTypes) {
  const block = src.substring(fnIdx, fnIdx + 2000);
  if (block.includes('"' + t + '"')) {
    ok("type '" + t + "' recognized for artwork category");
  } else {
    fl("type '" + t + "' should map to artwork category");
  }
}

process.exit(fail > 0 ? 1 : 0);
NODE
[ $? -eq 0 ] && ok "Step 3 passed" || fail "Step 3 failed"
echo ""

# ── Step 4: Eligibility pipeline ─────────────────────────────────────────
echo "Step 4: Eligibility pipeline (filter chain)"
node - "$SERVER" <<'NODE'
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8");

let pass = 0, fail = 0, total = 0;
const ok = (m) => { total++; pass++; console.log("  ✓ " + m); };
const fl = (m) => { total++; fail++; console.log("  ✗ FAIL: " + m); };

const fnIdx = src.indexOf("function eligibleFeedItems(");
if (fnIdx === -1) { fl("eligibleFeedItems function found"); process.exit(1); }
ok("eligibleFeedItems function found");

const block = src.substring(fnIdx, fnIdx + 1200);

// Verify the 5 filter stages
const filters = [
  ["isExpired", "expiry filter (isExpired)"],
  ["startsAt", "scheduling filter (startsAt)"],
  ["feedItemTargetAllowed", "targeting filter (feedItemTargetAllowed)"],
  ["feedItemTypeAllowed", "type filter (feedItemTypeAllowed)"],
  ["feedItemArtistAllowed", "artist filter (feedItemArtistAllowed)"],
  ["feedItemStreamAllowed", "stream filter (feedItemStreamAllowed)"]
];

for (const [pattern, label] of filters) {
  if (block.includes(pattern)) {
    ok(label);
  } else {
    fl(label);
  }
}

// Verify sort order: priority desc, createdAt desc, order asc
if (block.includes("priorityRank") && block.includes("priorityDelta") && block.includes("createdDelta")) {
  ok("sort order: priority → createdAt → position");
} else {
  fl("sort order should be: priority → createdAt → position");
}

process.exit(fail > 0 ? 1 : 0);
NODE
[ $? -eq 0 ] && ok "Step 4 passed" || fail "Step 4 failed"
echo ""

# ── Step 5: Mixed queue composition rules ────────────────────────────────
echo "Step 5: Mixed queue composition (priority + category interleaving)"
node - "$SERVER" <<'NODE'
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8");

let pass = 0, fail = 0, total = 0;
const ok = (m) => { total++; pass++; console.log("  ✓ " + m); };
const fl = (m) => { total++; fail++; console.log("  ✗ FAIL: " + m); };

const fnIdx = src.indexOf("function mixedFeedQueue(");
if (fnIdx === -1) { fl("mixedFeedQueue function found"); process.exit(1); }
ok("mixedFeedQueue function found");

const block = src.substring(fnIdx, fnIdx + 2000);

// Verify category ordering
const catOrder = '["broadcast", "curatorial", "artwork", "blog", "news", "content"]';
if (block.includes(catOrder) || (block.includes('"broadcast"') && block.includes('"curatorial"') && block.includes('"artwork"'))) {
  ok("category ordering: broadcast → curatorial → artwork → blog → news → content");
} else {
  fl("category ordering not found");
}

// Verify display cursor integration (fresh before replay)
if (block.includes("feedCursor()") || block.includes("shownItemIds")) {
  ok("display cursor integration (fresh items before replay)");
} else {
  fl("display cursor integration missing");
}

// Verify FEED_QUEUE_LIMIT respected
if (block.includes("queueLimit") || block.includes("FEED_QUEUE_LIMIT")) {
  ok("queue limit respected");
} else {
  fl("queue limit not enforced");
}

// Verify displayCategory annotation
if (block.includes("displayCategory: feedItemCategory")) {
  ok("queue items annotated with displayCategory");
} else {
  fl("queue items should have displayCategory");
}

// Verify displayPosition annotation
if (block.includes("displayPosition")) {
  ok("queue items annotated with displayPosition");
} else {
  fl("queue items should have displayPosition");
}

// Verify priority grouping
if (block.includes("priorityRank") && block.includes("priorityGroups")) {
  ok("items grouped by priority rank");
} else {
  fl("items should be grouped by priority rank");
}

process.exit(fail > 0 ? 1 : 0);
NODE
[ $? -eq 0 ] && ok "Step 5 passed" || fail "Step 5 failed"
echo ""

# ── Step 6: Priority ranking contract ────────────────────────────────────
echo "Step 6: Priority ranking contract"
node - "$SERVER" <<'NODE'
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8");

let pass = 0, fail = 0, total = 0;
const ok = (m) => { total++; pass++; console.log("  ✓ " + m); };
const fl = (m) => { total++; fail++; console.log("  ✗ FAIL: " + m); };

const fnIdx = src.indexOf("function priorityRank(");
if (fnIdx === -1) { fl("priorityRank function found"); process.exit(1); }
ok("priorityRank function found");

const block = src.substring(fnIdx, fnIdx + 400);

// Verify all five priority levels with correct ordering
const levels = [
  ["emergency", "500"],
  ["critical", "400"],
  ["high", "300"],
  ["normal", "200"],
  ["low", "100"]
];

for (const [level, rank] of levels) {
  if (block.includes(level) && block.includes(rank)) {
    ok("priority '" + level + "' → rank " + rank);
  } else {
    fl("priority '" + level + "' should have rank " + rank);
  }
}

// Verify default fallback is "normal" (200)
if (block.includes("|| 200")) {
  ok("unknown priority defaults to 200 (normal)");
} else {
  fl("unknown priority should default to 200 (normal)");
}

process.exit(fail > 0 ? 1 : 0);
NODE
[ $? -eq 0 ] && ok "Step 6 passed" || fail "Step 6 failed"
echo ""

# ── Step 7: Cache eligibility contract ───────────────────────────────────
echo "Step 7: Cache eligibility contract"
node - "$SERVER" <<'NODE'
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8");

let pass = 0, fail = 0, total = 0;
const ok = (m) => { total++; pass++; console.log("  ✓ " + m); };
const fl = (m) => { total++; fail++; console.log("  ✗ FAIL: " + m); };

// Verify normalizeFeedItem sets cacheAllowed
const normIdx = src.indexOf("function normalizeFeedItem(");
const normBlock = src.substring(normIdx, src.indexOf("}", src.indexOf("return {", normIdx) + 20));

if (normBlock.includes("cacheAllowed")) {
  ok("normalizeFeedItem sets cacheAllowed field");
} else {
  fl("normalizeFeedItem should set cacheAllowed");
}

// Verify default is true (opt-out, not opt-in)
if (normBlock.includes("raw.cacheAllowed !== false") && normBlock.includes("raw.cache_allowed !== false")) {
  ok("cacheAllowed defaults to true (opt-out model)");
} else {
  fl("cacheAllowed should default to true (opt-out)");
}

// Verify writeFeedState extracts cache-eligible items
const writeIdx = src.indexOf("function writeFeedState(");
if (writeIdx === -1) { fl("writeFeedState function found"); process.exit(1); }
ok("writeFeedState function found");

const writeBlock = src.substring(writeIdx, writeIdx + 2000);
if (writeBlock.includes("cacheAllowed") && writeBlock.includes("mediaUrl")) {
  ok("writeFeedState extracts cache-eligible items with mediaUrl");
} else {
  fl("writeFeedState should extract cache-eligible items");
}

// Verify offline cache builder checks cache eligibility
const offIdx = src.indexOf("function cachedOfflineItems(");
if (offIdx === -1) { fl("cachedOfflineItems function found"); process.exit(1); }
ok("cachedOfflineItems function found");

const offBlock = src.substring(offIdx, offIdx + 1500);
if (offBlock.includes("cacheAssetUsable")) {
  ok("offline cache builder checks asset usability");
} else {
  fl("offline cache builder should check asset usability");
}

if (offBlock.includes("isExpired")) {
  ok("offline cache builder filters expired items");
} else {
  fl("offline cache builder should filter expired items");
}

process.exit(fail > 0 ? 1 : 0);
NODE
[ $? -eq 0 ] && ok "Step 7 passed" || fail "Step 7 failed"
echo ""

# ── Step 8: Per-category display timing ──────────────────────────────────
echo "Step 8: Per-category display timing"
node - "$SERVER" <<'NODE'
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8");

let pass = 0, fail = 0, total = 0;
const ok = (m) => { total++; pass++; console.log("  ✓ " + m); };
const fl = (m) => { total++; fail++; console.log("  ✗ FAIL: " + m); };

// Verify CATEGORY_DISPLAY_SECONDS constant
if (src.includes("const CATEGORY_DISPLAY_SECONDS")) {
  ok("CATEGORY_DISPLAY_SECONDS constant defined");
} else {
  fl("CATEGORY_DISPLAY_SECONDS constant should be defined");
}

// Verify broadcast default is 0 (until dismissed)
const catIdx = src.indexOf("const CATEGORY_DISPLAY_SECONDS");
const catBlock = src.substring(catIdx, catIdx + 300);
if (catBlock.includes("broadcast: 0")) {
  ok("broadcast default dwell: 0 (until dismissed)");
} else {
  fl("broadcast default dwell should be 0");
}

// Verify other defaults are non-zero
const defaults = [["curatorial", "45"], ["artwork", "60"], ["blog", "30"], ["news", "20"]];
for (const [cat, sec] of defaults) {
  if (catBlock.includes(cat + ": " + sec)) {
    ok(cat + " default dwell: " + sec + "s");
  } else {
    fl(cat + " default dwell should be " + sec + "s");
  }
}

// Verify BROADCAST_MAX_DISPLAY_SECONDS cap
if (src.includes("BROADCAST_MAX_DISPLAY_SECONDS") && src.includes("300")) {
  ok("broadcast max display cap: 300s (5 min)");
} else {
  fl("broadcast max display cap should be 300s");
}

// Verify categoryDisplaySeconds supports user overrides
const fnIdx = src.indexOf("function categoryDisplaySeconds(");
if (fnIdx === -1) { fl("categoryDisplaySeconds function found"); process.exit(1); }
ok("categoryDisplaySeconds function found");

const fnBlock = src.substring(fnIdx, fnIdx + 400);
if (fnBlock.includes("categoryDurations") || fnBlock.includes("overrides")) {
  ok("categoryDisplaySeconds supports user preference overrides");
} else {
  fl("categoryDisplaySeconds should support user overrides");
}

// Verify frameItemDisplayMs uses category-aware timing
const displayIdx = src.indexOf("function frameItemDisplayMs(");
if (displayIdx === -1) { fl("frameItemDisplayMs function found"); process.exit(1); }
ok("frameItemDisplayMs function found");

const displayBlock = src.substring(displayIdx, displayIdx + 800);
if (displayBlock.includes("feedItemCategory") && displayBlock.includes("categoryDisplaySeconds")) {
  ok("frameItemDisplayMs uses category-aware timing");
} else {
  fl("frameItemDisplayMs should use category-aware timing");
}

// Verify video/audio items use their own duration
if (displayBlock.includes('"video"') && displayBlock.includes('"audio"') && displayBlock.includes("duration")) {
  ok("video/audio items use their native duration");
} else {
  fl("video/audio items should use native duration");
}

process.exit(fail > 0 ? 1 : 0);
NODE
[ $? -eq 0 ] && ok "Step 8 passed" || fail "Step 8 failed"
echo ""

# ── Step 9: Expiry and scheduling enforcement ────────────────────────────
echo "Step 9: Expiry and scheduling enforcement"
node - "$SERVER" <<'NODE'
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8");

let pass = 0, fail = 0, total = 0;
const ok = (m) => { total++; pass++; console.log("  ✓ " + m); };
const fl = (m) => { total++; fail++; console.log("  ✗ FAIL: " + m); };

// Verify isExpired function
const expIdx = src.indexOf("function isExpired(");
if (expIdx === -1) { fl("isExpired function found"); process.exit(1); }
ok("isExpired function found");

// Verify eligibleFeedItems filters expired items
const eligIdx = src.indexOf("function eligibleFeedItems(");
const eligBlock = src.substring(eligIdx, eligIdx + 800);
if (eligBlock.includes("isExpired(item.expiresAt")) {
  ok("eligibleFeedItems filters expired items");
} else {
  fl("eligibleFeedItems should filter expired items");
}

// Verify eligibleFeedItems filters future-start items
if (eligBlock.includes("startsAt") && eligBlock.includes("startsAt <= now")) {
  ok("eligibleFeedItems filters items with future startsAt");
} else {
  fl("eligibleFeedItems should filter items with future startsAt");
}

// Verify broadcast handler also checks expiry
const bcastIdx = src.indexOf("show_broadcast") !== -1 ? src.indexOf("broadcast_expired") : -1;
if (bcastIdx > 0) {
  ok("broadcast handler emits broadcast_expired for expired broadcasts");
} else {
  fl("broadcast handler should handle expired broadcasts");
}

// Verify broadcast handler checks startsAt
if (src.includes("startsAt") && src.includes("startsAt > now")) {
  ok("broadcast handler skips future-scheduled broadcasts");
} else {
  fl("broadcast handler should skip future-scheduled broadcasts");
}

process.exit(fail > 0 ? 1 : 0);
NODE
[ $? -eq 0 ] && ok "Step 9 passed" || fail "Step 9 failed"
echo ""

# ── Step 10: Feed public API shape ───────────────────────────────────────
echo "Step 10: Feed public API shape (publicFeed)"
node - "$SERVER" <<'NODE'
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8");

let pass = 0, fail = 0, total = 0;
const ok = (m) => { total++; pass++; console.log("  ✓ " + m); };
const fl = (m) => { total++; fail++; console.log("  ✗ FAIL: " + m); };

const fnIdx = src.indexOf("function publicFeed(");
if (fnIdx === -1) { fl("publicFeed function found"); process.exit(1); }
ok("publicFeed function found");

const block = src.substring(fnIdx, fnIdx + 1200);

// Verify required response fields
const fields = [
  ["ok", "ok field"],
  ["syncedAt", "syncedAt field"],
  ["source", "source field"],
  ["offline", "offline field"],
  ["offlineState", "offlineState field"],
  ["polling", "polling field"],
  ["pollingStatus", "pollingStatus field"],
  ["totalItems", "totalItems field"],
  ["eligibleItems", "eligibleItems field"],
  ["categories", "categories field"],
  ["displayQueueItems", "displayQueueItems field"],
  ["displayCursor", "displayCursor field"],
  ["displayQueue", "displayQueue field"],
  ["items", "items field"]
];

for (const [field, label] of fields) {
  if (block.includes(field + ":") || block.includes(field + " ||") || block.includes(",\n    " + field + ",") || block.includes("\n    " + field + ",")) {
    ok(label);
  } else {
    fl("publicFeed should include " + label);
  }
}

// Verify raw is stripped from public items
if (block.includes("raw, visibility")) {
  ok("publicFeed strips raw and visibility from items");
} else {
  fl("publicFeed should strip raw and visibility from items");
}

process.exit(fail > 0 ? 1 : 0);
NODE
[ $? -eq 0 ] && ok "Step 10 passed" || fail "Step 10 failed"
echo ""

# ── Step 11: Frame state display item shape ──────────────────────────────
echo "Step 11: Frame state display item shape"
node - "$SERVER" <<'NODE'
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8");

let pass = 0, fail = 0, total = 0;
const ok = (m) => { total++; pass++; console.log("  ✓ " + m); };
const fl = (m) => { total++; fail++; console.log("  ✗ FAIL: " + m); };

const fnIdx = src.indexOf("function publicFrameState(");
if (fnIdx === -1) { fl("publicFrameState function found"); process.exit(1); }
ok("publicFrameState function found");

const block = src.substring(fnIdx, fnIdx + 3000);

// Verify display item fields
const itemFields = [
  "id", "source", "type", "title", "artist", "artistId", "body",
  "url", "priority", "displayCategory", "displayPosition",
  "duration", "soundRequired", "expiresAt", "liked", "media", "displayMs"
];

for (const field of itemFields) {
  if (block.includes(field + ":") || block.includes(field + " ||") || block.includes(",\n      " + field + ",") || block.includes("\n      " + field + ",")) {
    ok("frame item includes '" + field + "'");
  } else {
    fl("frame item should include '" + field + "'");
  }
}

// Verify media object structure
if (block.includes("url:") && block.includes("role:") && block.includes("cached:") && block.includes("source:")) {
  ok("media object includes url, role, cached, source");
} else {
  fl("media object should include url, role, cached, source");
}

// Verify displayMs is computed per-item
if (block.includes("frameItemDisplayMs(publicItem")) {
  ok("displayMs computed per-item via frameItemDisplayMs");
} else {
  fl("displayMs should be computed per-item");
}

// Verify raw stripped from frame items
if (block.includes("raw, ...item") || block.includes("({ raw, ...item })")) {
  ok("raw stripped from frame state items");
} else {
  fl("raw should be stripped from frame state items");
}

process.exit(fail > 0 ? 1 : 0);
NODE
[ $? -eq 0 ] && ok "Step 11 passed" || fail "Step 11 failed"
echo ""

# ── Step 12: Feed normalization integration (live test) ──────────────────
echo "Step 12: Feed normalization integration (live server)"

pick_port() {
  node - <<'PORTNODE'
const net = require("net");
const server = net.createServer();
server.listen(0, "127.0.0.1", () => {
  console.log(server.address().port);
  server.close();
});
PORTNODE
}

PORT="${AUTOPOIESIS_FEED_MODEL_PORT:-$(pick_port)}"
MOCK_PORT="${AUTOPOIESIS_FEED_MODEL_API_PORT:-$(pick_port)}"
TMP_DIR="$(mktemp -d)"
SERVER_PID=""
API_PID=""

cleanup() {
  [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true
  [ -n "${API_PID:-}" ] && kill "$API_PID" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$TMP_DIR/data" "$TMP_DIR/log" "$TMP_DIR/cache"

# Start mock API
MOCK_URL="http://127.0.0.1:$MOCK_PORT"
node - "$TMP_DIR" "$MOCK_PORT" <<'MOCKNODE' &
const http = require("http");
const fs = require("fs");
const dataDir = process.argv[2];
const port = parseInt(process.argv[3], 10);

// Minimal mock that returns mixed content with all 6 categories
const server = http.createServer((req, res) => {
  res.setHeader("Content-Type", "application/json");
  const url = new URL(req.url, "http://localhost");

  if (url.pathname.match(/\/api\/frames\/device\/[^/]+\/stream/)) {
    res.end(JSON.stringify({
      ok: true,
      items: [
        { id: "art-001", type: "artwork_image", title: "Test Artwork", artist: "Vessel", artistId: "vessel", mediaUrl: "https://example.com/art.jpg", priority: "normal", createdAt: new Date().toISOString() },
        { id: "blog-001", type: "blog_post", title: "Blog Post", body: "Content", priority: "low", createdAt: new Date().toISOString() },
        { id: "news-001", type: "news_update", title: "News Flash", priority: "high", createdAt: new Date().toISOString(), expiresAt: new Date(Date.now() + 3600000).toISOString() },
        { id: "curatorial-001", type: "curatorial_note", title: "Curatorial", body: "Note text", priority: "normal", createdAt: new Date().toISOString() },
        { id: "gen-001", type: "generative", title: "Gen Art", mediaUrl: "https://example.com/gen.html", priority: "normal", createdAt: new Date().toISOString() },
        { id: "expired-001", type: "artwork_image", title: "Expired Art", mediaUrl: "https://example.com/old.jpg", expiresAt: new Date(Date.now() - 1000).toISOString() }
      ],
      polling: { nextPollAt: new Date(Date.now() + 300000).toISOString(), staleAfter: 600 }
    }));
  } else if (url.pathname.match(/\/api\/frames\/device\/[^/]+\/feed/)) {
    res.end(JSON.stringify({ ok: true, items: [], syncedAt: new Date().toISOString() }));
  } else if (url.pathname.match(/\/api\/frames\/device\/[^/]+\/settings/) && req.method === "GET") {
    res.end(JSON.stringify({ ok: true, settings: {} }));
  } else if (url.pathname.match(/\/api\/frames\/device\/[^/]+\/heartbeat/)) {
    let body = "";
    req.on("data", c => body += c);
    req.on("end", () => {
      res.end(JSON.stringify({ ok: true, commands: [] }));
    });
  } else if (url.pathname.match(/\/api\/frames\/device\/register/)) {
    let body = "";
    req.on("data", c => body += c);
    req.on("end", () => {
      const d = JSON.parse(body || "{}");
      res.end(JSON.stringify({
        ok: true,
        deviceId: d.deviceId || "test-device",
        deviceApiKey: "test-key-123",
        pairingCode: "AB12CD",
        pairingExpiresAt: new Date(Date.now() + 600000).toISOString()
      }));
    });
  } else {
    res.statusCode = 404;
    res.end(JSON.stringify({ ok: false, error: "not found" }));
  }
});
server.listen(port, "127.0.0.1");
MOCKNODE
API_PID=$!

sleep 1

# Register device
mkdir -p "$TMP_DIR/data"
cat > "$TMP_DIR/data/device.json" <<DEVJSON
{
  "deviceId": "feed-model-test",
  "deviceName": "Feed Model Test Frame",
  "paired": true,
  "ownerUserId": "test-owner",
  "pairedAt": "$(date -Iseconds)",
  "apiBaseUrl": "$MOCK_URL/api",
  "deviceApiKey": "test-key-123"
}
DEVJSON

# Start local UI
AUTOPOIESIS_PORT=$PORT \
AUTOPOIESIS_DATA_DIR="$TMP_DIR/data" \
AUTOPOIESIS_LOG_DIR="$TMP_DIR/log" \
AUTOPOIESIS_CACHE_DIR="$TMP_DIR/cache" \
node "$SERVER" > "$TMP_DIR/server.log" 2>&1 &
SERVER_PID=$!

sleep 2

BASE="http://127.0.0.1:$PORT"

# Sync feed from the mock API
SYNC_RESULT=$(curl -sf -X POST "$BASE/local/feed/sync" 2>/dev/null || echo '{"ok":false}')

# Check feed response
FEED_RESULT=$(curl -sf "$BASE/local/feed" 2>/dev/null || echo '{"ok":false}')

# Check frame state
FRAME_RESULT=$(curl -sf "$BASE/local/frame-state" 2>/dev/null || echo '{"ok":false}')

node - "$SYNC_RESULT" "$FEED_RESULT" "$FRAME_RESULT" <<'CHECKNODE'
const sync = JSON.parse(process.argv[2]);
const feed = JSON.parse(process.argv[3]);
const frame = JSON.parse(process.argv[4]);

let pass = 0, fail = 0, total = 0;
const ok = (m) => { total++; pass++; console.log("  ✓ " + m); };
const fl = (m) => { total++; fail++; console.log("  ✗ FAIL: " + m); };

// Feed sync
if (sync.ok) {
  ok("feed sync returned ok:true");
} else {
  fl("feed sync should return ok:true (got: " + JSON.stringify(sync).substring(0, 100) + ")");
}

// Feed response shape
if (feed.ok) ok("feed endpoint returned ok:true"); else fl("feed endpoint should return ok:true");
if (feed.items && Array.isArray(feed.items)) ok("feed items is array"); else fl("feed items should be array");
if (feed.categories && typeof feed.categories === "object") ok("feed has categories object"); else fl("feed should have categories");
if (feed.displayQueue && Array.isArray(feed.displayQueue)) ok("feed has displayQueue array"); else fl("feed should have displayQueue");
if (feed.pollingStatus && typeof feed.pollingStatus === "object") ok("feed has pollingStatus"); else fl("feed should have pollingStatus");

// Verify expired item was filtered
const hasExpired = feed.items && feed.items.some(i => i.id === "expired-001");
if (!hasExpired) {
  ok("expired item (expired-001) filtered from eligible items");
} else {
  fl("expired item should be filtered from eligible items");
}

// Verify category counts
const cats = feed.categories || {};
if (cats.artwork >= 1) ok("artwork category present"); else fl("artwork category should be present (got: " + JSON.stringify(cats) + ")");
if (cats.blog >= 1) ok("blog category present"); else fl("blog category should be present");
if (cats.news >= 1) ok("news category present"); else fl("news category should be present");
if (cats.curatorial >= 1) ok("curatorial category present"); else fl("curatorial category should be present");

// Frame state
if (frame.ok) ok("frame-state returned ok:true"); else fl("frame-state should return ok:true");
if (frame.kind === "autopoiesis_frame_state") ok("frame-state has correct kind"); else fl("frame-state should have kind autopoiesis_frame_state");
if (frame.schemaVersion === 1) ok("frame-state has schemaVersion 1"); else fl("frame-state should have schemaVersion 1");

// Frame items have all required fields
if (frame.items && frame.items.length > 0) {
  const item = frame.items[0];
  const requiredFields = ["id", "source", "type", "displayCategory", "displayMs", "media", "priority"];
  for (const f of requiredFields) {
    if (item[f] !== undefined) {
      ok("frame item[0] has '" + f + "'");
    } else {
      fl("frame item[0] should have '" + f + "'");
    }
  }

  // Media object
  const itemsWithMedia = frame.items.filter(fi => fi.media && fi.media.url);
  if (itemsWithMedia.length > 0 && itemsWithMedia[0].media.role) ok("frame item with media has role"); else fl("frame item with media should have role");
  if (item.media && typeof item.media.cached === "boolean") ok("frame item media.cached is boolean"); else fl("frame item media.cached should be boolean");

  // Display timing varies by category
  const categories = {};
  for (const fi of frame.items) {
    categories[fi.displayCategory] = fi.displayMs;
  }
  // Broadcast default is 0 → capped at broadcast max (300000ms)
  // Other categories should have non-zero displayMs
  let allNonZero = true;
  for (const [cat, ms] of Object.entries(categories)) {
    if (cat !== "broadcast" && ms === 0) allNonZero = false;
  }
  if (allNonZero) ok("all non-broadcast items have non-zero displayMs"); else fl("non-broadcast items should have non-zero displayMs");
} else {
  fl("frame-state should have items array with content");
}

// Verify category display config in frame state
if (frame.categoryDisplay) {
  if (frame.categoryDisplay.defaults && typeof frame.categoryDisplay.defaults === "object") {
    ok("frame-state has categoryDisplay.defaults");
  } else {
    fl("frame-state should have categoryDisplay.defaults");
  }
  if (typeof frame.categoryDisplay.broadcastMaxSeconds === "number") {
    ok("frame-state has categoryDisplay.broadcastMaxSeconds");
  } else {
    fl("frame-state should have categoryDisplay.broadcastMaxSeconds");
  }
} else {
  fl("frame-state should have categoryDisplay");
}

process.exit(fail > 0 ? 1 : 0);
CHECKNODE
[ $? -eq 0 ] && ok "Step 12 passed" || fail "Step 12 failed"
echo ""

# ── Summary ──────────────────────────────────────────────────────────────
echo "=== Summary ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "  Total:  $TOTAL"
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo "RESULT: FAIL ($FAIL failures)"
  exit 1
fi

echo "RESULT: PASS ($TOTAL checks)"
