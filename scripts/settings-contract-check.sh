#!/usr/bin/env bash
set -euo pipefail

SOURCE="${1:-${AUTOPOIESIS_SETTINGS_CONTRACT_SOURCE:-}}"
REQUIRE_STALE_REJECTION="${AUTOPOIESIS_REQUIRE_SETTINGS_STALE_REJECTION:-1}"
REQUIRE_FINAL_READ="${AUTOPOIESIS_REQUIRE_SETTINGS_FINAL_READ:-1}"
REQUIRE_HEARTBEAT_SETTINGS="${AUTOPOIESIS_REQUIRE_SETTINGS_HEARTBEAT:-1}"
TMP_FILE=""

cleanup() {
  if [[ -n "$TMP_FILE" ]]; then
    rm -f "$TMP_FILE"
  fi
}
trap cleanup EXIT

fail() {
  echo "settings contract check failed: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/settings-contract-check.sh <settings-contract-bundle.json>
  scripts/settings-contract-check.sh https://example/api/admin/frames/settings-contract-bundle

Environment:
  AUTOPOIESIS_SETTINGS_CONTRACT_SOURCE       default bundle file or URL when no argument is passed
  AUTOPOIESIS_SETTINGS_CONTRACT_TOKEN        optional bearer token for URL checks
  AUTOPOIESIS_REQUIRE_SETTINGS_STALE_REJECTION require stale write conflict evidence, default 1
  AUTOPOIESIS_REQUIRE_SETTINGS_FINAL_READ    require final read after stale write, default 1
  AUTOPOIESIS_REQUIRE_SETTINGS_HEARTBEAT     require heartbeat settings evidence, default 1

The bundle is read-only staging/CI evidence for hosted newest-updatedAt settings
resolution. It should prove an initial read, a newer settings write, a stale
write rejection/conflict, a final read that preserved the newer row, and a
heartbeat response that returns authoritative settings.
EOF
}

if [[ -z "$SOURCE" ]]; then
  usage
  exit 2
fi

if [[ "$SOURCE" =~ ^https?:// ]]; then
  TMP_FILE="$(mktemp)"
  CURL_ARGS=(-fsS)
  if [[ -n "${AUTOPOIESIS_SETTINGS_CONTRACT_TOKEN:-}" ]]; then
    CURL_ARGS+=(-H "Authorization: Bearer ${AUTOPOIESIS_SETTINGS_CONTRACT_TOKEN}")
  fi
  curl "${CURL_ARGS[@]}" "$SOURCE" >"$TMP_FILE" || fail "could not fetch settings contract URL"
  SOURCE="$TMP_FILE"
fi

[[ -f "$SOURCE" ]] || fail "settings contract bundle file not found: $SOURCE"

node - "$SOURCE" "$REQUIRE_STALE_REJECTION" "$REQUIRE_FINAL_READ" "$REQUIRE_HEARTBEAT_SETTINGS" <<'NODE'
const fs = require("fs");

const [file, requireStaleRejectionValue, requireFinalReadValue, requireHeartbeatValue] = process.argv.slice(2);
const requireStaleRejection = requireStaleRejectionValue !== "0";
const requireFinalRead = requireFinalReadValue !== "0";
const requireHeartbeat = requireHeartbeatValue !== "0";

const sensitiveKeyPatterns = [
  /^deviceApiKey$/i,
  /^device_api_key$/i,
  /^apiKey$/i,
  /^api_key$/i,
  /^pairingCodeHash$/i,
  /^pairing_code_hash$/i,
  /^pairingCode$/i,
  /^pairing_code$/i,
  /^accessToken$/i,
  /^refreshToken$/i,
  /^privateToken$/i,
  /^adminToken$/i,
  /^password$/i,
  /^secret$/i,
  /^privateKey$/i
];

const sensitiveValuePatterns = [
  /\/var\/lib\/autopoiesis-os/i,
  /\/opt\/autopoiesis-os/i,
  /\/home\/frame/i,
  /Bearer\s+[A-Za-z0-9._~+\/-]{16,}/i,
  /eyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{8,}/,
  /sk-[A-Za-z0-9_-]{16,}/i
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
  if (value === undefined || value === null || value === "") return;
  if (!validIso(value)) fail(field + " must be an ISO timestamp when present");
}

function requiredIso(value, field) {
  if (!validIso(value)) fail(field + " is required and must be an ISO timestamp");
}

function optionalString(value, field) {
  if (value === undefined || value === null) return;
  if (typeof value !== "string") fail(field + " must be a string when present");
}

function optionalBoolean(value, field) {
  if (value === undefined || value === null) return;
  if (typeof value !== "boolean") fail(field + " must be boolean when present");
}

function optionalNumber(value, field) {
  if (value === undefined || value === null || value === "") return;
  if (!Number.isFinite(Number(value))) fail(field + " must be numeric when present");
}

function optionalArray(value, field) {
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value)) fail(field + " must be an array when present");
  return value;
}

