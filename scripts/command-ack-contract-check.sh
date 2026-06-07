#!/usr/bin/env bash
set -euo pipefail

SOURCE="${1:-${AUTOPOIESIS_COMMAND_ACK_CONTRACT_SOURCE:-}}"
REQUIRE_ADMIN_AUDITS="${AUTOPOIESIS_REQUIRE_COMMAND_ACK_ADMIN_AUDITS:-1}"
REQUIRE_DEVICE_EVENTS="${AUTOPOIESIS_REQUIRE_COMMAND_ACK_DEVICE_EVENTS:-1}"
REQUIRE_DUPLICATE_ACK="${AUTOPOIESIS_REQUIRE_COMMAND_ACK_DUPLICATE:-1}"
TMP_FILE=""

cleanup() {
  if [[ -n "$TMP_FILE" ]]; then
    rm -f "$TMP_FILE"
  fi
}
trap cleanup EXIT

fail() {
  echo "command ack contract check failed: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/command-ack-contract-check.sh <command-ack-contract-bundle.json>
  scripts/command-ack-contract-check.sh https://example/api/admin/frames/command-ack-contract-bundle

Environment:
  AUTOPOIESIS_COMMAND_ACK_CONTRACT_SOURCE  default file or URL when no argument is passed
  AUTOPOIESIS_COMMAND_ACK_CONTRACT_TOKEN   optional bearer token for URL checks
  AUTOPOIESIS_REQUIRE_COMMAND_ACK_ADMIN_AUDITS require admin audit rows, default 1
  AUTOPOIESIS_REQUIRE_COMMAND_ACK_DEVICE_EVENTS require command_audit device events, default 1
  AUTOPOIESIS_REQUIRE_COMMAND_ACK_DUPLICATE require duplicate final-ack idempotency evidence, default 1

The bundle is read-only staging/CI evidence for hosted command acknowledgement
state: queued command rows, acknowledgement attempts, updated durable command
rows, matching admin audit status, heartbeat-ingested command_audit events, and
duplicate final acknowledgement idempotency.
EOF
}

if [[ -z "$SOURCE" ]]; then
  usage
  exit 2
fi

