#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${AUTOPOIESIS_LOCAL_BASE_URL:-http://localhost:3030}"
REQUIRE_FRAME_ITEMS="${AUTOPOIESIS_REQUIRE_FRAME_ITEMS:-0}"
TMP_FILE="$(mktemp)"

cleanup() {
  rm -f "$TMP_FILE"
}
trap cleanup EXIT

fail() {
  echo "frame-state check failed: $*" >&2
  exit 1
}

curl -fsS "$BASE_URL/local/frame-state" >"$TMP_FILE" || fail "GET /local/frame-state failed"

node - "$TMP_FILE" "$REQUIRE_FRAME_ITEMS" <<'NODE'
const fs = require("fs");
const file = process.argv[2];
const requireItems = process.argv[3] === "1";
const frame = JSON.parse(fs.readFileSync(file, "utf8"));

function fail(message) {
  console.error(message);
  process.exit(1);
}

if (!frame || frame.kind !== "autopoiesis_frame_state") fail("unexpected frame-state kind");
if (frame.schemaVersion !== 1) fail("unexpected frame-state schema version");
if (!frame.generatedAt || !Number.isFinite(Date.parse(frame.generatedAt))) fail("generatedAt is missing or invalid");
for (const field of ["totalItems", "displayQueueItems", "playableItems", "cachedPlayableItems"]) {
  if (!Number.isFinite(Number(frame[field]))) fail(field + " must be numeric");
}
if (!Array.isArray(frame.items)) fail("items must be an array");
if (frame.items.length !== Number(frame.playableItems)) fail("items length must match playableItems");
if (Number(frame.cachedPlayableItems) > Number(frame.playableItems)) fail("cachedPlayableItems cannot exceed playableItems");
if (!frame.playback || typeof frame.playback !== "object") fail("playback summary is missing");
if (Boolean(frame.playback.ready) !== (Number(frame.playableItems) > 0)) fail("playback.ready does not match playableItems");
if (frame.playback.playableItems !== Number(frame.playableItems)) fail("playback playable count mismatch");
if (requireItems && Number(frame.playableItems) <= 0) fail("no playable frame items available");

const allowedMediaSources = new Set(["cache", "remote", null]);
for (const item of frame.items) {
  if (!item.id) fail("frame item is missing id");
  if (!item.displayCategory) fail("frame item is missing displayCategory");
  if (!Number.isFinite(Number(item.displayPosition))) fail("frame item is missing numeric displayPosition");
  if (!item.media || typeof item.media !== "object") fail("frame item is missing media object");
  if (!allowedMediaSources.has(item.media.source || null)) fail("frame item has unexpected media source");
  if (item.media.url && /^\//.test(item.media.url) && !item.media.url.startsWith("/local/cache/assets/")) {
    fail("local media URL must use the safe cache asset route");
  }
}

console.log(
  "frame-state ready=" + frame.playback.ready +
    " status=" + frame.playback.status +
    " playable=" + frame.playableItems +
    " cached=" + frame.cachedPlayableItems
);
NODE

curl -fsS "$BASE_URL/frame" >/dev/null || fail "GET /frame failed"