function assertNoSensitive(value, field) {
  const seen = new Set();
  function walk(current, path) {
    if (current === null || current === undefined) return;
    if (typeof current === "string") {
      for (const pattern of sensitiveValuePatterns) {
        if (pattern.test(current)) fail(path + " exposes sensitive or local-only data: " + pattern);
      }
      if (
        /credential|token|key|secret|password|authorization/i.test(path) &&
        /^[A-Za-z0-9+/=_-]{32,}$/.test(current) &&
        !/redacted|hidden|omitted|masked|present|valid|invalid|missing|wrong/i.test(current)
      ) {
        fail(path + " looks like a raw credential; use a boolean or redacted marker instead");
      }
      return;
    }
    if (typeof current !== "object") return;
    if (seen.has(current)) return;
    seen.add(current);
    if (Array.isArray(current)) {
      current.forEach((entry, index) => walk(entry, path + "[" + index + "]"));
      return;
    }
    for (const [key, child] of Object.entries(current)) {
      if (sensitiveKeyPatterns.some((pattern) => pattern.test(key))) {
        fail(path + "." + key + " must not expose sensitive field names");
      }
      walk(child, path + "." + key);
    }
  }
  walk(value, field);
}

function readJson(path) {
  try {
    return JSON.parse(fs.readFileSync(path, "utf8"));
  } catch (error) {
    fail("invalid JSON: " + error.message);
  }
}

function sectionFrom(payload, names, field, options = {}) {
  for (const name of names) {
    if (payload[name] !== undefined && payload[name] !== null) {
      if (!isObject(payload[name])) fail(field + " must be an object");
      return payload[name];
    }
  }
  if (options.required === false) return null;
  fail(field + " section is required");
}

function unwrap(value) {
  if (!isObject(value)) return value;
  for (const key of ["body", "response", "result", "payload", "data"]) {
    if (isObject(value[key])) return unwrap(value[key]);
  }
  return value;
}

function responseFrom(section, field) {
  if (!isObject(section)) fail(field + " must be an object");
  const response = section.response || section.body || section.result || section.payload || section;
  if (!isObject(response)) fail(field + ".response must be an object");
  return response;
}

function requestFrom(section, field) {
  if (!isObject(section)) fail(field + " must be an object");
  const request = section.request || section.input || section.submitted || null;
  if (!isObject(request)) fail(field + ".request is required");
  return request;
}

function statusFrom(value) {
  if (!isObject(value)) return null;
  const status = Number(value.status ?? value.statusCode ?? value.httpStatus ?? value.code);
  return Number.isInteger(status) ? status : null;
}

function settingsFrom(value) {
  if (!isObject(value)) return null;
  const unwrapped = unwrap(value);
  if (!isObject(unwrapped)) return null;
  for (const key of ["settings", "deviceSettings", "preferences", "devicePreferences", "frameSettings"]) {
    if (isObject(unwrapped[key])) return unwrapped[key];
  }
  if (unwrapped.updatedAt || unwrapped.updated_at) return unwrapped;
  return null;
}

function timestamp(settings, field) {
  if (!isObject(settings)) fail(field + " must be an object");
  const value = settings.updatedAt || settings.updated_at;
  requiredIso(value, field + ".updatedAt");
  return Date.parse(value);
}

