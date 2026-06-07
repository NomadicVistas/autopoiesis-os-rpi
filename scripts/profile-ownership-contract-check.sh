#!/usr/bin/env bash
set -euo pipefail

SOURCE="${1:-${AUTOPOIESIS_PROFILE_OWNERSHIP_CONTRACT_SOURCE:-}}"
REQUIRED_CHECKS="${AUTOPOIESIS_PROFILE_OWNERSHIP_REQUIRE_CHECKS:-owned-list,owned-read,owned-settings-write,cross-owner-read,cross-owner-settings-write,cross-owner-command,anonymous-profile,admin-fleet-read}"
TMP_FILE=""

cleanup() {
  if [[ -n "$TMP_FILE" ]]; then
    rm -f "$TMP_FILE"
  fi
}
trap cleanup EXIT

fail() {
  echo "profile ownership contract check failed: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/profile-ownership-contract-check.sh <profile-ownership-contract-bundle.json>
  scripts/profile-ownership-contract-check.sh https://example/api/admin/frames/profile-ownership-contract-bundle

Environment:
  AUTOPOIESIS_PROFILE_OWNERSHIP_CONTRACT_SOURCE default file or URL when no argument is passed
  AUTOPOIESIS_PROFILE_OWNERSHIP_CONTRACT_TOKEN  optional bearer token for URL checks
  AUTOPOIESIS_PROFILE_OWNERSHIP_REQUIRE_CHECKS  comma-separated required checks, default:
                                                owned-list,owned-read,owned-settings-write,cross-owner-read,
                                                cross-owner-settings-write,cross-owner-command,anonymous-profile,
                                                admin-fleet-read

The bundle is read-only staging/CI evidence. It should prove that Profile >
Frames routes are scoped to the authenticated account/session, that cross-owner
device reads/writes/commands are rejected, and that Admin fleet access remains
separate from ordinary profile ownership.
EOF
}

if [[ -z "$SOURCE" ]]; then
  usage
  exit 2
fi

if [[ "$SOURCE" =~ ^https?:// ]]; then
  TMP_FILE="$(mktemp)"
  CURL_ARGS=(-fsS)
  if [[ -n "${AUTOPOIESIS_PROFILE_OWNERSHIP_CONTRACT_TOKEN:-}" ]]; then
    CURL_ARGS+=(-H "Authorization: Bearer ${AUTOPOIESIS_PROFILE_OWNERSHIP_CONTRACT_TOKEN}")
  fi
  curl "${CURL_ARGS[@]}" "$SOURCE" >"$TMP_FILE" || fail "could not fetch profile ownership contract URL"
  SOURCE="$TMP_FILE"
fi

[[ -f "$SOURCE" ]] || fail "profile ownership contract bundle file not found: $SOURCE"

node - "$SOURCE" "$REQUIRED_CHECKS" <<'NODE'
const fs = require("fs");

const [file, requiredChecksValue] = process.argv.slice(2);
const requiredChecks = String(requiredChecksValue || "")
  .split(",")
  .map((entry) => normalizeKind(entry.trim()))
  .filter(Boolean);

const sensitiveKeyPatterns = [
  /^deviceApiKey$/i,
  /^device_api_key$/i,
  /^apiKey$/i,
  /^api_key$/i,
  /^pairingCode$/i,
  /^pairing_code$/i,
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
  return value.trim();
}

function normalizeKind(value) {
  const text = String(value || "").trim().toLowerCase().replace(/_/g, "-");
  if (!text) return "";
  if (text === "list" || text.includes("owned-list") || text.includes("my-frames")) return "owned-list";
  if (text === "read-owned" || text.includes("owned-read") || text.includes("owned-device-read")) return "owned-read";
  if (text.includes("owned-settings") || text.includes("own-settings")) return "owned-settings-write";
  if (text.includes("cross-owner-read") || text.includes("other-device-read")) return "cross-owner-read";
  if (text.includes("cross-owner-settings") || text.includes("other-settings")) return "cross-owner-settings-write";
  if (text.includes("cross-owner-command") || text.includes("other-command")) return "cross-owner-command";
  if (text.includes("anonymous") || text.includes("unauthenticated")) return "anonymous-profile";
  if (text.includes("admin-fleet") || text.includes("admin-read")) return "admin-fleet-read";
  return text;
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
        !/redacted|hidden|omitted|masked|present|valid|invalid|missing|wrong|session-authenticated/i.test(current)
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
      walk(child, path + "." + key);
    }
  }
  walk(value, field);
}

function statusFrom(check, field) {
  if (!isObject(check)) fail(field + " must be an object");
  const status = Number(check.status ?? check.statusCode ?? check.httpStatus ?? check.code);
  if (!Number.isInteger(status)) fail(field + ".status is required");
  return status;
}

