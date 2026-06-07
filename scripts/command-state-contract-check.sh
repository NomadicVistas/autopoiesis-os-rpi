#!/usr/bin/env bash
set -euo pipefail

SOURCE="${1:-${AUTOPOIESIS_COMMAND_STATE_CONTRACT_SOURCE:-}}"
REQUIRE_ADMIN_AUDITS="${AUTOPOIESIS_REQUIRE_COMMAND_STATE_ADMIN_AUDITS:-1}"
REQUIRE_NEXT_POLL="${AUTOPOIESIS_REQUIRE_COMMAND_STATE_NEXT_POLL:-1}"
TMP_FILE=""

cleanup() {
  if [[ -n "$TMP_FILE" ]]; then
    rm -f "$TMP_FILE"
  fi
}
trap cleanup EXIT

fail() {
  echo "command state contract check failed: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/command-state-contract-check.sh <command-state-contract-bundle.json>
  scripts/command-state-contract-check.sh https://example/api/admin/frames/command-state-contract-bundle

Environment:
  AUTOPOIESIS_COMMAND_STATE_CONTRACT_SOURCE default file or URL when no argument is passed
  AUTOPOIESIS_COMMAND_STATE_CONTRACT_TOKEN  optional bearer token for URL checks
  AUTOPOIESIS_REQUIRE_COMMAND_STATE_ADMIN_AUDITS require mirrored admin audit rows, default 1
  AUTOPOIESIS_REQUIRE_COMMAND_STATE_NEXT_POLL require post-terminal poll exclusion evidence, default 1

The bundle is read-only staging/CI evidence for hosted command outbox state:
queued durable rows, post-poll delivered rows, post-ack terminal rows,
mirrored admin audit rows, and a next poll proving terminal commands are no
longer delivered.
EOF
}

if [[ -z "$SOURCE" ]]; then
  usage
  exit 2
fi

