#!/usr/bin/env bash
set -euo pipefail

SOURCE="${1:-${AUTOPOIESIS_CACHE_CONTRACT_SOURCE:-}}"
REQUIRE_ITEMS="${AUTOPOIESIS_REQUIRE_CACHE_ITEMS:-1}"
REQUIRE_DEVICE_SUMMARY="${AUTOPOIESIS_REQUIRE_CACHE_DEVICE_SUMMARY:-1}"
TMP_FILE=""

cleanup() {
  if [[ -n "$TMP_FILE" ]]; then
    rm -f "$TMP_FILE"
  fi
}
trap cleanup EXIT

fail() {
  echo "cache contract check failed: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/cache-contract-check.sh <cache-contract-bundle.json>
  scripts/cache-contract-check.sh https://example/api/admin/frames/cache-contract-bundle

Environment:
  AUTOPOIESIS_CACHE_CONTRACT_SOURCE           default file or URL when no argument is passed
  AUTOPOIESIS_CACHE_CONTRACT_TOKEN            optional bearer token for URL checks
  AUTOPOIESIS_REQUIRE_CACHE_ITEMS             require at least one cache candidate/item, default 1
  AUTOPOIESIS_REQUIRE_CACHE_DEVICE_SUMMARY    require device cache/offline summary evidence, default 1

The bundle is read-only staging/CI evidence that hosted Profile > Frames cache
preferences, stream cache eligibility, and device cache/offline status can be
assembled without leaking local appliance paths or credentials.
EOF
}

if [[ -z "$SOURCE" ]]; then
  usage
  exit 2
fi

