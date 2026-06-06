#!/usr/bin/env bash
set -euo pipefail

SOURCE="${1:-${AUTOPOIESIS_DEVICE_AUTH_CONTRACT_SOURCE:-}}"
REQUIRED_ROUTES="${AUTOPOIESIS_DEVICE_AUTH_REQUIRE_ROUTES:-pairing-status,settings-read,settings-write,heartbeat,stream,commands,command-ack,release}"
REQUIRE_MISMATCH="${AUTOPOIESIS_DEVICE_AUTH_REQUIRE_MISMATCH:-1}"
TMP_FILE=""

cleanup() {
  if [[ -n "$TMP_FILE" ]]; then
    rm -f "$TMP_FILE"
  fi
}
trap cleanup EXIT

fail() {
  echo "device auth contract check failed: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/device-auth-contract-check.sh <device-auth-contract-bundle.json>
  scripts/device-auth-contract-check.sh https://example/api/admin/frames/device-auth-contract-bundle

Environment:
  AUTOPOIESIS_DEVICE_AUTH_CONTRACT_SOURCE  default file or URL when no argument is passed
  AUTOPOIESIS_DEVICE_AUTH_CONTRACT_TOKEN   optional bearer token for URL checks
  AUTOPOIESIS_DEVICE_AUTH_REQUIRE_ROUTES   comma-separated route kinds, default:
                                            pairing-status,settings-read,settings-write,heartbeat,stream,commands,command-ack,release
  AUTOPOIESIS_DEVICE_AUTH_REQUIRE_MISMATCH require cross-device rejection attempts, default 1

The bundle is read-only staging/CI evidence. It should prove that device-only
routes accept the correct per-device credential and reject missing, invalid, and
cross-device credentials without exposing raw device keys or private tokens.
EOF
}

if [[ -z "$SOURCE" ]]; then
  usage
  exit 2
fi

if [[ "$SOURCE" =~ ^https?:// ]]; then
  TMP_FILE="$(mktemp)"
  CURL_ARGS=(-fsS)
  if [[ -n "${AUTOPOIESIS_DEVICE_AUTH_CONTRACT_TOKEN:-}" ]]; then
    CURL_ARGS+=(-H "Authorization: Bearer ${AUTOPOIESIS_DEVICE_AUTH_CONTRACT_TOKEN}")
  fi
  curl "${CURL_ARGS[@]}" "$SOURCE" >"$TMP_FILE" || fail "could not fetch device auth contract URL"
  SOURCE="$TMP_FILE"
fi

[[ -f "$SOURCE" ]] || fail "device auth contract bundle file not found: $SOURCE"

node - "$SOURCE" "$REQUIRED_ROUTES" "$REQUIRE_MISMATCH" <<'NODE'
const fs = require("fs");

const [file, requiredRoutesValue, requireMismatchValue] = process.argv.slice(2);
const requiredRoutes = String(requiredRoutesValue || "")
  .split(",")
  .map((entry) => normalizeKind(entry.trim()))
  .filter(Boolean);
const requireMismatch = requireMismatchValue !== "0";

const sensitiveKeyPatterns = [
  /^deviceApiKey$/i,
  /^device_api_key$/i,
  /^apiKey$/i,
  /^api_key$/i,
  /^pairingCodeHash$/i,
  /^pairing_code_hash$/i,
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

function requiredString(value, field) {
  if (typeof value !== "string" || !value.trim()) fail(field + " is required");
}

function statusFrom(attempt, field) {
  if (!isObject(attempt)) fail(field + " must be an object");
  const status = Number(attempt.status ?? attempt.statusCode ?? attempt.httpStatus ?? attempt.code);
  if (!Number.isInteger(status)) fail(field + ".status is required");
  return status;
}

function normalizeKind(value) {
  const text = String(value || "").trim().toLowerCase().replace(/_/g, "-");
  if (!text) return "";
  if (text === "pairing" || text.includes("pairing-status")) return "pairing-status";
  if (text === "settings-get" || text === "read-settings" || text.includes("settings-read")) return "settings-read";
  if (text === "settings-post" || text === "write-settings" || text.includes("settings-write")) return "settings-write";
  if (text.includes("heartbeat")) return "heartbeat";
  if (text.includes("stream")) return "stream";
  if (text.includes("command-ack") || text.includes("commands-ack") || text.includes("ack")) return "command-ack";
  if (text.includes("commands")) return "commands";
  if (text.includes("release")) return "release";
  return text;
}

function kindFromRoute(route) {
  const explicit = route.kind || route.name || route.routeKind || route.id || "";
  const method = String(route.method || route.httpMethod || "").trim().toUpperCase();
  const path = String(route.path || route.url || route.endpoint || "").trim().toLowerCase();
  const normalized = normalizeKind(explicit);
  if (normalized && requiredRoutes.includes(normalized)) return normalized;
  if (path.includes("/pairing-status")) return "pairing-status";
  if (path.includes("/settings") && method === "POST") return "settings-write";
  if (path.includes("/settings")) return "settings-read";
  if (path.includes("/heartbeat")) return "heartbeat";
  if (path.includes("/stream")) return "stream";
  if (path.includes("/commands/") && path.includes("/ack")) return "command-ack";
  if (path.includes("/commands")) return "commands";
  if (path.includes("/release")) return "release";
  return normalized || path || explicit || "unknown";
}

function extractRoutes(payload) {
  if (Array.isArray(payload.routes)) return payload.routes;
  if (Array.isArray(payload.endpoints)) return payload.endpoints;
  if (Array.isArray(payload.checks)) return payload.checks;
  if (isObject(payload.routes)) {
    return Object.entries(payload.routes).map(([key, route]) => ({ kind: key, ...(isObject(route) ? route : { attempts: route }) }));
  }
  fail("routes/endpoints/checks collection is required");
}

function firstAttempt(attempts, keys, field) {
  if (!isObject(attempts)) fail(field + ".attempts must be an object");
  for (const key of keys) {
    if (attempts[key] !== undefined && attempts[key] !== null) return attempts[key];
  }
  fail(field + ".attempts missing " + keys[0]);
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
        !/redacted|hidden|omitted|masked|credential-present|valid-device-credential/i.test(current)
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
        fail(path + "." + key + " must not expose stored credential field names");
      }
      if (/credential/i.test(key) && typeof child === "string" && !/redacted|hidden|omitted|masked|present|valid|invalid|missing|wrong/i.test(child)) {
        fail(path + "." + key + " must use a redacted credential marker");
      }
      walk(child, path + "." + key);
    }
  }
  walk(value, field);
}