if [[ "$SOURCE" =~ ^https?:// ]]; then
  TMP_FILE="$(mktemp)"
  CURL_ARGS=(-fsS)
  if [[ -n "${AUTOPOIESIS_COMMAND_ACK_CONTRACT_TOKEN:-}" ]]; then
    CURL_ARGS+=(-H "Authorization: Bearer ${AUTOPOIESIS_COMMAND_ACK_CONTRACT_TOKEN}")
  fi
  curl "${CURL_ARGS[@]}" "$SOURCE" >"$TMP_FILE" || fail "could not fetch command ack bundle URL"
  SOURCE="$TMP_FILE"
fi

[[ -f "$SOURCE" ]] || fail "command ack contract bundle file not found: $SOURCE"

node - "$SOURCE" "$REQUIRE_ADMIN_AUDITS" "$REQUIRE_DEVICE_EVENTS" "$REQUIRE_DUPLICATE_ACK" <<'NODE'
const fs = require("fs");

const file = process.argv[2];
const requireAdminAudits = process.argv[3] !== "0";
const requireDeviceEvents = process.argv[4] !== "0";
const requireDuplicateAck = process.argv[5] !== "0";

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
const acceptedRoles = new Set(["admin", "owner", "support", "ops", "maintainer", "super_admin"]);
const commandStatuses = new Set([
  "queued",
  "pending",
  "sent",
  "acknowledged",
  "processing",
  "completed",
  "error",
  "failed",
  "denied",
  "expired",
  "cancelled"
]);
const ackStatuses = new Set(["acknowledged", "processing", "completed", "error", "failed", "denied"]);
const finalAckStatuses = new Set(["completed", "error", "failed", "denied"]);
const auditStatuses = new Set([
  "approved",
  "queued",
  "sent",
  "acknowledged",
  "processing",
  "completed",
  "error",
  "failed",
  "denied",
  "expired",
  "cancelled"
]);
const forbiddenPatterns = [
  /deviceApiKey/i,
  /device_api_key/i,
  /pairingCodeHash/i,
  /pairing_code_hash/i,
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

function requiredIso(value, field) {
  if (!validIso(value)) fail(field + " is required and must be an ISO timestamp");
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

function nestedDeviceId(value) {
  if (!isObject(value)) return "";
  return firstString(value, ["deviceId", "device_id"]) ||
    (isObject(value.device) ? firstString(value.device, ["deviceId", "device_id", "id"]) : "") ||
    (isObject(value.payload) ? firstString(value.payload, ["deviceId", "device_id"]) : "");
}

function nestedCommandId(value) {
  if (!isObject(value)) return "";
  return firstString(value, ["commandId", "command_id", "id"]) ||
    (isObject(value.command) ? firstString(value.command, ["id", "commandId", "command_id"]) : "") ||
    (isObject(value.payload) ? firstString(value.payload, ["commandId", "command_id"]) : "");
}

function nestedCommandType(value) {
  if (!isObject(value)) return "";
  return firstString(value, ["commandType", "command_type", "action", "type"]) ||
    (isObject(value.command) ? firstString(value.command, ["commandType", "command_type", "action", "type"]) : "") ||
    (isObject(value.payload) ? firstString(value.payload, ["commandType", "command_type", "action", "type"]) : "");
}

function ackStatus(value) {
  if (!isObject(value)) return "";
  const explicit = firstString(value, ["ackStatus", "ack_status", "submittedStatus", "submitted_status", "commandStatus", "command_status", "resultStatus", "result_status"]);
  if (ackStatuses.has(explicit)) return explicit;
  const nested = isObject(value.ack) ? firstString(value.ack, ["status", "ackStatus", "submittedStatus"]) : "";
  if (ackStatuses.has(nested)) return nested;
  const fallback = firstString(value, ["status", "state"]);
  return ackStatuses.has(fallback) ? fallback : "";
}

function responseStatus(value) {
  if (!isObject(value)) return null;
  const status = Number(value.httpStatus ?? value.statusCode ?? value.responseStatus ?? value.code);
  return Number.isInteger(status) ? status : null;
}

function validateAuthorization(auth, field, expectedAction) {
  if (!isObject(auth)) fail(field + " authorization is required when present");
  if (auth.approved !== true) fail(field + ".approved must be true");
  const action = firstString(auth, ["action", "commandType", "command_type"]);
  if (action && action !== expectedAction) fail(field + ".action must match command type");
  requiredString(firstString(auth, ["actorId", "actor_id"]), field + ".actorId");
  const role = firstString(auth, ["actorRole", "actor_role", "role"]);
  if (!acceptedRoles.has(role)) fail(field + ".actorRole is not accepted: " + (role || "missing"));
  optionalString(firstString(auth, ["auditId", "audit_id", "adminAuditId", "admin_audit_id"]), field + ".auditId");
  optionalIso(auth.authorizedAt || auth.authorized_at, field + ".authorizedAt");
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
          "commandType",
          "command_type",
          "deviceId",
          "device_id",
          "broadcastId",
          "broadcast_id",
          "releaseId",
          "release_id",
          "rolloutId",
          "rollout_id",
          "status",
          "reason",
          "error"
        ]);
        const extra = Object.keys(child).filter((payloadKey) => !allowedPayloadKeys.has(payloadKey));
        if (extra.length) fail(path + "." + key + " exposes raw command payload keys: " + extra.join(", "));
      }
      walk(child, path + "." + key);
    }
  }
  walk(value, field);
}

let payload;
try {
  payload = JSON.parse(fs.readFileSync(file, "utf8"));
} catch (error) {
  fail("invalid JSON: " + error.message);
}

if (!isObject(payload)) fail("command ack bundle root must be an object");
if (payload.ok === false) fail("command ack bundle ok=false");
if (payload.schemaVersion !== undefined && payload.schemaVersion !== 1) fail("schemaVersion must be 1 when present");
if (payload.kind !== undefined && payload.kind !== "autopoiesis_frames_command_ack_contract") {
  fail("kind must be autopoiesis_frames_command_ack_contract when present");
}
optionalIso(payload.generatedAt, "generatedAt");
assertNoSensitive(payload, "bundle");

const commands = extractArray(payload, ["commands", "commandRows", "deviceCommands", "queuedCommands"], "commands");
const acknowledgements = extractArray(payload, ["acknowledgements", "acknowledgments", "ackAttempts", "acks", "commandAcks"], "acknowledgements");
const audits = extractArray(payload, ["adminAudits", "audits", "commandAudits"], "adminAudits", requireAdminAudits);
const events = extractArray(payload, ["deviceEvents", "events", "commandEvents"], "deviceEvents", requireDeviceEvents);

