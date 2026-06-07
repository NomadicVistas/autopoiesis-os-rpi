#!/usr/bin/env bash
set -euo pipefail

SOURCE="${1:-${AUTOPOIESIS_COMMAND_POLL_CONTRACT_SOURCE:-}}"
REQUIRE_ELIGIBILITY="${AUTOPOIESIS_REQUIRE_COMMAND_POLL_ELIGIBILITY:-1}"
REQUIRE_DENIED="${AUTOPOIESIS_REQUIRE_COMMAND_POLL_DENIED:-1}"
REQUIRE_AUTHORIZATION="${AUTOPOIESIS_REQUIRE_COMMAND_POLL_AUTHORIZATION:-1}"
TMP_FILE=""

cleanup() {
  if [[ -n "$TMP_FILE" ]]; then
    rm -f "$TMP_FILE"
  fi
}
trap cleanup EXIT

fail() {
  echo "command poll contract check failed: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/command-poll-contract-check.sh <command-poll-contract-bundle.json>
  scripts/command-poll-contract-check.sh https://example/api/admin/frames/command-poll-contract-bundle

Environment:
  AUTOPOIESIS_COMMAND_POLL_CONTRACT_SOURCE  default file or URL when no argument is passed
  AUTOPOIESIS_COMMAND_POLL_CONTRACT_TOKEN   optional bearer token for URL checks
  AUTOPOIESIS_REQUIRE_COMMAND_POLL_ELIGIBILITY require not-due/expired/cancelled exclusion evidence, default 1
  AUTOPOIESIS_REQUIRE_COMMAND_POLL_DENIED      require disabled or unauthorized poll rejection evidence, default 1
  AUTOPOIESIS_REQUIRE_COMMAND_POLL_AUTHORIZATION require authorization metadata on risky commands, default 1

The bundle is read-only staging/CI evidence for hosted command polling state:
durable queued command rows, the authorized device poll response, excluded
ineligible rows, optional denial attempts, and redaction boundaries.
EOF
}

if [[ -z "$SOURCE" ]]; then
  usage
  exit 2
fi