if [[ "$SOURCE" =~ ^https?:// ]]; then
  TMP_FILE="$(mktemp)"
  CURL_ARGS=(-fsS)
  if [[ -n "${AUTOPOIESIS_CACHE_CONTRACT_TOKEN:-}" ]]; then
    CURL_ARGS+=(-H "Authorization: Bearer ${AUTOPOIESIS_CACHE_CONTRACT_TOKEN}")
  fi
  curl "${CURL_ARGS[@]}" "$SOURCE" >"$TMP_FILE" || fail "could not fetch cache bundle URL"
  SOURCE="$TMP_FILE"
fi

[[ -f "$SOURCE" ]] || fail "cache contract bundle file not found: $SOURCE"

node - "$SOURCE" "$REQUIRE_ITEMS" "$REQUIRE_DEVICE_SUMMARY" <<'NODE'
const fs = require("fs");

const file = process.argv[2];
const requireItems = process.argv[3] !== "0";
const requireDeviceSummary = process.argv[4] !== "0";

const forbiddenPatterns = [
  /deviceApiKey/i,
  /device_api_key/i,
  /pairingCodeHash/i,
  /pairing_code_hash/i,
  /accessToken/i,
  /refreshToken/i,
  /privateToken/i,
  /adminToken/i,
  /bearer\s+[a-z0-9._-]+/i,
  /secret/i,
  /password/i,
  /cachePath/i,
  /localPath/i,
  /absolutePath/i,
  /assetPath/i,
  //var/lib/autopoiesis-os/i,
  //opt/autopoiesis-os/i,
  //var/log/autopoiesis-os/i,
  //home/frame/i
];
const allowedStatuses = new Set([
  "unknown",
  "pending",
  "queued",
  "eligible",
  "skipped",
  "cached",
  "failed",
  "expired",
  "evicted",
  "disabled"
]);
const allowedCategories = new Set([
  "artwork",
  "broadcast",
  "blog",
  "news",
  "curatorial",
  "general",
  "system",
  "exhibition"
]);

function fail(message) {
  console.error(message);
  process.exit(1);
}

function isObject(value) {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}

function validIso(value) {
  return typeof value === "string" && value.trim() && Number.isFinite(Date.parse(value));
}

function optionalIso(value, field) {
  if (value === undefined || value === null || value === "") return;
  if (!validIso(value)) fail(field + " must be an ISO timestamp when present");
}

function requiredString(value, field) {
  if (typeof value !== "string" || !value.trim()) fail(field + " is required");
}

function optionalString(value, field) {
  if (value === undefined || value === null) return;
  if (typeof value !== "string") fail(field + " must be a string when present");
}

function optionalBoolean(value, field) {
  if (value === undefined || value === null) return;
  if (typeof value !== "boolean") fail(field + " must be boolean when present");
}

function optionalNumber(value, field, min = null) {
  if (value === undefined || value === null || value === "") return;
  const number = Number(value);
  if (!Number.isFinite(number)) fail(field + " must be numeric when present");
  if (min !== null && number < min) fail(field + " must be >= " + min);
}

function extractArray(payload, names, field, required = true) {
  for (const name of names) {
    const value = payload[name];
    if (value === undefined || value === null) continue;
    if (Array.isArray(value)) return value;
    if (isObject(value) && Array.isArray(value.items)) return value.items;
    if (isObject(value) && Array.isArray(value.rows)) return value.rows;
    fail(field + " must be an array or paged object when present");
  }
  if (required) fail(field + " is required");
  return [];
}

function validateCachePolicy(policy, field) {
  if (!isObject(policy)) fail(field + " is required");
  for (const key of ["enabled", "likedArtworks", "recentArtworks", "selectedArtists"]) {
    if (typeof policy[key] !== "boolean") fail(field + "." + key + " must be an explicit boolean");
  }
  optionalBoolean(policy.cacheLikedArtworks, field + ".cacheLikedArtworks");
  optionalBoolean(policy.cacheRecentArtworks, field + ".cacheRecentArtworks");
  optionalBoolean(policy.cacheSelectedArtists, field + ".cacheSelectedArtists");
  optionalNumber(policy.sizeLimitMb ?? policy.cacheSizeLimitMb, field + ".sizeLimitMb", 0);
  if (!Number.isFinite(Number(policy.sizeLimitMb ?? policy.cacheSizeLimitMb))) {
    fail(field + ".sizeLimitMb is required");
  }
  optionalIso(policy.updatedAt || policy.updated_at, field + ".updatedAt");
}

function validateItem(item, field, ids) {
  if (!isObject(item)) fail(field + " must be an object");
  const id = item.itemId || item.id || item.artworkId || item.broadcastId;
  requiredString(id, field + ".itemId");
  if (ids.has(id)) fail("duplicate cache item id: " + id);
  ids.add(id);

  optionalString(item.type, field + ".type");
  optionalString(item.title, field + ".title");
  optionalString(item.artistId, field + ".artistId");
  optionalString(item.artist, field + ".artist");
  optionalString(item.source, field + ".source");
  optionalString(item.reason, field + ".reason");
  optionalString(item.mediaUrl || item.media_url, field + ".mediaUrl");
  optionalString(item.thumbnailUrl || item.thumbnail_url, field + ".thumbnailUrl");
  optionalString(item.sourceUrl || item.source_url, field + ".sourceUrl");
  optionalString(item.cacheKey || item.cache_key, field + ".cacheKey");
  optionalBoolean(item.cacheAllowed ?? item.cache_allowed, field + ".cacheAllowed");
  optionalNumber(item.durationSeconds ?? item.duration, field + ".durationSeconds", 0);
  optionalNumber(item.sizeBytes ?? item.bytes, field + ".sizeBytes", 0);
  optionalIso(item.createdAt || item.created_at, field + ".createdAt");
  optionalIso(item.cachedAt || item.cached_at, field + ".cachedAt");
  optionalIso(item.lastAttemptAt || item.last_attempt_at, field + ".lastAttemptAt");
  optionalIso(item.expiresAt || item.expires_at, field + ".expiresAt");

  const mediaUrl = item.mediaUrl || item.media_url || item.sourceUrl || item.source_url;
  const thumbnailUrl = item.thumbnailUrl || item.thumbnail_url;
  if (!mediaUrl && !thumbnailUrl) fail(field + " must include mediaUrl, sourceUrl, or thumbnailUrl");
  for (const [urlField, value] of [["mediaUrl", mediaUrl], ["thumbnailUrl", thumbnailUrl]]) {
    if (value === undefined || value === null || value === "") continue;
    if (typeof value !== "string") fail(field + "." + urlField + " must be a string");
    if (!/^https?:\/\//i.test(value)) fail(field + "." + urlField + " must be an HTTP(S) URL");
  }

  const category = String(item.category || item.displayCategory || "artwork").toLowerCase();
  if (!allowedCategories.has(category)) fail(field + ".category has unsupported value: " + category);
  const status = String(item.status || item.cacheStatus || "eligible").toLowerCase();
  if (!allowedStatuses.has(status)) fail(field + ".status has unsupported value: " + status);
}

function validateSummary(summary, field, itemCount) {
  if (!isObject(summary)) {
    if (requireDeviceSummary) fail(field + " is required");
    return { playable: 0, cached: 0, failed: 0 };
  }
  optionalString(summary.deviceId, field + ".deviceId");
  optionalIso(summary.lastSyncedAt || summary.syncedAt || summary.generatedAt, field + ".lastSyncedAt");
  for (const key of [
    "eligibleItems",
    "manifestItems",
    "cachedItems",
    "playableItems",
    "offlinePlayableItems",
    "failedItems",
    "pendingItems",
    "evictedItems",
    "sizeBytes",
    "sizeLimitMb",
    "cacheSizeLimitMb"
  ]) {
    optionalNumber(summary[key], field + "." + key, 0);
  }
  optionalBoolean(summary.enabled, field + ".enabled");
  if (requireDeviceSummary) {
    const cached = Number(summary.cachedItems ?? summary.offlinePlayableItems ?? summary.playableItems ?? 0);
    const playable = Number(summary.offlinePlayableItems ?? summary.playableItems ?? summary.cachedItems ?? 0);
    if (itemCount > 0 && cached + playable <= 0 && Number(summary.failedItems || 0) <= 0) {
      fail(field + " must include cached/playable/failed evidence for cache candidates");
    }
  }
  return {
    playable: Number(summary.offlinePlayableItems ?? summary.playableItems ?? 0),
    cached: Number(summary.cachedItems ?? 0),
    failed: Number(summary.failedItems ?? 0)
  };
}

let payload;
try {
  payload = JSON.parse(fs.readFileSync(file, "utf8"));
} catch (error) {
  fail("invalid JSON: " + error.message);
}

if (!isObject(payload)) fail("cache bundle root must be an object");
if (payload.ok === false) fail("cache bundle ok=false");
if (payload.schemaVersion !== undefined && payload.schemaVersion !== 1) fail("schemaVersion must be 1 when present");
if (payload.kind !== undefined && payload.kind !== "autopoiesis_frames_cache_contract") {
  fail("kind must be autopoiesis_frames_cache_contract when present");
}
optionalIso(payload.generatedAt, "generatedAt");

const raw = JSON.stringify(payload);
for (const pattern of forbiddenPatterns) {
  if (pattern.test(raw)) fail("bundle appears to expose sensitive or local-only data: " + pattern);
}

const deviceId = payload.deviceId || (isObject(payload.device) ? payload.device.deviceId : "");
if (deviceId !== undefined && deviceId !== null && deviceId !== "") requiredString(deviceId, "deviceId");
if (isObject(payload.device)) {
  optionalString(payload.device.deviceName, "device.deviceName");
  optionalString(payload.device.ownerUserId, "device.ownerUserId");
  optionalBoolean(payload.device.paired, "device.paired");
  optionalBoolean(payload.device.online, "device.online");
}

const policy =
  payload.cachePreferences ||
  payload.cachePolicy ||
  (isObject(payload.profileFrames) ? (payload.profileFrames.cachePreferences || payload.profileFrames.cache) : null) ||
  (isObject(payload.settings) ? payload.settings.cachePreferences : null);
validateCachePolicy(policy, "cachePreferences");

const items = extractArray(payload, [
  "cacheItems",
  "cacheCandidates",
  "cacheManifest",
  "manifestItems",
  "items"
], "cacheItems", requireItems);
if (requireItems && items.length === 0) fail("cacheItems must not be empty");

const ids = new Set();
let eligible = 0;
let cached = 0;
let failed = 0;
for (const [index, item] of items.entries()) {
  validateItem(item, "cacheItems[" + index + "]", ids);
  const status = String(item.status || item.cacheStatus || "eligible").toLowerCase();
  if (status !== "disabled" && status !== "skipped" && status !== "expired") eligible += 1;
  if (status === "cached") cached += 1;
  if (status === "failed") failed += 1;
}
if (requireItems && eligible === 0) fail("cacheItems contains no eligible cache candidates");

const summary =
  payload.deviceCache ||
  payload.cacheSummary ||
  payload.offlineCache ||
  (isObject(payload.device) ? payload.device.cache : null) ||
  (isObject(payload.supportBundle) ? payload.supportBundle.offlineCache : null);
const summaryCounts = validateSummary(summary, "deviceCache", items.length);

const commands = extractArray(payload, ["commands", "commandQueue", "queuedCommands"], "commands", false);
for (const [index, command] of commands.entries()) {
  if (!isObject(command)) fail("commands[" + index + "] must be an object");
  optionalString(command.id || command.commandId, "commands[" + index + "].id");
  const type = command.type || command.commandType || command.command_type;
  optionalString(type, "commands[" + index + "].type");
  if (type && type !== "clear_cache" && type !== "sync_settings") {
    fail("commands[" + index + "].type must be clear_cache or sync_settings when present in cache bundle");
  }
  optionalString(command.status, "commands[" + index + "].status");
  optionalIso(command.createdAt || command.created_at || command.queuedAt || command.queued_at, "commands[" + index + "].createdAt");
}

console.log(
  "cache contract ok: items=" + items.length +
    " eligible=" + eligible +
    " cached=" + Math.max(cached, summaryCounts.cached) +
    " playable=" + summaryCounts.playable +
    " failed=" + Math.max(failed, summaryCounts.failed)
);
NODE
