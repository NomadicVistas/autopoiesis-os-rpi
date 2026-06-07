#!/usr/bin/env bash
set -euo pipefail

SOURCE="${1:-${AUTOPOIESIS_RELEASE_ROLLOUT_CONTRACT_SOURCE:-}}"
REQUIRE_COMMANDS="${AUTOPOIESIS_REQUIRE_RELEASE_ROLLOUT_COMMANDS:-1}"
REQUIRE_DEVICE_EVENTS="${AUTOPOIESIS_REQUIRE_RELEASE_ROLLOUT_DEVICE_EVENTS:-1}"
REQUIRE_PROGRESS="${AUTOPOIESIS_REQUIRE_RELEASE_ROLLOUT_PROGRESS:-1}"
TMP_FILE=""

cleanup() {
  if [[ -n "$TMP_FILE" ]]; then
    rm -f "$TMP_FILE"
  fi
}
trap cleanup EXIT

fail() {
  echo "release rollout contract check failed: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/release-rollout-contract-check.sh <release-rollout-contract-bundle.json>
  scripts/release-rollout-contract-check.sh https://example/api/admin/frames/release-rollout-contract-bundle

Environment:
  AUTOPOIESIS_RELEASE_ROLLOUT_CONTRACT_SOURCE default file or URL when no argument is passed
  AUTOPOIESIS_RELEASE_ROLLOUT_CONTRACT_TOKEN  optional bearer token for URL checks
  AUTOPOIESIS_REQUIRE_RELEASE_ROLLOUT_COMMANDS require update_device command evidence, default 1
  AUTOPOIESIS_REQUIRE_RELEASE_ROLLOUT_DEVICE_EVENTS require release_history event evidence, default 1
  AUTOPOIESIS_REQUIRE_RELEASE_ROLLOUT_PROGRESS require rollout progress rows, default 1

The bundle is read-only staging/CI evidence for hosted release rollout state:
software release rows, per-device rollout rows, update commands, admin audits,
and heartbeat-ingested release_history events. It intentionally does not need
release artifact URLs, checksums, or raw command payloads.
EOF
}

if [[ -z "$SOURCE" ]]; then
  usage
  exit 2
fi