function bodyFrom(check) {
  const body = check.body ?? check.response ?? check.result ?? check.payload ?? null;
  return isObject(body) ? body : null;
}

function actorFrom(check) {
  return check.actorUserId || check.actor_user_id || check.userId || check.user_id || check.subjectUserId || check.subject_user_id || "";
}

function targetDeviceFrom(check) {
  return check.targetDeviceId || check.target_device_id || check.deviceId || check.device_id || "";
}

function expectedOwnerFrom(check) {
  return check.expectedOwnerUserId || check.expected_owner_user_id || check.ownerUserId || check.owner_user_id || "";
}

function deviceRowsFrom(value) {
  if (!value) return [];
  if (Array.isArray(value)) return value.filter(isObject);
  if (Array.isArray(value.devices)) return value.devices.filter(isObject);
  if (Array.isArray(value.items)) return value.items.filter(isObject);
  if (Array.isArray(value.frames)) return value.frames.filter(isObject);
  if (Array.isArray(value.fleetDevices)) return value.fleetDevices.filter(isObject);
  if (isObject(value.profileFrames)) return deviceRowsFrom(value.profileFrames);
  if (isObject(value.adminFrames)) return deviceRowsFrom(value.adminFrames);
  if (isObject(value.device)) return [value.device];
  if (isObject(value.frameDevice)) return [value.frameDevice];
  if (typeof (value.deviceId || value.device_id || value.id) === "string") return [value];
  return [];
}

function rowDeviceId(row) {
  return row.deviceId || row.device_id || row.id || "";
}

function rowOwnerId(row) {
  return row.ownerUserId || row.owner_user_id || row.userId || row.user_id || row.ownerId || row.owner_id || "";
}

function validateAccepted(check, field) {
  const status = statusFrom(check, field);
  if (status < 200 || status >= 300) fail(field + ".status must be 2xx");
  const body = bodyFrom(check);
  if (body && body.ok === false) fail(field + " body must not report ok=false");
  return body;
}

function validateRejected(check, field, allowedStatuses = new Set([401, 403, 404])) {
  const status = statusFrom(check, field);
  if (!allowedStatuses.has(status)) {
    fail(field + ".status must be one of " + Array.from(allowedStatuses).join("/") + ", got " + status);
  }
  const body = bodyFrom(check);
  if (body && body.ok === true) fail(field + " body must not report ok=true");
  const rows = deviceRowsFrom(body);
  if (rows.length > 0) fail(field + " rejected response must not include device rows");
}

function validateOwnedList(check, field) {
  const body = validateAccepted(check, field);
  const actorUserId = requiredString(actorFrom(check), field + ".actorUserId");
  const rows = deviceRowsFrom(body);
  if (rows.length === 0) fail(field + " must include at least one owned device row");
  const allowed = new Set((check.allowedDeviceIds || check.allowed_device_ids || []).filter(Boolean));
  const forbidden = new Set((check.forbiddenDeviceIds || check.forbidden_device_ids || []).filter(Boolean));
  for (const row of rows) {
    const ownerUserId = rowOwnerId(row);
    if (ownerUserId && ownerUserId !== actorUserId) {
      fail(field + " returned device owned by another user: " + rowDeviceId(row));
    }
    if (forbidden.has(rowDeviceId(row))) fail(field + " returned forbidden deviceId " + rowDeviceId(row));
  }
  for (const deviceId of allowed) {
    if (!rows.some((row) => rowDeviceId(row) === deviceId)) fail(field + " missing expected owned deviceId " + deviceId);
  }
}

function validateOwnedDevice(check, field) {
  const body = validateAccepted(check, field);
  const actorUserId = requiredString(actorFrom(check), field + ".actorUserId");
  const targetDeviceId = requiredString(targetDeviceFrom(check), field + ".targetDeviceId");
  const rows = deviceRowsFrom(body);
  if (rows.length === 0) fail(field + " must include the owned device row");
  if (!rows.some((row) => rowDeviceId(row) === targetDeviceId)) fail(field + " did not return targetDeviceId " + targetDeviceId);
  for (const row of rows) {
    const ownerUserId = rowOwnerId(row);
    if (ownerUserId && ownerUserId !== actorUserId) fail(field + " returned a device for a different owner");
  }
}

function validateAdminFleetRead(check, field) {
  const body = validateAccepted(check, field);
  const role = String(check.actorRole || check.actor_role || check.role || "").toLowerCase();
  if (!["admin", "ops", "support", "maintainer", "super_admin"].includes(role)) {
    fail(field + ".actorRole must be an admin/support role");
  }
  const rows = deviceRowsFrom(body);
  if (rows.length < 2) fail(field + " must include at least two fleet devices so cross-owner visibility is explicit");
  const owners = new Set(rows.map(rowOwnerId).filter(Boolean));
  if (owners.size < 2) fail(field + " must include devices from at least two owners");
}