function validateSettings(settings, field) {
  if (!isObject(settings)) fail(field + " must be an object");
  requiredIso(settings.updatedAt || settings.updated_at, field + ".updatedAt");
  optionalArray(settings.activeArtists, field + ".activeArtists");
  optionalArray(settings.streamCategories || settings.enabledContentTypes, field + ".streamCategories");
  for (const key of [
    "allowImages",
    "allowVideos",
    "allowSoundWorks",
    "allowGenerativeWorks",
    "autoplay",
    "videoAutoplay",
    "soundAutoplay",
    "soundEnabled",
    "cacheEnabled",
    "cacheLikedArtworks",
    "cacheRecentArtworks",
    "cacheSelectedArtists",
    "likedWorksOnly",
    "showArtworkInfoOnTap",
    "nightMode"
  ]) {
    optionalBoolean(settings[key], field + "." + key);
  }
  for (const key of ["volume", "imageDuration", "brightness", "cacheSizeLimitMb"]) {
    optionalNumber(settings[key], field + "." + key);
  }
  optionalString(settings.displayMode, field + ".displayMode");
  optionalString(settings.streamProfile, field + ".streamProfile");
  optionalString(settings.offlineFallbackMode, field + ".offlineFallbackMode");
}

function deviceIdFrom(value) {
  if (!isObject(value)) return "";
  const unwrapped = unwrap(value);
  const candidates = [
    value.deviceId,
    value.device_id,
    unwrapped.deviceId,
    unwrapped.device_id,
    isObject(unwrapped.device) ? unwrapped.device.deviceId || unwrapped.device.device_id || unwrapped.device.id : null,
    isObject(unwrapped.frameDevice) ? unwrapped.frameDevice.deviceId || unwrapped.frameDevice.device_id || unwrapped.frameDevice.id : null
  ];
  return candidates.find((candidate) => typeof candidate === "string" && candidate.trim()) || "";
}

function assertDeviceMatches(value, expectedDeviceId, field) {
  if (!expectedDeviceId) return;
  const found = deviceIdFrom(value);
  if (found && found !== expectedDeviceId) {
    fail(field + " returned deviceId " + found + " for bundle deviceId " + expectedDeviceId);
  }
}

function requireSuccessful(response, field) {
  const status = statusFrom(response);
  if (status !== null && (status < 200 || status >= 300)) fail(field + ".status must be 2xx");
  if (response.ok === false) fail(field + ".ok must not be false");
}

function conflictMarker(value) {
  const response = unwrap(value);
  if (!isObject(response)) return "";
  const conflict = response.conflict || response.settingsConflict || response.settingsSync || response.error || response.reason || response.status;
  if (typeof conflict === "string") return conflict.toLowerCase();
  if (isObject(conflict)) {
    return String(
      conflict.status ||
        conflict.reason ||
        conflict.code ||
        conflict.type ||
        conflict.message ||
        conflict.conflict ||
        ""
    ).toLowerCase();
  }
  return "";
}

function requireStaleRejected(response, acceptedAt, field) {
  const status = statusFrom(response);
  const marker = conflictMarker(response);
  const rejectedByStatus = status !== null && status >= 400 && status < 500;
  const rejectedByBody =
    response.ok === false ||
    response.accepted === false ||
    response.applied === false ||
    /conflict|stale|older|local_newer|newer|rejected|not_applied/.test(marker);

  if (!rejectedByStatus && !rejectedByBody) {
    fail(field + " must show a stale-write rejection or explicit conflict");
  }

  const returnedSettings = settingsFrom(response);
  if (returnedSettings) {
    const returnedAt = timestamp(returnedSettings, field + ".response.settings");
    if (returnedAt < acceptedAt) {
      fail(field + " returned stale settings as authoritative after conflict");
    }
  }
}

const payload = readJson(file);
if (!isObject(payload)) fail("settings contract bundle must be a JSON object");
if (payload.ok === false) fail("settings contract bundle has ok=false");
assertNoSensitive(payload, "bundle");
optionalIso(payload.generatedAt || payload.checkedAt, "bundle.generatedAt");
if (payload.kind !== undefined && payload.kind !== "autopoiesis_frames_settings_contract") {
  optionalString(payload.kind, "bundle.kind");
}
if (payload.schemaVersion !== undefined && Number(payload.schemaVersion) !== 1) {
  fail("bundle.schemaVersion must be 1 when present");
}

