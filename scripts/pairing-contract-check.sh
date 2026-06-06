#!/usr/bin/env bash
set -euo pipefail

SOURCE="${1:-${AUTOPOIESIS_PAIRING_CONTRACT_SOURCE:-}}"
REQUIRE_DEVICE_KEY="${AUTOPOIESIS_PAIRING_REQUIRE_DEVICE_KEY:-1}"
MAX_TTL_SECONDS="${AUTOPOIESIS_PAIRING_MAX_TTL_SECONDS:-3600}"
TMP_FILE=""

cleanup() {
  if [[ -n "$TMP_FILE" ]]; then
    rm -f "$TMP_FILE"
  fi
}
trap cleanup EXIT

fail() {
  echo "pairing contract check failed: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/pairing-contract-check.sh <pairing-contract-bundle.json>
  scripts/pairing-contract-check.sh https://example/api/admin/frames/pairing-contract-bundle

Environment:
  AUTOPOIESIS_PAIRING_CONTRACT_SOURCE       default file or URL when no argument is passed
  AUTOPOIESIS_PAIRING_CONTRACT_TOKEN        optional bearer token for URL checks
  AUTOPOIESIS_PAIRING_REQUIRE_DEVICE_KEY    require registration.deviceApiKey, default 1
  AUTOPOIESIS_PAIRING_MAX_TTL_SECONDS       maximum pairing-code TTL, default 3600

The bundle is read-only evidence from staging/CI. It should contain deviceRegistration,
userPairing, and pairingStatus sections without running a destructive live pairing flow.
EOF
}

if [[ -z "$SOURCE" ]]; then
  usage
  exit 2
fi

if [[ "$SOURCE" =~ ^https?:// ]]; then
  TMP_FILE="$(mktemp)"
  CURL_ARGS=(-fsS)
  if [[ -n "${AUTOPOIESIS_PAIRING_CONTRACT_TOKEN:-}" ]]; then
    CURL_ARGS+=(-H "Authorization: Bearer ${AUTOPOIESIS_PAIRING_CONTRACT_TOKEN}")
  fi
  curl "${CURL_ARGS[@]}" "$SOURCE" >"$TMP_FILE" || fail "could not fetch pairing contract URL"
  SOURCE="$TMP_FILE"
fi

[[ -f "$SOURCE" ]] || fail "pairing contract bundle file not found: $SOURCE"

node - "$SOURCE" "$REQUIRE_DEVICE_KEY" "$MAX_TTL_SECONDS" <<'NODE'
const fs = require("fs");

const file = process.argv[2];
const requireDeviceKey = process.argv[3] !== "0";
const maxTtlSeconds = Number(process.argv[4] || 3600);
const forbiddenGlobalPatterns = [
  /pairingCodeHash/i,
  /pairing_code_hash/i,
  /accessToken/i,
  /refreshToken/i,
  /privateToken/i,
  /secret/i,
  /password/i,
  /\/var\/lib\/autopoiesis-os/i,
  /\/opt\/autopoiesis-os/i
];
const allowedStatuses = new Set([
  "pending",
  "unclaimed",
  "claimed",
  "paired",
  "expired",
  "consumed",
  "cancelled",
  "revoked"
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
  if (value === null || value === undefined || value === "") return;
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

function optionalArray(value, field) {
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value)) fail(field + " must be an array when present");
  return value;
}

function extractSection(payload, names, field) {
  for (const name of names) {
    if (payload[name] !== undefined && payload[name] !== null) {
      if (!isObject(payload[name])) fail(field + " must be an object");
      return payload[name];
    }
  }
  fail(field + " section is required");
}

function extractResponse(section, field) {
  const response = section.response || section.body || section.result || section;
  if (!isObject(response)) fail(field + " response must be an object");
  if (response.ok === false) fail(field + " response has ok=false");
  return response;
}

function pairingCodeFrom(value) {
  if (!isObject(value)) return null;
  return value.pairingCode || value.pairing_code || (isObject(value.pairing) ? value.pairing.pairingCode || value.pairing.pairing_code || value.pairing.code : null) || value.code || null;
}

function expiresAtFrom(value) {
  if (!isObject(value)) return null;
  return value.expiresAt || value.expires_at || (isObject(value.pairing) ? value.pairing.expiresAt || value.pairing.expires_at : null) || null;
}

function validatePairingCode(code, field) {
  requiredString(code, field);
  if (!/^[A-Z0-9][A-Z0-9-]{5,23}$/.test(code)) {
    fail(field + " must be uppercase alphanumeric text with optional hyphen separators");
  }
  if (/--/.test(code) || code.startsWith("-") || code.endsWith("-")) fail(field + " has invalid hyphen placement");
}

function validateExpiry(createdAt, expiresAt, field) {
  if (!expiresAt) fail(field + ".expiresAt is required");
  if (!validIso(expiresAt)) fail(field + ".expiresAt must be an ISO timestamp");
  if (createdAt !== undefined && createdAt !== null && createdAt !== "") {
    if (!validIso(createdAt)) fail(field + ".createdAt must be an ISO timestamp when present");
    const ttlMs = Date.parse(expiresAt) - Date.parse(createdAt);
    if (ttlMs <= 0) fail(field + ".expiresAt must be after createdAt");
    if (Number.isFinite(maxTtlSeconds) && maxTtlSeconds > 0 && ttlMs > maxTtlSeconds * 1000) {
      fail(field + " TTL exceeds " + maxTtlSeconds + " seconds");
    }
  }
}

function validateDevice(device, field, options = {}) {
  if (!isObject(device)) fail(field + " must be an object");
  requiredString(device.deviceId || device.device_id, field + ".deviceId");
  optionalString(device.deviceName || device.device_name, field + ".deviceName");
  optionalString(device.deviceType || device.device_type, field + ".deviceType");
  optionalString(device.softwareVersion || device.software_version, field + ".softwareVersion");
  optionalString(device.ownerUserId || device.owner_user_id, field + ".ownerUserId");
  optionalBoolean(device.paired, field + ".paired");
  optionalBoolean(device.remoteEnabled || device.remote_enabled, field + ".remoteEnabled");
  optionalBoolean(device.disabled, field + ".disabled");
  optionalIso(device.createdAt || device.created_at, field + ".createdAt");
  optionalIso(device.updatedAt || device.updated_at, field + ".updatedAt");
  if (options.requireOwner) requiredString(device.ownerUserId || device.owner_user_id, field + ".ownerUserId");
  if (options.requirePaired && device.paired !== true) fail(field + ".paired must be true after claim/status");
}

function validatePreferences(preferences, field) {
  if (preferences === undefined || preferences === null) return;
  if (!isObject(preferences)) fail(field + " must be an object when present");
  optionalIso(preferences.updatedAt || preferences.updated_at, field + ".updatedAt");
  optionalArray(preferences.activeArtists, field + ".activeArtists");
  optionalArray(preferences.streamCategories || preferences.enabledContentTypes, field + ".streamCategories");
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
    "showArtworkInfoOnTap"
  ]) {
    optionalBoolean(preferences[key], field + "." + key);
  }
}