if [[ "$SOURCE" =~ ^https?:// ]]; then
  TMP_FILE="$(mktemp)"
  CURL_ARGS=(-fsS)
  if [[ -n "${AUTOPOIESIS_RELEASE_ROLLOUT_CONTRACT_TOKEN:-}" ]]; then
    CURL_ARGS+=(-H "Authorization: Bearer ${AUTOPOIESIS_RELEASE_ROLLOUT_CONTRACT_TOKEN}")
  fi
  curl "${CURL_ARGS[@]}" "$SOURCE" >"$TMP_FILE" || fail "could not fetch release rollout bundle URL"
  SOURCE="$TMP_FILE"
fi

[[ -f "$SOURCE" ]] || fail "release rollout contract bundle file not found: $SOURCE"

node - "$SOURCE" "$REQUIRE_COMMANDS" "$REQUIRE_DEVICE_EVENTS" "$REQUIRE_PROGRESS" <<'NODE'
const fs = require("fs");

const file = process.argv[2];
const requireCommands = process.argv[3] !== "0";
const requireDeviceEvents = process.argv[4] !== "0";
const requireProgress = process.argv[5] !== "0";

const allowedChannels = new Set(["stable", "beta", "dev", "canary", "nightly", "staged", "test"]);
const allowedReleaseStatuses = new Set([
  "draft",
  "staged",
  "published",
  "active",
  "rolling_out",
  "paused",
  "completed",
  "superseded",
  "failed",
  "cancelled"
]);
const allowedRolloutStatuses = new Set([
  "eligible",
  "queued",
  "pending",
  "sent",
  "acknowledged",
  "downloading",
  "installing",
  "updating",
  "installed",
  "succeeded",
  "completed",
  "failed",
  "error",
  "rolled_back",
  "rollback_completed",
  "skipped",
  "denied",
  "cancelled",
  "expired"
]);
const allowedCommandStatuses = new Set([
  "queued",
  "pending",
  "acknowledged",
  "processing",
  "completed",
  "error",
  "failed",
  "denied",
  "expired"
]);
const acceptedRoles = new Set(["admin", "owner", "support", "ops", "maintainer", "super_admin"]);
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
  /artifactUrl/i,
  /artifact_url/i,
  /assetUrl/i,
  /downloadUrl/i,
  /checksum/i,
  /sha256/i,
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

function optionalString(value, field) {
  if (value === undefined || value === null) return;
  if (typeof value !== "string") fail(field + " must be a string when present");
}

function optionalBoolean(value, field) {
  if (value === undefined || value === null) return;
  if (typeof value !== "boolean") fail(field + " must be boolean when present");
}

function optionalNumberRange(value, field, min, max) {
  if (value === undefined || value === null || value === "") return;
  const number = Number(value);
  if (!Number.isFinite(number) || number < min || number > max) {
    fail(field + " must be a number from " + min + " to " + max);
  }
}

function requiredString(value, field) {
  if (typeof value !== "string" || !value.trim()) fail(field + " is required");
}

function semver(value, field) {
  requiredString(value, field);
  if (!/^[vV]?\d+\.\d+\.\d+([-.+][0-9A-Za-z.-]+)?$/.test(value.trim())) {
    fail(field + " must look like a semantic version");
  }
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
    fail(field + " must be an array or paged object when present");
  }
  if (required) fail(field + " is required");
  return [];
}

function nestedReleaseId(value) {
  if (!isObject(value)) return "";
  return firstString(value, ["releaseId", "release_id"]) ||
    (isObject(value.release) ? firstString(value.release, ["id", "releaseId", "release_id"]) : "") ||
    (isObject(value.payload) ? firstString(value.payload, ["releaseId", "release_id", "id"]) : "");
}

function nestedRolloutId(value) {
  if (!isObject(value)) return "";
  return firstString(value, ["rolloutId", "rollout_id"]) ||
    (isObject(value.rollout) ? firstString(value.rollout, ["id", "rolloutId", "rollout_id"]) : "") ||
    (isObject(value.payload) ? firstString(value.payload, ["rolloutId", "rollout_id"]) : "");
}

function nestedTargetVersion(value) {
  if (!isObject(value)) return "";
  return firstString(value, ["targetVersion", "target_version", "version"]) ||
    (isObject(value.release) ? firstString(value.release, ["version", "targetVersion", "target_version"]) : "") ||
    (isObject(value.payload) ? firstString(value.payload, ["version", "targetVersion", "target_version"]) : "");
}

function nestedDeviceId(value) {
  if (!isObject(value)) return "";
  return firstString(value, ["deviceId", "device_id"]) ||
    (isObject(value.device) ? firstString(value.device, ["deviceId", "device_id", "id"]) : "") ||
    (isObject(value.payload) ? firstString(value.payload, ["deviceId", "device_id"]) : "");
}

function validateAuthorization(auth, field, expectedAction) {
  if (!isObject(auth)) fail(field + " authorization is required");
  if (auth.approved !== true) fail(field + ".approved must be true");
  const action = firstString(auth, ["action", "commandType", "command_type"]);
  if (action !== expectedAction) fail(field + ".action must be " + expectedAction);
  requiredString(firstString(auth, ["actorId", "actor_id"]), field + ".actorId");
  const role = firstString(auth, ["actorRole", "actor_role", "role"]);
  if (!acceptedRoles.has(role)) fail(field + ".actorRole is not accepted: " + (role || "missing"));
  requiredString(firstString(auth, ["auditId", "audit_id", "adminAuditId", "admin_audit_id"]), field + ".auditId");
  optionalIso(auth.authorizedAt || auth.authorized_at, field + ".authorizedAt");
}

let payload;
try {
  payload = JSON.parse(fs.readFileSync(file, "utf8"));
} catch (error) {
  fail("invalid JSON: " + error.message);
}

if (!isObject(payload)) fail("release rollout bundle root must be an object");
if (payload.ok === false) fail("release rollout bundle ok=false");
if (payload.schemaVersion !== undefined && payload.schemaVersion !== 1) fail("schemaVersion must be 1 when present");
if (payload.kind !== undefined && payload.kind !== "autopoiesis_frames_release_rollout_contract") {
  fail("kind must be autopoiesis_frames_release_rollout_contract when present");
}
optionalIso(payload.generatedAt, "generatedAt");

const raw = JSON.stringify(payload);
for (const pattern of forbiddenPatterns) {
  if (pattern.test(raw)) fail("bundle exposes forbidden sensitive or local-only data: " + pattern);
}

const releases = extractArray(payload, ["releases", "softwareReleases", "releaseRows"], "releases");
const rollouts = extractArray(payload, ["rollouts", "releaseRollouts", "rolloutRows"], "rollouts", requireProgress);
const commands = extractArray(payload, ["commands", "commandQueue", "queuedCommands", "adminCommands"], "commands", requireCommands);
const audits = extractArray(payload, ["adminAudits", "audits", "commandAudits"], "adminAudits", false);
const events = extractArray(payload, ["deviceEvents", "events", "releaseEvents"], "deviceEvents", requireDeviceEvents);

const releaseById = new Map();
for (const [index, release] of releases.entries()) {
  const field = "releases[" + index + "]";
  if (!isObject(release)) fail(field + " must be an object");
  const id = firstString(release, ["id", "releaseId", "release_id"]);
  requiredString(id, field + ".id");
  if (releaseById.has(id)) fail("duplicate release id: " + id);
  const version = firstString(release, ["version", "targetVersion", "target_version"]);
  semver(version, field + ".version");
  const channel = firstString(release, ["channel", "updateChannel", "update_channel"]) || "stable";
  if (!allowedChannels.has(channel)) fail(field + ".channel is not recognized: " + channel);
  const status = firstString(release, ["status", "state"]) || "published";
  if (!allowedReleaseStatuses.has(status)) fail(field + ".status is not recognized: " + status);
  optionalString(firstString(release, ["tag", "tagName", "tag_name"]), field + ".tag");
  optionalString(firstString(release, ["gitRef", "git_ref", "rollbackRef", "rollback_ref", "minimumVersion", "minimum_version"]), field + ".git/ref metadata");
  optionalIso(release.createdAt || release.created_at, field + ".createdAt");
  optionalIso(release.publishedAt || release.published_at, field + ".publishedAt");
  optionalIso(release.pausedAt || release.paused_at, field + ".pausedAt");
  optionalNumberRange(release.rolloutPercent ?? release.rollout_percent, field + ".rolloutPercent", 0, 100);
  releaseById.set(id, { version, channel, status });
}

const rolloutById = new Map();
const rolloutByDeviceRelease = new Map();
let terminalProgressRows = 0;
for (const [index, rollout] of rollouts.entries()) {
  const field = "rollouts[" + index + "]";
  if (!isObject(rollout)) fail(field + " must be an object");
  const id = firstString(rollout, ["id", "rolloutId", "rollout_id"]);
  requiredString(id, field + ".id");
  if (rolloutById.has(id)) fail("duplicate rollout id: " + id);
  const releaseId = firstString(rollout, ["releaseId", "release_id"]);
  requiredString(releaseId, field + ".releaseId");
  if (!releaseById.has(releaseId)) fail(field + ".releaseId references unknown release: " + releaseId);
  const deviceId = nestedDeviceId(rollout);
  requiredString(deviceId, field + ".deviceId");
  const status = firstString(rollout, ["status", "state"]) || "pending";
  if (!allowedRolloutStatuses.has(status)) fail(field + ".status is not recognized: " + status);
  const targetVersion = firstString(rollout, ["targetVersion", "target_version", "version"]) || releaseById.get(releaseId).version;
  semver(targetVersion, field + ".targetVersion");
  if (targetVersion !== releaseById.get(releaseId).version) {
    fail(field + ".targetVersion must match release.version for " + releaseId);
  }
  const currentVersion = firstString(rollout, ["currentVersion", "current_version"]);
  if (currentVersion) semver(currentVersion, field + ".currentVersion");
  optionalString(firstString(rollout, ["commandId", "command_id"]), field + ".commandId");
  optionalString(firstString(rollout, ["failureReason", "failure_reason", "error", "reason"]), field + ".failureReason");
  optionalBoolean(rollout.updateAvailable ?? rollout.update_available, field + ".updateAvailable");
  optionalIso(rollout.queuedAt || rollout.queued_at, field + ".queuedAt");
  optionalIso(rollout.startedAt || rollout.started_at, field + ".startedAt");
  optionalIso(rollout.completedAt || rollout.completed_at, field + ".completedAt");
  optionalIso(rollout.failedAt || rollout.failed_at, field + ".failedAt");
  optionalIso(rollout.rolledBackAt || rollout.rolled_back_at, field + ".rolledBackAt");
  optionalIso(rollout.lastSeenAt || rollout.last_seen_at || rollout.updatedAt || rollout.updated_at, field + ".lastSeenAt");
  rolloutById.set(id, { releaseId, deviceId, targetVersion, status });
  rolloutByDeviceRelease.set(deviceId + "\n" + releaseId, id);
  if (["installed", "succeeded", "completed", "failed", "error", "rolled_back", "rollback_completed", "skipped", "denied"].includes(status)) {
    terminalProgressRows += 1;
  }
}
if (requireProgress && rollouts.length === 0) fail("rollouts must not be empty");
if (requireProgress && terminalProgressRows === 0) {
  fail("at least one rollout row must show terminal progress or failure evidence");
}

let updateCommands = 0;
const commandIds = new Set();
for (const [index, command] of commands.entries()) {
  const field = "commands[" + index + "]";
  if (!isObject(command)) fail(field + " must be an object");
  const id = firstString(command, ["id", "commandId", "command_id"]);
  requiredString(id, field + ".id");
  if (commandIds.has(id)) fail("duplicate command id: " + id);
  commandIds.add(id);
  const type = firstString(command, ["commandType", "command_type", "action", "type"]);
  if (type !== "update_device") continue;
  updateCommands += 1;
  const deviceId = nestedDeviceId(command);
  requiredString(deviceId, field + ".deviceId");
  const releaseId = nestedReleaseId(command);
  requiredString(releaseId, field + ".releaseId");
  if (!releaseById.has(releaseId)) fail(field + ".releaseId references unknown release: " + releaseId);
  const targetVersion = nestedTargetVersion(command) || releaseById.get(releaseId).version;
  semver(targetVersion, field + ".targetVersion");
  if (targetVersion !== releaseById.get(releaseId).version) {
    fail(field + ".targetVersion must match release.version for " + releaseId);
  }
  const rolloutId = nestedRolloutId(command) || rolloutByDeviceRelease.get(deviceId + "\n" + releaseId);
  if (rolloutId && !rolloutById.has(rolloutId)) fail(field + ".rolloutId references unknown rollout: " + rolloutId);
  const status = firstString(command, ["status", "state"]) || "queued";
  if (!allowedCommandStatuses.has(status)) fail(field + ".status is not recognized: " + status);
  optionalIso(command.createdAt || command.created_at || command.queuedAt || command.queued_at, field + ".createdAt");
  optionalIso(command.acknowledgedAt || command.acknowledged_at, field + ".acknowledgedAt");
  optionalIso(command.completedAt || command.completed_at, field + ".completedAt");
  validateAuthorization(command.authorization || (isObject(command.payload) ? command.payload.authorization : null), field, "update_device");
}
if (requireCommands && updateCommands === 0) fail("commands must include at least one update_device command");

const auditIds = new Set();
for (const [index, audit] of audits.entries()) {
  const field = "adminAudits[" + index + "]";
  if (!isObject(audit)) fail(field + " must be an object");
  const id = firstString(audit, ["id", "auditId", "audit_id", "adminAuditId", "admin_audit_id"]);
  requiredString(id, field + ".id");
  if (auditIds.has(id)) fail("duplicate audit id: " + id);
  auditIds.add(id);
  const action = firstString(audit, ["action", "commandType", "command_type"]);
  if (action && action !== "update_device") fail(field + ".action must be update_device when present");
  const status = firstString(audit, ["status", "state"]) || "approved";
  if (!["approved", "queued", "acknowledged", "completed", "failed", "denied"].includes(status)) {
    fail(field + ".status is not recognized: " + status);
  }
  optionalIso(audit.createdAt || audit.created_at || audit.authorizedAt || audit.authorized_at, field + ".createdAt");
  optionalString(firstString(audit, ["actorId", "actor_id"]), field + ".actorId");
}

let releaseHistoryEvents = 0;
const eventKeys = new Set();
for (const [index, event] of events.entries()) {
  const field = "deviceEvents[" + index + "]";
  if (!isObject(event)) fail(field + " must be an object");
  const source = firstString(event, ["source"]) || "release_history";
  if (source !== "release_history" && source !== "releaseHistory") {
    fail(field + ".source must be release_history");
  }
  const eventKey = firstString(event, ["eventKey", "event_key"]);
  requiredString(eventKey, field + ".eventKey");
  if (eventKeys.has(eventKey)) fail("duplicate device eventKey: " + eventKey);
  eventKeys.add(eventKey);
  optionalString(firstString(event, ["eventType", "event_type", "type"]), field + ".eventType");
  optionalString(firstString(event, ["status", "state"]), field + ".status");
  const deviceId = nestedDeviceId(event);
  requiredString(deviceId, field + ".deviceId");
  const releaseId = nestedReleaseId(event);
  if (releaseId && !releaseById.has(releaseId)) fail(field + ".releaseId references unknown release: " + releaseId);
  const rolloutId = nestedRolloutId(event);
  if (rolloutId && !rolloutById.has(rolloutId)) fail(field + ".rolloutId references unknown rollout: " + rolloutId);
  const version = nestedTargetVersion(event);
  if (version) semver(version, field + ".version");
  optionalBoolean(event.updateAvailable ?? event.update_available, field + ".updateAvailable");
  optionalIso(event.observedAt || event.observed_at || event.createdAt || event.created_at, field + ".observedAt");
  releaseHistoryEvents += 1;
}
if (requireDeviceEvents && releaseHistoryEvents === 0) {
  fail("deviceEvents must include at least one release_history event");
}

console.log([
  "Autopoiesis release rollout contract",
  "releases=" + releases.length,
  "rollouts=" + rollouts.length,
  "updateCommands=" + updateCommands,
  "releaseHistoryEvents=" + releaseHistoryEvents
].join(" "));
NODE