if [[ "$SOURCE" =~ ^https?:// ]]; then
  TMP_FILE="$(mktemp)"
  CURL_ARGS=(-fsS)
  if [[ -n "${AUTOPOIESIS_COMMAND_POLL_CONTRACT_TOKEN:-}" ]]; then
    CURL_ARGS+=(-H "Authorization: Bearer ${AUTOPOIESIS_COMMAND_POLL_CONTRACT_TOKEN}")
  fi
  curl "${CURL_ARGS[@]}" "$SOURCE" >"$TMP_FILE" || fail "could not fetch command poll bundle URL"
  SOURCE="$TMP_FILE"
fi

[[ -f "$SOURCE" ]] || fail "command poll contract bundle file not found: $SOURCE"

node - "$SOURCE" "$REQUIRE_ELIGIBILITY" "$REQUIRE_DENIED" "$REQUIRE_AUTHORIZATION" <<'NODE'
const fs = require("fs");

const file = process.argv[2];
const requireEligibility = process.argv[3] !== "0";
const requireDenied = process.argv[4] !== "0";
const requireAuthorization = process.argv[5] !== "0";

const supportedCommands = new Set([
  "sync_settings",
  "clear_cache",
  "restart_display",
  "enable_device",
  "show_broadcast",
  "restart_device",
  "update_device",
  "disable_device",
  "factory_reset_request"
]);
const riskyCommands = new Set([
  "clear_cache",
  "restart_display",
  "enable_device",
  "show_broadcast",
  "restart_device",
  "update_device",
  "disable_device",
  "factory_reset_request"
]);
const highRiskCommands = new Set([
  "restart_device",
  "update_device",
  "disable_device",
  "factory_reset_request"
]);
const acceptedRoles = new Set(["admin", "owner", "support", "ops", "maintainer", "super_admin"]);
const queuedStatuses = new Set(["queued", "pending", "ready", "retry"]);
const excludedStatuses = new Set(["acknowledged", "processing", "completed", "error", "failed", "denied", "expired", "cancelled"]);
const denialReasons = new Set([
  "device_disabled",
  "device_unpaired",
  "missing_device_key",
  "remote_admin_disabled",
  "unauthorized",
  "owner_mismatch",
  "subscription_inactive",
  "not_eligible",
  "not_found"
]);
const forbiddenPatterns = [
  /deviceApiKey/i,
  /device_api_key/i,
  /pairingCodeHash/i,
  /pairing_code_hash/i,
  /pairingCode/i,
  /pairing_code/i,
  /accessToken/i,
  /refreshToken/i,
  /privateToken/i,
  /adminToken/i,
  /bearer\s+[a-z0-9._~+/-]+/i,
  /secret/i,
  /password/i,
  /artifactUrl/i,
  /artifact_url/i,
  /downloadUrl/i,
  /checksum/i,
  /sha256/i,
  /stdout/i,
  /stderr/i,
  /\/var\/lib\/autopoiesis-os/i,
  /\/opt\/autopoiesis-os/i,
  /\/var\/log\/autopoiesis-os/i,
  /\/home\/frame/i
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

function optionalString(value, field) {
  if (value === undefined || value === null) return;
  if (typeof value !== "string") fail(field + " must be a string when present");
}

function optionalBoolean(value, field) {
  if (value === undefined || value === null) return;
  if (typeof value !== "boolean") fail(field + " must be boolean when present");
}

function firstString(object, names) {
  if (!isObject(object)) return "";
  for (const name of names) {
    const value = object[name];
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  return "";
}

function extractArray(payload, names, field, required = true) {
  for (const name of names) {
    const value = payload[name];
    if (value === undefined || value === null) continue;
    if (Array.isArray(value)) return value;
    if (isObject(value) && Array.isArray(value.items)) return value.items;
    if (isObject(value) && Array.isArray(value.rows)) return value.rows;
    if (isObject(value) && Array.isArray(value.entries)) return value.entries;
    fail(field + " must be an array or paged object when present");
  }
  if (required) fail(field + " is required");
  return [];
}

function nestedId(value) {
  if (!isObject(value)) return "";
  return firstString(value, ["commandId", "command_id", "id"]) ||
    (isObject(value.command) ? firstString(value.command, ["commandId", "command_id", "id"]) : "");
}

function nestedDeviceId(value) {
  if (!isObject(value)) return "";
  return firstString(value, ["deviceId", "device_id"]) ||
    (isObject(value.device) ? firstString(value.device, ["deviceId", "device_id", "id"]) : "");
}

function nestedCommandType(value) {
  if (!isObject(value)) return "";
  return firstString(value, ["commandType", "command_type", "action", "type"]) ||
    (isObject(value.command) ? firstString(value.command, ["commandType", "command_type", "action", "type"]) : "");
}

function nestedStatus(value) {
  if (!isObject(value)) return "";
  return firstString(value, ["status", "commandStatus", "command_status", "state"]) ||
    (isObject(value.command) ? firstString(value.command, ["status", "commandStatus", "command_status", "state"]) : "");
}

function commandPayload(value) {
  if (!isObject(value)) return {};
  if (isObject(value.payload)) return value.payload;
  if (isObject(value.command) && isObject(value.command.payload)) return value.command.payload;
  return {};
}

function commandAuthorization(value) {
  const payload = commandPayload(value);
  if (isObject(payload.authorization)) return payload.authorization;
  if (isObject(value.authorization)) return value.authorization;
  if (isObject(value.command) && isObject(value.command.authorization)) return value.command.authorization;
  return null;
}

function responseStatus(value) {
  if (!isObject(value)) return null;
  const status = Number(value.httpStatus ?? value.statusCode ?? value.responseStatus ?? value.code ?? value.status);
  return Number.isInteger(status) ? status : null;
}

function pollCommands(poll) {
  if (!isObject(poll)) fail("authorizedPoll must be an object");
  const response = isObject(poll.response) ? poll.response : poll;
  return extractArray(response, ["commands", "commandQueue", "queuedCommands", "items", "rows"], "authorizedPoll.commands");
}

function assertNoSensitive(value, field) {
  const raw = JSON.stringify(value);
  for (const pattern of forbiddenPatterns) {
    if (pattern.test(raw)) fail(field + " exposes forbidden sensitive or local-only data: " + pattern);
  }
  const seen = new Set();
  function walk(current, path) {
    if (current === null || current === undefined) return;
    if (typeof current !== "object") return;
    if (seen.has(current)) return;
    seen.add(current);
    if (Array.isArray(current)) {
      current.forEach((entry, index) => walk(entry, path + "[" + index + "]"));
      return;
    }
    for (const [key, child] of Object.entries(current)) {
      if (/payload/i.test(key) && isObject(child)) {
        const allowedPayloadKeys = new Set([
          "authorization",
          "commandId",
          "command_id",
          "broadcastId",
          "broadcast_id",
          "releaseId",
          "release_id",
          "rolloutId",
          "rollout_id",
          "version",
          "settings",
          "preferences",
          "duration",
          "durationSeconds",
          "expiresAt",
          "startsAt",
          "title",
          "body",
          "message",
          "reason",
          "priority",
          "cacheAllowed",
          "targeting",
          "target"
        ]);
        for (const payloadKey of Object.keys(child)) {
          if (!allowedPayloadKeys.has(payloadKey)) {
            fail(path + "." + key + " exposes unsupported raw payload key: " + payloadKey);
          }
        }
      }
      walk(child, path + "." + key);
    }
  }
  walk(value, field);
}

function validateAuthorization(auth, field, commandType) {
  if (!isObject(auth)) fail(field + " authorization is required");
  if (auth.approved !== true) fail(field + ".approved must be true");
  const action = firstString(auth, ["action", "commandType", "command_type"]);
  if (action && action !== commandType) fail(field + ".action must match command type");
  requiredString(firstString(auth, ["actorId", "actor_id"]), field + ".actorId");
  const role = firstString(auth, ["actorRole", "actor_role", "role"]);
  if (!acceptedRoles.has(role)) fail(field + ".actorRole is not accepted: " + (role || "missing"));
  optionalIso(auth.authorizedAt || auth.authorized_at, field + ".authorizedAt");
  const auditId = firstString(auth, ["auditId", "audit_id", "adminAuditId", "admin_audit_id"]);
  if (highRiskCommands.has(commandType) && !auditId) fail(field + ".auditId is required for high/critical commands");
  optionalString(auditId || undefined, field + ".auditId");
  optionalBoolean(auth.localConfirmationRequired ?? auth.local_confirmation_required, field + ".localConfirmationRequired");
  if (commandType === "factory_reset_request" && (auth.localConfirmationRequired ?? auth.local_confirmation_required) !== true) {
    fail(field + ".localConfirmationRequired must be true for factory_reset_request");
  }
}

function validateCommand(command, field, expectedDeviceId) {
  if (!isObject(command)) fail(field + " must be an object");
  const commandId = nestedId(command);
  const deviceId = nestedDeviceId(command);
  const commandType = nestedCommandType(command);
  requiredString(commandId, field + ".commandId");
  requiredString(deviceId, field + ".deviceId");
  if (expectedDeviceId && deviceId !== expectedDeviceId) fail(field + ".deviceId must match authorized poll device");
  if (!supportedCommands.has(commandType)) fail(field + ".commandType is unsupported: " + (commandType || "missing"));
  optionalIso(command.createdAt || command.created_at, field + ".createdAt");
  optionalIso(command.notBefore || command.not_before, field + ".notBefore");
  optionalIso(command.expiresAt || command.expires_at, field + ".expiresAt");
  optionalString(firstString(command, ["dedupeKey", "dedupe_key", "idempotencyKey", "idempotency_key"]) || undefined, field + ".dedupeKey");
  const status = nestedStatus(command);
  if (requireAuthorization && riskyCommands.has(commandType)) {
    validateAuthorization(commandAuthorization(command), field, commandType);
  }
  return { commandId, deviceId, commandType, status };
}

function validateDeniedPoll(poll, index) {
  if (!isObject(poll)) fail("deniedPolls[" + index + "] must be an object");
  const status = responseStatus(poll.response || poll);
  if (!Number.isInteger(status) || ![401, 403, 404, 409, 423].includes(status)) {
    fail("deniedPolls[" + index + "] must have a rejecting HTTP status");
  }
  const reason = firstString(poll, ["reason", "code", "error"]) ||
    (isObject(poll.response) ? firstString(poll.response, ["reason", "code", "error"]) : "");
  if (reason && !denialReasons.has(reason)) {
    fail("deniedPolls[" + index + "] has unrecognized reason: " + reason);
  }
  const response = isObject(poll.response) ? poll.response : poll;
  const leakedCommands = Array.isArray(response.commands)
    ? response.commands
    : Array.isArray(response.commandQueue)
      ? response.commandQueue
      : Array.isArray(response.queuedCommands)
        ? response.queuedCommands
        : [];
  const leaked = leakedCommands.length > 0;
  if (leaked) fail("deniedPolls[" + index + "] must not return commands");
}

let payload;
try {
  payload = JSON.parse(fs.readFileSync(file, "utf8"));
} catch (error) {
  fail("could not parse JSON: " + error.message);
}

if (!isObject(payload)) fail("bundle root must be an object");
if (payload.kind && payload.kind !== "autopoiesis_frames_command_poll_contract") {
  fail("unexpected bundle kind: " + payload.kind);
}
if (payload.schemaVersion !== undefined && Number(payload.schemaVersion) !== 1) {
  fail("unsupported schemaVersion: " + payload.schemaVersion);
}
optionalIso(payload.generatedAt || payload.generated_at, "generatedAt");
assertNoSensitive(payload, "bundle");

const deviceId = firstString(payload, ["deviceId", "device_id"]) ||
  (isObject(payload.device) ? firstString(payload.device, ["deviceId", "device_id", "id"]) : "");
requiredString(deviceId, "deviceId");

const durableRows = extractArray(
  payload,
  ["commands", "commandRows", "durableCommands", "queuedCommands", "deviceCommands"],
  "commands"
);
if (durableRows.length === 0) fail("commands must include at least one durable row");

const rowsById = new Map();
let eligibleRowCount = 0;
durableRows.forEach((row, index) => {
  const normalized = validateCommand(row, "commands[" + index + "]", "");
  if (rowsById.has(normalized.commandId)) fail("duplicate durable command id: " + normalized.commandId);
  rowsById.set(normalized.commandId, normalized);
  if (normalized.deviceId === deviceId && queuedStatuses.has(normalized.status)) eligibleRowCount += 1;
});
if (eligibleRowCount === 0) fail("commands must include at least one queued row for the authorized device");

const authorizedPoll = payload.authorizedPoll || payload.poll || payload.commandPoll || payload.devicePoll;
if (!isObject(authorizedPoll)) fail("authorizedPoll/poll is required");
const pollStatus = responseStatus(authorizedPoll.response || authorizedPoll);
if (Number.isInteger(pollStatus) && (pollStatus < 200 || pollStatus >= 300)) {
  fail("authorizedPoll must be a successful response");
}
const returnedCommands = pollCommands(authorizedPoll);
if (returnedCommands.length === 0) fail("authorizedPoll must return at least one command");

const returnedIds = new Set();
returnedCommands.forEach((command, index) => {
  const normalized = validateCommand(command, "authorizedPoll.commands[" + index + "]", deviceId);
  if (returnedIds.has(normalized.commandId)) fail("authorizedPoll returns duplicate command id: " + normalized.commandId);
  returnedIds.add(normalized.commandId);
  const row = rowsById.get(normalized.commandId);
  if (!row) fail("authorizedPoll returns command not present in durable rows: " + normalized.commandId);
  if (row.deviceId !== deviceId) fail("authorizedPoll returns command for another device: " + normalized.commandId);
  if (!queuedStatuses.has(row.status)) fail("authorizedPoll returns non-queued durable command: " + normalized.commandId);
  if (row.commandType !== normalized.commandType) fail("authorizedPoll command type does not match durable row: " + normalized.commandId);
});

const expectedPollIds = [...rowsById.values()]
  .filter(row => row.deviceId === deviceId && queuedStatuses.has(row.status))
  .map(row => row.commandId);
for (const id of expectedPollIds) {
  if (!returnedIds.has(id)) fail("authorizedPoll omits queued command for device: " + id);
}

if (requireEligibility) {
  const excluded = extractArray(
    payload,
    ["excludedCommands", "ineligibleCommands", "notPollableCommands"],
    "excludedCommands",
    false
  );
  if (excluded.length === 0) fail("excludedCommands evidence is required");
  let sawNotDue = false;
  let sawExpiredOrTerminal = false;
  excluded.forEach((command, index) => {
    const normalized = validateCommand(command, "excludedCommands[" + index + "]", "");
    if (returnedIds.has(normalized.commandId)) fail("excluded command was returned by authorized poll: " + normalized.commandId);
    const reason = firstString(command, ["reason", "exclusionReason", "exclusion_reason"]);
    if (reason === "not_due" || reason === "scheduled_for_future") sawNotDue = true;
    if (["expired", "cancelled", "completed", "failed", "terminal_status"].includes(reason) || excludedStatuses.has(normalized.status)) {
      sawExpiredOrTerminal = true;
    }
  });
  if (!sawNotDue) fail("excludedCommands must include not-due/scheduled evidence");
  if (!sawExpiredOrTerminal) fail("excludedCommands must include expired/cancelled/terminal evidence");
}

if (requireDenied) {
  const deniedPolls = extractArray(payload, ["deniedPolls", "rejectedPolls", "blockedPolls"], "deniedPolls", false);
  if (deniedPolls.length === 0) fail("deniedPolls evidence is required");
  deniedPolls.forEach(validateDeniedPoll);
}

console.log(
  [
    "Autopoiesis command poll contract ok",
    "device=" + deviceId,
    "durableRows=" + durableRows.length,
    "returned=" + returnedCommands.length,
    "eligible=" + expectedPollIds.length
  ].join(" ")
);
NODE