function assertNoForbidden(value, field, options = {}) {
  const raw = JSON.stringify(value);
  for (const pattern of forbiddenGlobalPatterns) {
    if (pattern.test(raw)) fail(field + " exposes forbidden sensitive or local-only data: " + pattern);
  }
  if (!options.allowDeviceApiKey && /deviceApiKey|device_api_key|apiKey/i.test(raw)) {
    fail(field + " must not expose stored device API keys");
  }
  if (!options.allowPairingCode && /pairingCode|pairing_code|\bcode\b/i.test(raw)) {
    fail(field + " must not expose raw pairing codes");
  }
}

let payload;
try {
  payload = JSON.parse(fs.readFileSync(file, "utf8"));
} catch (error) {
  fail("invalid JSON: " + error.message);
}

if (!isObject(payload)) fail("pairing contract bundle must be a JSON object");
if (payload.ok === false) fail("pairing contract bundle ok=false");
if (payload.schemaVersion !== undefined && payload.schemaVersion !== 1) fail("schemaVersion must be 1 when present");
optionalIso(payload.generatedAt, "generatedAt");
assertNoForbidden(payload, "bundle", { allowDeviceApiKey: true, allowPairingCode: true });

const registrationSection = extractSection(payload, ["deviceRegistration", "registration", "register"], "deviceRegistration");
const userPairingSection = extractSection(payload, ["userPairing", "claim", "pairingClaim"], "userPairing");
const statusSection = extractSection(payload, ["pairingStatus", "status"], "pairingStatus");

