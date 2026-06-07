#!/usr/bin/env bash
set -euo pipefail

SOURCE="${1:-${AUTOPOIESIS_STREAM_CONTRACT_SOURCE:-}}"
REQUIRE_ITEMS="${AUTOPOIESIS_REQUIRE_STREAM_ITEMS:-1}"
REQUIRE_POLLING="${AUTOPOIESIS_REQUIRE_STREAM_POLLING:-0}"
TMP_FILE=""

cleanup() {
  if [[ -n "$TMP_FILE" ]]; then
    rm -f "$TMP_FILE"
  fi
}
trap cleanup EXIT

fail() {
  echo "stream contract check failed: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/stream-contract-check.sh <stream-response.json>
  scripts/stream-contract-check.sh https://example/api/frames/device/<deviceId>/stream

Environment:
  AUTOPOIESIS_STREAM_CONTRACT_SOURCE   default file or URL when no argument is passed
  AUTOPOIESIS_STREAM_CONTRACT_TOKEN    optional bearer token for URL checks
  AUTOPOIESIS_REQUIRE_STREAM_ITEMS     require at least one stream item, default 1
  AUTOPOIESIS_REQUIRE_STREAM_POLLING   require polling/refresh cadence metadata, default 0
EOF
}

if [[ -z "$SOURCE" ]]; then
  usage
  exit 2
fi