const commandById = new Map();
let completedCommands = 0;
for (const [index, command] of commands.entries()) {
  const field = "commands[" + index + "]";
  if (!isObject(command)) fail(field + " must be an object");
  const id = nestedCommandId(command);
  requiredString(id, field + ".id");
  if (commandById.has(id)) fail("duplicate command id: " + id);
  const deviceId = nestedDeviceId(command);
  requiredString(deviceId, field + ".deviceId");
  const type = nestedCommandType(command);
  if (!supportedCommands.has(type)) fail(field + ".commandType is unsupported: " + (type || "missing"));
  const status = firstString(command, ["status", "state"]) || "queued";
  if (!commandStatuses.has(status)) fail(field + ".status is not recognized: " + status);
  optionalIso(command.createdAt || command.created_at || command.queuedAt || command.queued_at, field + ".createdAt");
  optionalIso(command.acknowledgedAt || command.acknowledged_at, field + ".acknowledgedAt");
  optionalIso(command.completedAt || command.completed_at, field + ".completedAt");
  optionalIso(command.failedAt || command.failed_at || command.errorAt || command.error_at, field + ".errorAt");
  optionalString(firstString(command, ["error", "failureReason", "failure_reason", "denialReason", "denial_reason"]), field + ".error");
  optionalBoolean(command.remoteEnabled ?? command.remote_enabled, field + ".remoteEnabled");
  const auth = command.authorization || (isObject(command.payload) ? command.payload.authorization : null);
  if (auth) validateAuthorization(auth, field + ".authorization", type);
  if (finalAckStatuses.has(status)) completedCommands += 1;
  commandById.set(id, { id, deviceId, type, status, command, index });
}

let acknowledgedAcks = 0;
let finalAcks = 0;
let duplicateFinalAcks = 0;
const ackIds = new Set();
for (const [index, acknowledgement] of acknowledgements.entries()) {
  const field = "acknowledgements[" + index + "]";
  if (!isObject(acknowledgement)) fail(field + " must be an object");
  const ackId = firstString(acknowledgement, ["id", "ackId", "ack_id", "requestId", "request_id"]);
  if (ackId) {
    if (ackIds.has(ackId)) fail("duplicate acknowledgement id: " + ackId);
    ackIds.add(ackId);
  }
  const commandId = nestedCommandId(acknowledgement);
  requiredString(commandId, field + ".commandId");
  const command = commandById.get(commandId);
  if (!command) fail(field + ".commandId references unknown command: " + commandId);
  const deviceId = nestedDeviceId(acknowledgement) || command.deviceId;
  if (deviceId !== command.deviceId) fail(field + ".deviceId does not match command deviceId");
  const status = ackStatus(acknowledgement);
  if (!ackStatuses.has(status)) fail(field + ".ackStatus is required and must be recognized");
  const httpStatus = responseStatus(acknowledgement);
  if (httpStatus !== null) {
    const duplicate = acknowledgement.duplicate === true || acknowledgement.retry === true || acknowledgement.idempotent === true;
    const ok = httpStatus >= 200 && httpStatus < 300;
    const harmlessDuplicate = duplicate && [200, 202, 204, 208, 409].includes(httpStatus);
    if (!ok && !harmlessDuplicate) fail(field + ".httpStatus must show an accepted or harmless duplicate acknowledgement");
  }
  optionalIso(acknowledgement.submittedAt || acknowledgement.submitted_at || acknowledgement.acknowledgedAt || acknowledgement.acknowledged_at, field + ".submittedAt");
  optionalString(firstString(acknowledgement, ["error", "reason"]), field + ".error");
  if (status === "acknowledged") {
    acknowledgedAcks += 1;
    if (!validIso(command.command.acknowledgedAt || command.command.acknowledged_at)) {
      fail(field + " acknowledged command but durable command row lacks acknowledgedAt");
    }
  }
  if (finalAckStatuses.has(status)) {
    finalAcks += 1;
    if (!finalAckStatuses.has(command.status)) fail(field + " final acknowledgement did not leave durable command row terminal");
    if (status === "completed") {
      requiredIso(command.command.completedAt || command.command.completed_at, "commands[" + command.index + "].completedAt");
    } else if (!validIso(command.command.failedAt || command.command.failed_at || command.command.errorAt || command.command.error_at || command.command.completedAt || command.command.completed_at)) {
      fail(field + " terminal error/denied acknowledgement needs failedAt/errorAt/completedAt evidence");
    }
    if (acknowledgement.duplicate === true || acknowledgement.retry === true || acknowledgement.idempotent === true || acknowledgement.effect === "no_change") {
      if (acknowledgement.idempotent === false || acknowledgement.effect === "duplicate_created") {
        fail(field + " duplicate final acknowledgement must be idempotent/no_change");
      }
      duplicateFinalAcks += 1;
    }
  }
}