const registration = extractResponse(registrationSection, "deviceRegistration");
assertNoForbidden(registration, "deviceRegistration", { allowDeviceApiKey: true, allowPairingCode: true });
const registeredDevice = registration.device || registration.frameDevice || registration;
validateDevice(registeredDevice, "deviceRegistration.device");
const deviceId = registeredDevice.deviceId || registeredDevice.device_id || registration.deviceId || registration.device_id;
requiredString(deviceId, "deviceRegistration.deviceId");
const pairingCode = pairingCodeFrom(registration);
validatePairingCode(pairingCode, "deviceRegistration.pairingCode");
const registrationCreatedAt = registration.createdAt || registration.created_at || (isObject(registration.pairing) ? registration.pairing.createdAt || registration.pairing.created_at : null) || payload.generatedAt;
validateExpiry(registrationCreatedAt, expiresAtFrom(registration), "deviceRegistration");
const deviceApiKey = registration.deviceApiKey || registration.device_api_key || (isObject(registration.device) ? registration.device.deviceApiKey || registration.device.device_api_key : null);
if (requireDeviceKey) requiredString(deviceApiKey, "deviceRegistration.deviceApiKey");
if (deviceApiKey && String(deviceApiKey).length < 24) fail("deviceRegistration.deviceApiKey is too short for a durable device credential");
if (registeredDevice.paired === true) fail("deviceRegistration.device.paired must not be true before user claim");

const userPairing = extractResponse(userPairingSection, "userPairing");
assertNoForbidden(userPairing, "userPairing");
const claimedDevice = userPairing.device || userPairing.frameDevice || userPairing.pairedDevice || null;
if (claimedDevice) validateDevice(claimedDevice, "userPairing.device", { requireOwner: true, requirePaired: true });
if (userPairing.deviceId !== undefined && userPairing.deviceId !== deviceId) fail("userPairing.deviceId does not match registration deviceId");
if (claimedDevice && (claimedDevice.deviceId || claimedDevice.device_id) !== deviceId) fail("userPairing.device.deviceId does not match registration deviceId");
const ownerUserId = userPairing.ownerUserId || userPairing.owner_user_id || userPairing.userId || userPairing.user_id || (claimedDevice ? claimedDevice.ownerUserId || claimedDevice.owner_user_id : null);
requiredString(ownerUserId, "userPairing.ownerUserId");
if (userPairing.paired !== undefined && userPairing.paired !== true) fail("userPairing.paired must be true when present");
optionalIso(userPairing.claimedAt || userPairing.claimed_at, "userPairing.claimedAt");
validatePreferences(userPairing.settings || userPairing.preferences || userPairing.deviceSettings, "userPairing.settings");
if (userPairing.pairing !== undefined && userPairing.pairing !== null) {
  if (!isObject(userPairing.pairing)) fail("userPairing.pairing must be an object when present");
  const claimStatus = userPairing.pairing.status || userPairing.pairing.pairingStatus;
  optionalString(claimStatus, "userPairing.pairing.status");
  if (claimStatus && !allowedStatuses.has(String(claimStatus))) fail("userPairing.pairing.status is unsupported: " + claimStatus);
  optionalIso(userPairing.pairing.claimedAt || userPairing.pairing.claimed_at, "userPairing.pairing.claimedAt");
}

const status = extractResponse(statusSection, "pairingStatus");
assertNoForbidden(status, "pairingStatus", { allowPairingCode: true });
if (status.deviceId !== undefined && status.deviceId !== deviceId) fail("pairingStatus.deviceId does not match registration deviceId");
if (status.device && (status.device.deviceId || status.device.device_id) !== deviceId) fail("pairingStatus.device.deviceId does not match registration deviceId");
if (status.paired !== true) fail("pairingStatus.paired must be true after user claim");
const statusOwner = status.ownerUserId || status.owner_user_id || status.userId || status.user_id || (status.device ? status.device.ownerUserId || status.device.owner_user_id : null);
if (statusOwner && statusOwner !== ownerUserId) fail("pairingStatus owner does not match userPairing ownerUserId");
if (status.device) validateDevice(status.device, "pairingStatus.device", { requirePaired: true });
validatePreferences(status.settings || status.preferences, "pairingStatus.settings");
if (status.pairing !== undefined && status.pairing !== null) {
  if (!isObject(status.pairing)) fail("pairingStatus.pairing must be an object when present");
  const statusValue = status.pairing.status || status.pairing.pairingStatus;
  optionalString(statusValue, "pairingStatus.pairing.status");
  if (statusValue && !allowedStatuses.has(String(statusValue))) fail("pairingStatus.pairing.status is unsupported: " + statusValue);
  optionalIso(status.pairing.claimedAt || status.pairing.claimed_at, "pairingStatus.pairing.claimedAt");
  optionalIso(status.pairing.expiresAt || status.pairing.expires_at, "pairingStatus.pairing.expiresAt");
}

console.log(
  "pairing contract ok: deviceId=" + deviceId +
    " ownerUserId=" + ownerUserId +
    " registrationKey=" + (deviceApiKey ? "present" : "absent") +
    " status=paired"
);
NODE