function extractChecks(payload) {
  if (Array.isArray(payload.checks)) return payload.checks;
  const source = payload.checks || payload.profileOwnership || payload.profile_ownership || payload.ownership || payload;
  const mappings = [
    ["owned-list", ["ownedList", "profileList", "myFramesList"]],
    ["owned-read", ["ownedDeviceRead", "ownedRead", "profileDeviceRead"]],
    ["owned-settings-write", ["ownedSettingsWrite", "ownSettingsWrite", "profileSettingsWrite"]],
    ["cross-owner-read", ["crossOwnerRead", "otherOwnerRead", "crossOwnerDeviceRead"]],
    ["cross-owner-settings-write", ["crossOwnerSettingsWrite", "otherOwnerSettingsWrite"]],
    ["cross-owner-command", ["crossOwnerCommand", "otherOwnerCommand"]],
    ["anonymous-profile", ["anonymousProfile", "unauthenticatedProfile"]],
    ["admin-fleet-read", ["adminFleetRead", "adminRead"]]
  ];
  const checks = [];
  for (const [kind, names] of mappings) {
    for (const name of names) {
      if (source[name] !== undefined && source[name] !== null) {
        checks.push({ kind, ...source[name] });
        break;
      }
    }
  }
  return checks;
}

let payload;
try {
  payload = JSON.parse(fs.readFileSync(file, "utf8"));
} catch (error) {
  fail("invalid JSON: " + error.message);
}

if (!isObject(payload)) fail("profile ownership contract bundle must be a JSON object");
if (payload.ok === false) fail("profile ownership contract bundle ok=false");
if (payload.schemaVersion !== undefined && payload.schemaVersion !== 1) fail("schemaVersion must be 1 when present");
optionalIso(payload.generatedAt, "generatedAt");
assertNoSensitive(payload, "bundle");

const checks = extractChecks(payload);
if (!Array.isArray(checks) || checks.length === 0) fail("checks collection is required");

const byKind = new Map();
checks.forEach((check, index) => {
  if (!isObject(check)) fail("checks[" + index + "] must be an object");
  const kind = normalizeKind(check.kind || check.name || check.id || check.operation || check.routeKind);
  if (!kind) fail("checks[" + index + "].kind is required");
  if (byKind.has(kind)) fail("duplicate check kind: " + kind);
  optionalIso(check.checkedAt || check.generatedAt, "checks[" + index + "].checkedAt");
  assertNoSensitive(check, "checks[" + index + "](" + kind + ")");
  byKind.set(kind, check);
});

for (const kind of requiredChecks) {
  if (!byKind.has(kind)) fail("missing required check: " + kind);
}

for (const [kind, check] of byKind.entries()) {
  const field = "checks." + kind;
  if (kind === "owned-list") validateOwnedList(check, field);
  else if (kind === "owned-read") validateOwnedDevice(check, field);
  else if (kind === "owned-settings-write") validateOwnedDevice(check, field);
  else if (kind === "cross-owner-read") {
    requiredString(actorFrom(check), field + ".actorUserId");
    requiredString(targetDeviceFrom(check), field + ".targetDeviceId");
    requiredString(expectedOwnerFrom(check), field + ".expectedOwnerUserId");
    if (actorFrom(check) === expectedOwnerFrom(check)) fail(field + " actor must differ from target owner");
    validateRejected(check, field);
  } else if (kind === "cross-owner-settings-write") {
    requiredString(actorFrom(check), field + ".actorUserId");
    requiredString(targetDeviceFrom(check), field + ".targetDeviceId");
    requiredString(expectedOwnerFrom(check), field + ".expectedOwnerUserId");
    if (actorFrom(check) === expectedOwnerFrom(check)) fail(field + " actor must differ from target owner");
    validateRejected(check, field);
  } else if (kind === "cross-owner-command") {
    requiredString(actorFrom(check), field + ".actorUserId");
    requiredString(targetDeviceFrom(check), field + ".targetDeviceId");
    requiredString(expectedOwnerFrom(check), field + ".expectedOwnerUserId");
    if (actorFrom(check) === expectedOwnerFrom(check)) fail(field + " actor must differ from target owner");
    validateRejected(check, field);
  } else if (kind === "anonymous-profile") {
    validateRejected(check, field, new Set([401, 403]));
  } else if (kind === "admin-fleet-read") {
    validateAdminFleetRead(check, field);
  }
}

console.log("profile ownership contract ok: " + Array.from(byKind.keys()).join(","));
NODE