if [[ "$SOURCE" =~ ^https?:// ]]; then
  TMP_FILE="$(mktemp)"
  CURL_ARGS=(-fsS)
  if [[ -n "${AUTOPOIESIS_STREAM_CONTRACT_TOKEN:-}" ]]; then
    CURL_ARGS+=(-H "Authorization: Bearer ${AUTOPOIESIS_STREAM_CONTRACT_TOKEN}")
  fi
  curl "${CURL_ARGS[@]}" "$SOURCE" >"$TMP_FILE" || fail "could not fetch stream URL"
  SOURCE="$TMP_FILE"
fi

[[ -f "$SOURCE" ]] || fail "stream response file not found: $SOURCE"

node - "$SOURCE" "$REQUIRE_ITEMS" "$REQUIRE_POLLING" <<'NODE'
const fs = require("fs");

const file = process.argv[2];
const requireItems = process.argv[3] !== "0";
const requirePolling = process.argv[4] === "1";
const forbiddenPatterns = [
  /deviceApiKey/i,
  /pairingCodeHash/i,
  /apiKey/i,
  /secret/i,
  /token/i,
  /\/var\/lib\/autopoiesis-os/i,
  /\/opt\/autopoiesis-os/i
];

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
  if (value === null || value === undefined || value === "") return;
  if (!validIso(value)) fail(field + " must be an ISO timestamp");
}

function optionalBoolean(value, field) {
  if (value === null || value === undefined) return;
  if (typeof value !== "boolean") fail(field + " must be boolean when present");
}

function optionalNumber(value, field) {
  if (value === null || value === undefined || value === "") return;
  if (!Number.isFinite(Number(value))) fail(field + " must be numeric when present");
}

function optionalArray(value, field) {
  if (value === null || value === undefined) return;
  if (!Array.isArray(value)) fail(field + " must be an array when present");
}

function validateTargeting(targeting, field) {
  if (targeting === null || targeting === undefined) return;
  if (typeof targeting === "string") return;
  if (Array.isArray(targeting)) {
    for (const [index, entry] of targeting.entries()) validateTargeting(entry, field + "[" + index + "]");
    return;
  }
  if (!isObject(targeting)) fail(field + " must be a string, object, or array when present");

  const recognized = [
    "type", "targetType", "scope", "kind", "value", "targetValue", "values", "ids", "id",
    "deviceId", "deviceIds", "devices", "targetDeviceIds",
    "userId", "userIds", "ownerUserId", "ownerUserIds", "users", "owners", "targetUserIds",
    "subscriptionStatus", "subscriptionStatuses", "subscriberStatus", "subscriberStatuses",
    "subscriptionTier", "subscriptionTiers", "tier", "tiers",
    "region", "regions", "country", "countries",
    "excludeDeviceIds", "excludedDeviceIds", "blockedDeviceIds",
    "excludeUserIds", "excludedUserIds", "blockedUserIds"
  ];
  const unknown = Object.keys(targeting).filter(key => !recognized.includes(key));
  if (unknown.length) fail(field + " contains unsupported targeting keys: " + unknown.join(", "));
}

function firstPresent(...values) {
  return values.find(value => value !== undefined && value !== null && value !== "");
}

function pollingSeconds(value, field) {
  if (value === undefined || value === null || value === "") return null;
  const number = Number(value);
  if (!Number.isFinite(number)) fail(field + " must be numeric when present");
  if (number <= 0) fail(field + " must be greater than zero");
  if (number < 5) fail(field + " must be at least 5 seconds");
  if (number > 86400) fail(field + " must be at most 86400 seconds");
  return number;
}

function validatePolling(payload) {
  const stream = isObject(payload.stream) ? payload.stream : {};
  const polling = payload.polling || payload.poll || payload.refresh || stream.polling || stream.poll || stream.refresh || null;
  const source = isObject(polling) ? polling : {};
  const pollAfterSeconds = firstPresent(
    payload.pollAfterSeconds,
    payload.poll_after_seconds,
    payload.refreshAfterSeconds,
    payload.refresh_after_seconds,
    stream.pollAfterSeconds,
    stream.poll_after_seconds,
    stream.refreshAfterSeconds,
    stream.refresh_after_seconds,
    stream.pollIntervalSeconds,
    stream.poll_interval_seconds,
    source.pollAfterSeconds,
    source.poll_after_seconds,
    source.refreshAfterSeconds,
    source.refresh_after_seconds,
    source.intervalSeconds,
    source.interval_seconds,
    source.seconds
  );
  const intervalMs = firstPresent(source.ms, source.intervalMs, source.interval_ms);
  const normalizedPollAfter = pollAfterSeconds !== undefined ? pollingSeconds(pollAfterSeconds, "polling.pollAfterSeconds") : null;
  if (intervalMs !== undefined) pollingSeconds(Number(intervalMs) / 1000, "polling.intervalMs");
  pollingSeconds(firstPresent(source.minPollSeconds, source.min_poll_seconds, source.minSeconds, source.min_seconds, stream.minPollSeconds, stream.min_poll_seconds), "polling.minPollSeconds");
  pollingSeconds(firstPresent(source.maxPollSeconds, source.max_poll_seconds, source.maxSeconds, source.max_seconds, stream.maxPollSeconds, stream.max_poll_seconds), "polling.maxPollSeconds");
  optionalIso(firstPresent(payload.nextPollAt, payload.next_poll_at, stream.nextPollAt, stream.next_poll_at, source.nextPollAt, source.next_poll_at, source.at), "polling.nextPollAt");
  optionalIso(firstPresent(payload.staleAfter, payload.stale_after, stream.staleAfter, stream.stale_after, source.staleAfter, source.stale_after), "polling.staleAfter");
  if (source.reason !== undefined && source.reason !== null && typeof source.reason !== "string") fail("polling.reason must be a string when present");
  const hasPolling = Boolean(
    normalizedPollAfter ||
      intervalMs !== undefined ||
      firstPresent(payload.nextPollAt, payload.next_poll_at, stream.nextPollAt, stream.next_poll_at, source.nextPollAt, source.next_poll_at, source.at) ||
      firstPresent(payload.staleAfter, payload.stale_after, stream.staleAfter, stream.stale_after, source.staleAfter, source.stale_after)
  );
  if (requirePolling && !hasPolling) fail("polling cadence metadata is required");
  return hasPolling;
}

let payload;
try {
  payload = JSON.parse(fs.readFileSync(file, "utf8"));
} catch (error) {
  fail("invalid JSON: " + error.message);
}

const raw = JSON.stringify(payload);
for (const pattern of forbiddenPatterns) {
  if (pattern.test(raw)) fail("response appears to expose sensitive or local-only data: " + pattern);
}

if (!isObject(payload)) fail("stream response must be a JSON object");
if (payload.ok === false) fail("stream response ok=false");
if (payload.schemaVersion !== 1) fail("schemaVersion must be 1");
if (!validIso(payload.generatedAt)) fail("generatedAt is missing or invalid");
if (!isObject(payload.stream)) fail("stream metadata object is required");
if (payload.stream.profile !== undefined && typeof payload.stream.profile !== "string") fail("stream.profile must be a string");
if (payload.stream.source !== undefined && typeof payload.stream.source !== "string") fail("stream.source must be a string");
const hasPolling = validatePolling(payload);
if (!Array.isArray(payload.items)) fail("items must be an array");
if (requireItems && payload.items.length === 0) fail("items must not be empty");

const settings = payload.settings || payload.preferences || null;
if (settings !== null) {
  if (!isObject(settings)) fail("settings/preferences must be an object when present");
  optionalIso(settings.updatedAt || settings.updated_at, "settings.updatedAt");
  optionalArray(settings.activeArtists, "settings.activeArtists");
  optionalArray(settings.streamCategories || settings.enabledContentTypes, "settings.streamCategories");
  for (const field of ["allowImages", "allowVideos", "allowSoundWorks", "allowGenerativeWorks", "autoplay", "videoAutoplay", "soundAutoplay", "soundEnabled", "showArtworkInfoOnTap"]) {
    optionalBoolean(settings[field], "settings." + field);
  }
  optionalNumber(settings.volume, "settings.volume");
  optionalNumber(settings.imageDuration, "settings.imageDuration");
}

const allowedPriorities = new Set(["critical", "emergency", "high", "normal", "low"]);
const ids = new Set();
const categoryCounts = {};
let cacheEligible = 0;
let playable = 0;

for (const [index, item] of payload.items.entries()) {
  const prefix = "items[" + index + "]";
  if (!isObject(item)) fail(prefix + " must be an object");
  if (!item.id || typeof item.id !== "string") fail(prefix + ".id is required");
  if (ids.has(item.id)) fail("duplicate stream item id: " + item.id);
  ids.add(item.id);
  if (!item.type || typeof item.type !== "string") fail(prefix + ".type is required");
  if (item.title !== undefined && item.title !== null && typeof item.title !== "string") fail(prefix + ".title must be a string");
  if (item.artist !== undefined && item.artist !== null && typeof item.artist !== "string") fail(prefix + ".artist must be a string");
  if (item.artistId !== undefined && item.artistId !== null && typeof item.artistId !== "string") fail(prefix + ".artistId must be a string");
  if (item.body !== undefined && item.body !== null && typeof item.body !== "string") fail(prefix + ".body must be a string");
  for (const field of ["mediaUrl", "thumbnailUrl", "url", "infoUrl", "blogUrl", "exhibitionUrl", "dashboardUrl", "likeUrl"]) {
    if (item[field] !== undefined && item[field] !== null && typeof item[field] !== "string") fail(prefix + "." + field + " must be a string");
  }
  optionalNumber(item.durationSeconds ?? item.duration, prefix + ".durationSeconds");
  optionalBoolean(item.cacheAllowed ?? item.cache_allowed, prefix + ".cacheAllowed");
  optionalBoolean(item.soundRequired ?? item.sound_required, prefix + ".soundRequired");
  optionalIso(item.createdAt || item.created_at, prefix + ".createdAt");
  optionalIso(item.startsAt || item.starts_at || item.scheduledAt || item.scheduled_at, prefix + ".startsAt");
  optionalIso(item.expiresAt || item.expires_at, prefix + ".expiresAt");
  const priority = String(item.priority || "normal").toLowerCase();
  if (!allowedPriorities.has(priority)) fail(prefix + ".priority has unsupported value: " + priority);
  validateTargeting(item.targeting || item.visibility, prefix + ".targeting");

  const type = String(item.type).toLowerCase();
  const category = type.includes("broadcast")
    ? "broadcast"
    : type.includes("blog")
      ? "blog"
      : type.includes("news")
        ? "news"
        : type.includes("curatorial")
          ? "curatorial"
          : "artwork";
  categoryCounts[category] = (categoryCounts[category] || 0) + 1;
  if ((item.cacheAllowed ?? item.cache_allowed) !== false && (item.mediaUrl || item.media_url || item.thumbnailUrl || item.thumbnail_url)) cacheEligible += 1;
  if (item.mediaUrl || item.media_url || item.thumbnailUrl || item.thumbnail_url || item.title || item.body) playable += 1;
}

if (requireItems && playable === 0) fail("stream contains no playable/displayable items");

console.log(
  "stream contract ok: items=" + payload.items.length +
    " playable=" + playable +
    " cacheEligible=" + cacheEligible +
    " polling=" + (hasPolling ? "present" : "absent") +
    " categories=" + JSON.stringify(categoryCounts)
);
NODE