function responseBody(attempt) {
  if (!isObject(attempt)) return null;
  const body = attempt.body ?? attempt.response ?? attempt.result ?? attempt.payload ?? null;
  return isObject(body) ? body : null;
}

function deviceIdFromRoute(route, attempt) {
  const direct = route.deviceId || route.device_id || route.validDeviceId || route.pathDeviceId;
  if (typeof direct === "string" && direct.trim()) return direct.trim();
  const path = String(route.path || route.url || route.endpoint || attempt?.path || "").trim();
  const match = path.match(/\/api\/frames\/device\/([^/?#]+)/i);
  return match ? decodeURIComponent(match[1]) : "";
}

function assertBodyDeviceMatches(attempt, expectedDeviceId, field) {
  const body = responseBody(attempt);
  if (!body || !expectedDeviceId) return;
  const candidates = [
    body.deviceId,
    body.device_id,
    isObject(body.device) ? body.device.deviceId || body.device.device_id || body.device.id : null,
    isObject(body.frameDevice) ? body.frameDevice.deviceId || body.frameDevice.device_id || body.frameDevice.id : null
  ].filter((value) => typeof value === "string" && value.trim());
  for (const candidate of candidates) {
    if (candidate !== expectedDeviceId) fail(field + " returned deviceId " + candidate + " for route deviceId " + expectedDeviceId);
  }
}

function validateRejectedAttempt(attempt, field, allowedStatuses) {
  assertNoSensitive(attempt, field);
  const status = statusFrom(attempt, field);
  if (!allowedStatuses.has(status)) {
    fail(field + ".status must be one of " + Array.from(allowedStatuses).join("/") + ", got " + status);
  }
  const body = responseBody(attempt);
  if (body && body.ok === true) fail(field + " response must not report ok=true");
}

function validateRoute(route, index) {
  if (!isObject(route)) fail("routes[" + index + "] must be an object");
  const kind = kindFromRoute(route);
  const field = "routes[" + index + "](" + kind + ")";
  const attempts = route.attempts || route.results || route.authAttempts || route;
  requiredString(kind, field + ".kind");
  if (route.method !== undefined && typeof route.method !== "string") fail(field + ".method must be a string");
  if (route.path !== undefined && typeof route.path !== "string") fail(field + ".path must be a string");
  optionalIso(route.checkedAt || route.generatedAt, field + ".checkedAt");
  assertNoSensitive(route, field);

  const authorized = firstAttempt(attempts, ["authorized", "validCredential", "valid", "success", "ok"], field);
  const missing = firstAttempt(attempts, ["missingCredential", "missing", "unauthenticated", "noCredential", "withoutCredential"], field);
  const wrong = firstAttempt(attempts, ["wrongCredential", "invalidCredential", "invalid", "badCredential"], field);

  const authorizedStatus = statusFrom(authorized, field + ".attempts.authorized");
  if (authorizedStatus < 200 || authorizedStatus >= 300) fail(field + ".attempts.authorized.status must be 2xx");
  assertNoSensitive(authorized, field + ".attempts.authorized");
  assertBodyDeviceMatches(authorized, deviceIdFromRoute(route, authorized), field + ".attempts.authorized");

  validateRejectedAttempt(missing, field + ".attempts.missingCredential", new Set([401, 403]));
  validateRejectedAttempt(wrong, field + ".attempts.wrongCredential", new Set([401, 403]));

  if (requireMismatch) {
    const mismatch = firstAttempt(attempts, ["mismatchedDevice", "crossDevice", "wrongDevice", "otherDeviceCredential"], field);
    validateRejectedAttempt(mismatch, field + ".attempts.mismatchedDevice", new Set([401, 403, 404]));
  }

  return kind;
}

let payload;
try {
  payload = JSON.parse(fs.readFileSync(file, "utf8"));
} catch (error) {
  fail("invalid JSON: " + error.message);
}

if (!isObject(payload)) fail("device auth contract bundle must be a JSON object");
if (payload.ok === false) fail("device auth contract bundle ok=false");
if (payload.kind !== undefined && payload.kind !== "autopoiesis_frames_device_auth_contract") {
  fail("kind must be autopoiesis_frames_device_auth_contract when present");
}
if (payload.schemaVersion !== undefined && payload.schemaVersion !== 1) fail("schemaVersion must be 1 when present");
optionalIso(payload.generatedAt, "generatedAt");
assertNoSensitive(payload, "bundle");

const routes = extractRoutes(payload);
if (routes.length === 0) fail("at least one route check is required");

const covered = new Set();
routes.forEach((route, index) => covered.add(validateRoute(route, index)));

for (const required of requiredRoutes) {
  if (!covered.has(required)) fail("missing required device auth route coverage: " + required);
}

console.log(
  "device auth contract ok: routes=" + routes.length +
    " covered=" + Array.from(covered).sort().join(",")
);
NODE