if [[ "$SOURCE" =~ ^https?:// ]]; then
  TMP_FILE="$(mktemp)"
  CURL_ARGS=(-fsS)
  if [[ -n "${AUTOPOIESIS_COMMAND_STATE_CONTRACT_TOKEN:-}" ]]; then
    CURL_ARGS+=(-H "Authorization: Bearer ${AUTOPOIESIS_COMMAND_STATE_CONTRACT_TOKEN}")
  fi
  curl "${CURL_ARGS[@]}" "$SOURCE" >"$TMP_FILE" || fail "could not fetch command state bundle URL"
  SOURCE="$TMP_FILE"
fi

[[ -f "$SOURCE" ]] || fail "command state contract bundle file not found: $SOURCE"

node - "$SOURCE" "$REQUIRE_ADMIN_AUDITS" "$REQUIRE_NEXT_POLL" <<'NODE'
const fs = require("fs");

const file = process.argv[2];
const requireAdminAudits = process.argv[3] !== "0";
const requireNextPoll = process.argv[4] !== "0";

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
const queuedStatuses = new Set(["queued", "pending", "ready", "retry"]);
const deliveredStatuses = new Set(["sent", "delivered", "acknowledged", "processing"]);
const terminalStatuses = new Set(["completed", "error", "failed", "denied", "expired", "cancelled"]);
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
  /rawPayload/i,
  /raw_payload/i,
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

function firstString(object, names) {
  if (!isObject(object)) return "";
  for (const name of names) {
    const value = object[name];
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  return "";
}

function firstValue(object, names) {
  if (!isObject(object)) return undefined;
  for (const name of names) {
    if (object[name] !== undefined && object[name] !== null && object[name] !== "") return object[name];
  }
  return undefined;
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

function nestedObject(value, names) {
  if (!isObject(value)) return {};
  for (const name of names) {
    if (isObject(value[name])) return value[name];
  }
  return {};
}

function nestedDeviceId(value) {
  return firstString(value, ["deviceId", "device_id"]) ||
    firstString(nestedObject(value, ["device", "command", "payload"]), ["deviceId", "device_id", "id"]);
}

function nestedCommandId(value) {
  return firstString(value, ["commandId", "command_id", "id"]) ||
    firstString(nestedObject(value, ["command", "payload"]), ["commandId", "command_id", "id"]);
}

function nestedCommandType(value) {
  return firstString(value, ["commandType", "command_type", "action", "type"]) ||
    firstString(nestedObject(value, ["command", "payload"]), ["commandType", "command_type", "action", "type"]);
}

function nestedStatus(value) {
  return firstString(value, ["status", "commandStatus", "command_status", "state", "lastAckStatus", "last_ack_status"]) ||
    firstString(nestedObject(value, ["command", "audit"]), ["status", "commandStatus", "command_status", "state", "lastAckStatus", "last_ack_status"]);
}

function responseStatus(value) {
  if (!isObject(value)) return null;
  const status = Number(value.httpStatus ?? value.statusCode ?? value.responseStatus ?? value.code ?? value.status);
  return Number.isInteger(status) ? status : null;
}

function pollCommands(poll, field) {
  if (poll === undefined || poll === null) return [];
  if (!isObject(poll)) fail(field + " must be an object when present");
  const response = isObject(poll.response) ? poll.response : poll;
  const status = responseStatus(response);
  if (Number.isInteger(status) && (status < 200 || status >= 300)) fail(field + " must be a successful response");
  return extractArray(response, ["commands", "commandQueue", "queuedCommands", "items", "rows"], field + ".commands", false);
}

function assertNoSensitive(value, field) {
  const raw = JSON.stringify(value);
  for (const pattern of forbiddenPatterns) {
    if (pattern.test(raw)) fail(field + " exposes forbidden sensitive or local-only data: " + pattern);
  }
}

function normalizeCommand(row, field, expectedDeviceId = "") {
  if (!isObject(row)) fail(field + " must be an object");
  const commandId = nestedCommandId(row);
  const deviceId = nestedDeviceId(row);
  const commandType = nestedCommandType(row);
  const status = nestedStatus(row);
  requiredString(commandId, field + ".commandId");
  requiredString(deviceId, field + ".deviceId");
  requiredString(commandType, field + ".commandType");
  if (expectedDeviceId && deviceId !== expectedDeviceId) fail(field + ".deviceId must match bundle deviceId");
  if (!supportedCommands.has(commandType)) fail(field + ".commandType is unsupported: " + commandType);
  optionalIso(row.createdAt || row.created_at, field + ".createdAt");
  optionalIso(row.updatedAt || row.updated_at, field + ".updatedAt");
  optionalIso(row.deliveredAt || row.delivered_at || row.sentAt || row.sent_at || row.polledAt || row.polled_at, field + ".deliveredAt");
  optionalIso(row.acknowledgedAt || row.acknowledged_at, field + ".acknowledgedAt");
  optionalIso(row.completedAt || row.completed_at || row.terminalAt || row.terminal_at || row.failedAt || row.failed_at || row.deniedAt || row.denied_at || row.lastAckAt || row.last_ack_at, field + ".terminalAt");
  return { commandId, deviceId, commandType, status, row };
}

function commandMap(rows, field, expectedDeviceId) {
  const map = new Map();
  rows.forEach((row, index) => {
    const normalized = normalizeCommand(row, field + "[" + index + "]", expectedDeviceId);
    if (map.has(normalized.commandId)) fail("duplicate command id in " + field + ": " + normalized.commandId);
    map.set(normalized.commandId, normalized);
  });
  return map;
}

function requireTimestamp(row, names, field) {
  const value = firstValue(row, names);
  if (!validIso(value)) fail(field + " is required and must be an ISO timestamp");
}

function validateAudit(audit, field, expected) {
  if (!isObject(audit)) fail(field + " must be an object");
  const commandId = nestedCommandId(audit);
  const deviceId = nestedDeviceId(audit);
  const status = nestedStatus(audit);
  if (commandId !== expected.commandId) fail(field + ".commandId must match terminal command");
  if (deviceId && deviceId !== expected.deviceId) fail(field + ".deviceId must match terminal command");
  if (!terminalStatuses.has(status)) fail(field + ".status must be terminal");
  if (status !== expected.status) fail(field + ".status must mirror terminal command status");
  optionalIso(audit.updatedAt || audit.updated_at || audit.completedAt || audit.completed_at, field + ".updatedAt");
}

let payload;
try {
  payload = JSON.parse(fs.readFileSync(file, "utf8"));
} catch (error) {
  fail("could not parse JSON: " + error.message);
}

if (!isObject(payload)) fail("bundle root must be an object");
if (payload.kind && payload.kind !== "autopoiesis_frames_command_state_contract") {
  fail("unexpected bundle kind: " + payload.kind);
}
if (payload.schemaVersion !== undefined && Number(payload.schemaVersion) !== 1) {
  fail("unsupported schemaVersion: " + payload.schemaVersion);
}
optionalIso(payload.generatedAt || payload.generated_at, "generatedAt");
assertNoSensitive(payload, "bundle");

const deviceId = firstString(payload, ["deviceId", "device_id"]) ||
  firstString(nestedObject(payload, ["device"]), ["deviceId", "device_id", "id"]);
requiredString(deviceId, "deviceId");

const queuedRows = extractArray(
  payload,
  ["beforePollCommands", "queuedCommands", "initialCommands", "commandsBeforePoll", "commands"],
  "beforePollCommands"
);
const deliveredRows = extractArray(
  payload,
  ["postPollCommands", "deliveredCommands", "afterPollCommands", "sentCommands", "commandsAfterPoll"],
  "postPollCommands"
);
const terminalRows = extractArray(
  payload,
  ["postAckCommands", "terminalCommands", "afterAckCommands", "finalCommands", "commandsAfterAck"],
  "postAckCommands"
);

if (queuedRows.length === 0) fail("beforePollCommands must include at least one command");
if (deliveredRows.length === 0) fail("postPollCommands must include at least one command");
if (terminalRows.length === 0) fail("postAckCommands must include at least one command");

const queuedById = commandMap(queuedRows, "beforePollCommands", deviceId);
const deliveredById = commandMap(deliveredRows, "postPollCommands", deviceId);
const terminalById = commandMap(terminalRows, "postAckCommands", deviceId);

let lifecycleCount = 0;
for (const queued of queuedById.values()) {
  if (!queuedStatuses.has(queued.status)) fail("beforePollCommands command is not queued: " + queued.commandId);
  const delivered = deliveredById.get(queued.commandId);
  if (!delivered) fail("postPollCommands missing queued command: " + queued.commandId);
  if (delivered.commandType !== queued.commandType) fail("postPollCommands command type drift: " + queued.commandId);
  if (!deliveredStatuses.has(delivered.status)) {
    fail("postPollCommands command must be delivered/sent/acknowledged/processing: " + queued.commandId);
  }
  requireTimestamp(
    delivered.row,
    ["deliveredAt", "delivered_at", "sentAt", "sent_at", "polledAt", "polled_at", "lastPollAt", "last_poll_at"],
    "postPollCommands[" + queued.commandId + "].deliveredAt"
  );
  const terminal = terminalById.get(queued.commandId);
  if (!terminal) fail("postAckCommands missing delivered command: " + queued.commandId);
  if (terminal.commandType !== queued.commandType) fail("postAckCommands command type drift: " + queued.commandId);
  if (!terminalStatuses.has(terminal.status)) fail("postAckCommands command is not terminal: " + queued.commandId);
  requireTimestamp(
    terminal.row,
    ["completedAt", "completed_at", "terminalAt", "terminal_at", "failedAt", "failed_at", "deniedAt", "denied_at", "lastAckAt", "last_ack_at"],
    "postAckCommands[" + queued.commandId + "].terminalAt"
  );
  lifecycleCount += 1;
}

if (lifecycleCount === 0) fail("no complete queued -> delivered -> terminal command lifecycle found");

if (requireAdminAudits) {
  const adminAudits = extractArray(payload, ["adminAudits", "auditRows", "commandAudits"], "adminAudits");
  const auditsByCommandId = new Map();
  adminAudits.forEach((audit, index) => {
    const commandId = nestedCommandId(audit);
    if (!commandId) fail("adminAudits[" + index + "].commandId is required");
    if (!auditsByCommandId.has(commandId)) auditsByCommandId.set(commandId, []);
    auditsByCommandId.get(commandId).push({ audit, index });
  });
  for (const terminal of terminalById.values()) {
    const matches = auditsByCommandId.get(terminal.commandId) || [];
    if (matches.length === 0) fail("adminAudits missing terminal command: " + terminal.commandId);
    let sawMirror = false;
    for (const match of matches) {
      validateAudit(match.audit, "adminAudits[" + match.index + "]", terminal);
      sawMirror = true;
    }
    if (!sawMirror) fail("adminAudits did not mirror terminal command: " + terminal.commandId);
  }
}

if (requireNextPoll) {
  const nextPoll = payload.nextPoll || payload.postAckPoll || payload.pollAfterAck || payload.afterAckPoll;
  if (!isObject(nextPoll)) fail("nextPoll/postAckPoll evidence is required");
  const returned = pollCommands(nextPoll, "nextPoll");
  for (const [index, command] of returned.entries()) {
    const normalized = normalizeCommand(command, "nextPoll.commands[" + index + "]", deviceId);
    if (terminalById.has(normalized.commandId)) {
      fail("nextPoll returned terminal command: " + normalized.commandId);
    }
  }
}

console.log(
  [
    "Autopoiesis command state contract ok",
    "device=" + deviceId,
    "lifecycles=" + lifecycleCount,
    "terminal=" + terminalById.size
  ].join(" ")
);
NODE