if (acknowledgedAcks === 0) fail("acknowledgements must include at least one acknowledged status");
if (finalAcks === 0) fail("acknowledgements must include at least one completed/error/failed/denied status");
if (completedCommands === 0) fail("commands must include at least one terminal durable command row");
if (requireDuplicateAck && duplicateFinalAcks === 0) fail("acknowledgements must include duplicate final-ack idempotency evidence");

const auditByCommand = new Map();
const auditIds = new Set();
for (const [index, audit] of audits.entries()) {
  const field = "adminAudits[" + index + "]";
  if (!isObject(audit)) fail(field + " must be an object");
  const id = firstString(audit, ["id", "auditId", "audit_id", "adminAuditId", "admin_audit_id"]);
  requiredString(id, field + ".id");
  if (auditIds.has(id)) fail("duplicate audit id: " + id);
  auditIds.add(id);
  const commandId = nestedCommandId(audit);
  requiredString(commandId, field + ".commandId");
  if (!commandById.has(commandId)) fail(field + ".commandId references unknown command: " + commandId);
  const action = nestedCommandType(audit);
  if (action && action !== commandById.get(commandId).type) fail(field + ".action does not match command type");
  const status = firstString(audit, ["status", "state"]) || "queued";
  if (!auditStatuses.has(status)) fail(field + ".status is not recognized: " + status);
  optionalString(firstString(audit, ["actorId", "actor_id"]), field + ".actorId");
  optionalString(firstString(audit, ["actorRole", "actor_role", "role"]), field + ".actorRole");
  optionalIso(audit.createdAt || audit.created_at || audit.authorizedAt || audit.authorized_at, field + ".createdAt");
  optionalIso(audit.updatedAt || audit.updated_at || audit.acknowledgedAt || audit.acknowledged_at || audit.completedAt || audit.completed_at, field + ".updatedAt");
  const commandStatus = commandById.get(commandId).status;
  if (finalAckStatuses.has(commandStatus) && !finalAckStatuses.has(status)) {
    fail(field + ".status must mirror terminal command status for " + commandId);
  }
  auditByCommand.set(commandId, audit);
}
if (requireAdminAudits && auditByCommand.size === 0) fail("adminAudits must include at least one command audit row");

const eventKeys = new Set();
let commandAuditEvents = 0;
for (const [index, event] of events.entries()) {
  const field = "deviceEvents[" + index + "]";
  if (!isObject(event)) fail(field + " must be an object");
  const source = firstString(event, ["source"]) || "command_audit";
  if (source !== "command_audit" && source !== "commandAudit") fail(field + ".source must be command_audit");
  const deviceId = nestedDeviceId(event);
  requiredString(deviceId, field + ".deviceId");
  const eventKey = firstString(event, ["eventKey", "event_key"]);
  requiredString(eventKey, field + ".eventKey");
  const idempotencyKey = deviceId + "\n" + eventKey;
  if (eventKeys.has(idempotencyKey)) fail("duplicate device event idempotency key: " + deviceId + " + " + eventKey);
  eventKeys.add(idempotencyKey);
  const commandId = nestedCommandId(event);
  requiredString(commandId, field + ".commandId");
  if (!commandById.has(commandId)) fail(field + ".commandId references unknown command: " + commandId);
  if (deviceId !== commandById.get(commandId).deviceId) fail(field + ".deviceId does not match command deviceId");
  optionalString(firstString(event, ["eventType", "event_type", "type"]), field + ".eventType");
  optionalString(firstString(event, ["status", "state"]), field + ".status");
  requiredIso(event.observedAt || event.observed_at || event.createdAt || event.created_at, field + ".observedAt");
  commandAuditEvents += 1;
}
if (requireDeviceEvents && commandAuditEvents === 0) fail("deviceEvents must include at least one command_audit event");

console.log([
  "Autopoiesis command ack contract",
  "commands=" + commands.length,
  "acks=" + acknowledgements.length,
  "adminAudits=" + audits.length,
  "commandAuditEvents=" + commandAuditEvents,
  "duplicateFinalAcks=" + duplicateFinalAcks
].join(" "));
NODE