const expectedDeviceId = typeof payload.deviceId === "string" ? payload.deviceId : "";
const initialRead = sectionFrom(payload, ["settingsRead", "initialRead", "read", "currentSettings"], "settingsRead");
const initialResponse = responseFrom(initialRead, "settingsRead");
requireSuccessful(initialResponse, "settingsRead.response");
assertDeviceMatches(initialResponse, expectedDeviceId, "settingsRead.response");
const initialSettings = settingsFrom(initialResponse);
if (!initialSettings) fail("settingsRead.response.settings is required");
validateSettings(initialSettings, "settingsRead.response.settings");
const initialAt = timestamp(initialSettings, "settingsRead.response.settings");

const newerWrite = sectionFrom(payload, ["newerWrite", "settingsWrite", "acceptedWrite", "writeNewer"], "newerWrite");
const newerRequest = requestFrom(newerWrite, "newerWrite");
const newerRequestSettings = settingsFrom(newerRequest);
if (!newerRequestSettings) fail("newerWrite.request.settings is required");
validateSettings(newerRequestSettings, "newerWrite.request.settings");
const newerRequestAt = timestamp(newerRequestSettings, "newerWrite.request.settings");
if (newerRequestAt <= initialAt) fail("newerWrite.request.settings.updatedAt must be newer than settingsRead");

const newerResponse = responseFrom(newerWrite, "newerWrite");
requireSuccessful(newerResponse, "newerWrite.response");
assertDeviceMatches(newerResponse, expectedDeviceId, "newerWrite.response");
const newerResponseSettings = settingsFrom(newerResponse);
if (!newerResponseSettings) fail("newerWrite.response.settings is required");
validateSettings(newerResponseSettings, "newerWrite.response.settings");
const acceptedAt = timestamp(newerResponseSettings, "newerWrite.response.settings");
if (acceptedAt < newerRequestAt) fail("newerWrite.response.settings.updatedAt must preserve or advance the submitted updatedAt");

if (requireStaleRejection) {
  const staleWrite = sectionFrom(payload, ["staleWrite", "staleSettingsWrite", "conflictWrite", "olderWrite"], "staleWrite");
  const staleRequest = requestFrom(staleWrite, "staleWrite");
  const staleRequestSettings = settingsFrom(staleRequest);
  if (!staleRequestSettings) fail("staleWrite.request.settings is required");
  validateSettings(staleRequestSettings, "staleWrite.request.settings");
  const staleRequestAt = timestamp(staleRequestSettings, "staleWrite.request.settings");
  if (staleRequestAt >= acceptedAt) fail("staleWrite.request.settings.updatedAt must be older than the accepted row");
  const staleResponse = responseFrom(staleWrite, "staleWrite");
  assertDeviceMatches(staleResponse, expectedDeviceId, "staleWrite.response");
  requireStaleRejected(staleResponse, acceptedAt, "staleWrite.response");
}

if (requireFinalRead) {
  const finalRead = sectionFrom(payload, ["finalRead", "postConflictRead", "readAfterStale", "latestRead"], "finalRead");
  const finalResponse = responseFrom(finalRead, "finalRead");
  requireSuccessful(finalResponse, "finalRead.response");
  assertDeviceMatches(finalResponse, expectedDeviceId, "finalRead.response");
  const finalSettings = settingsFrom(finalResponse);
  if (!finalSettings) fail("finalRead.response.settings is required");
  validateSettings(finalSettings, "finalRead.response.settings");
  const finalAt = timestamp(finalSettings, "finalRead.response.settings");
  if (finalAt < acceptedAt) fail("finalRead.response.settings.updatedAt must preserve the accepted newer row");
}

if (requireHeartbeat) {
  const heartbeat = sectionFrom(payload, ["heartbeat", "heartbeatResponse", "settingsHeartbeat"], "heartbeat");
  const heartbeatResponse = responseFrom(heartbeat, "heartbeat");
  requireSuccessful(heartbeatResponse, "heartbeat.response");
  assertDeviceMatches(heartbeatResponse, expectedDeviceId, "heartbeat.response");
  const heartbeatSettings = settingsFrom(heartbeatResponse);
  if (!heartbeatSettings) fail("heartbeat.response.settings is required");
  validateSettings(heartbeatSettings, "heartbeat.response.settings");
  const heartbeatAt = timestamp(heartbeatSettings, "heartbeat.response.settings");
  if (heartbeatAt < acceptedAt) fail("heartbeat.response.settings.updatedAt must not lag behind the accepted row");
}

console.log("settings contract ok");
NODE
