#!/usr/bin/env bash
set -euo pipefail

SOURCE="${1:-${AUTOPOIESIS_BROADCAST_CONTRACT_SOURCE:-}}"
REQUIRE_COMMANDS="${AUTOPOIESIS_REQUIRE_BROADCAST_COMMANDS:-1}"
REQUIRE_DELIVERY="${AUTOPOIESIS_REQUIRE_BROADCAST_DELIVERY:-1}"
REQUIRE_TARGETING="${AUTOPOIESIS_REQUIRE_BROADCAST_TARGETING:-1}"
TMP_FILE=""

cleanup() {
  if [[ -n "$TMP_FILE" ]]; then
    rm -f "$TMP_FILE"
  fi
}
trap cleanup EXIT

fail() {
  echo "broadcast contract check failed: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/broadcast-contract-check.sh <broadcast-contract-bundle.json>
  scripts/broadcast-contract-check.sh https://example/api/admin/frames/broadcast-contract-bundle

Environment:
  AUTOPOIESIS_BROADCAST_CONTRACT_SOURCE   default file or URL when no argument is passed
  AUTOPOIESIS_BROADCAST_CONTRACT_TOKEN    optional bearer token for URL checks
  AUTOPOIESIS_REQUIRE_BROADCAST_COMMANDS  require show_broadcast queue evidence, default 1
  AUTOPOIESIS_REQUIRE_BROADCAST_DELIVERY  require display/delivery evidence, default 1
  AUTOPOIESIS_REQUIRE_BROADCAST_TARGETING require explicit targeting/audience, default 1

The bundle is read-only staging/CI evidence for the hosted broadcast lifecycle:
admin broadcast rows, queued show_broadcast commands, and durable delivery rows.
EOF
}

if [[ -z "$SOURCE" ]]; then
  usage
  exit 2
fi

if [[ "$SOURCE" =~ ^https?:// ]]; then
  TMP_FILE="$(mktemp)"
  CURL_ARGS=(-fsS)
  if [[ -n "${AUTOPOIESIS_BROADCAST_CONTRACT_TOKEN:-}" ]]; then
    CURL_ARGS+=(-H "Authorization: Bearer ${AUTOPOIESIS_BROADCAST_CONTRACT_TOKEN}")
  fi
  curl "${CURL_ARGS[@]}" "$SOURCE" >"$TMP_FILE" || fail "could not fetch broadcast bundle URL"
  SOURCE="$TMP_FILE"
fi

[[ -f "$SOURCE" ]] || fail "broadcast contract bundle file not found: $SOURCE"

node - "$SOURCE" "$REQUIRE_COMMANDS" "$REQUIRE_DELIVERY" "$REQUIRE_TARGETING" <<'NODE'
const fs = require("fs");

const file = process.argv[2];
const requireCommands = process.argv[3] !== "0";
const requireDelivery = process.argv[4] !== "0";
const requireTargeting = process.argv[5] !== "0";

const allowedBroadcastTypes = new Set([
  "text_message",
  "image_message",
  "video_message",
  "audio_message",
  "curatorial_announcement",
  "system_notice",
  "emergency_notice",
  "event_invitation",
  "artist_drop",
  "maintenance_notice",
  "broadcast"
]);
const allowedStatuses = new Set([
  "draft",
  "scheduled",
  "queued",
  "active",
  "sent",
  "delivering",
  "completed",
  "expired",
  "cancelled",
  "failed"
]);
const allowedPriorities = new Set(["critical", "emergency", "high", "normal", "low"]);
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
const allowedDeliveryEvents = new Set([
  "queued",
  "sent",
  "delivered",
  "shown",
  "broadcast_shown",
  "broadcast_dismissed",
  "broadcast_expired",
  "broadcast_skipped",
  "acknowledged",
  "completed",
  "failed",
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
  /secret/i,
  /password/i,
  /\/var\/lib\/autopoiesis-os/i,
  /\/opt\/autopoiesis-os/i,
  /\/var\/log\/autopoiesis-os/i
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

function optionalNumber(value, field, min = null, max = null) {
  if (value === undefined || value === null || value === "") return;
  const number = Number(value);
  if (!Number.isFinite(number)) fail(field + " must be numeric when present");
  if (min !== null && number < min) fail(field + " must be >= " + min);
  if (max !== null && number > max) fail(field + " must be <= " + max);
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

function firstString(object, names) {
  for (const name of names) {
    const value = object[name];
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  return "";
}

function nestedBroadcastId(value) {
  if (!isObject(value)) return "";
  return firstString(value, ["broadcastId", "broadcast_id"]) ||
    (isObject(value.broadcast) ? firstString(value.broadcast, ["id", "broadcastId", "broadcast_id"]) : "") ||
    (isObject(value.payload) ? firstString(value.payload, ["broadcastId", "broadcast_id", "id"]) : "");
}

function validateTargeting(targeting, field) {
  if (targeting === undefined || targeting === null || targeting === "") {
    if (requireTargeting) fail(field + " is required");
    return false;
  }
  if (typeof targeting === "string") {
    if (!targeting.trim()) fail(field + " must not be empty");
    return true;
  }
  if (Array.isArray(targeting)) {
    if (targeting.length === 0 && requireTargeting) fail(field + " must not be empty");
    return targeting.map((entry, index) => validateTargeting(entry, field + "[" + index + "]")).some(Boolean);
  }
  if (!isObject(targeting)) fail(field + " must be a string, object, or array");

  const recognized = [
    "type", "targetType", "scope", "audience", "kind", "value", "values", "ids", "id",
    "allDevices", "allSubscribers", "subscriberOnly", "testDevicesOnly",
    "deviceId", "deviceIds", "devices", "targetDeviceIds",
    "userId", "userIds", "ownerUserId", "ownerUserIds", "users", "owners", "targetUserIds",
    "subscriptionStatus", "subscriptionStatuses", "subscriberStatus", "subscriberStatuses",
    "subscriptionTier", "subscriptionTiers", "tier", "tiers",
    "artistId", "artistIds", "artistFollowers",
    "region", "regions", "country", "countries",
    "excludeDeviceIds", "excludedDeviceIds", "blockedDeviceIds",
    "excludeUserIds", "excludedUserIds", "blockedUserIds",
    "developmentDevices", "devDevices"
  ];
  const keys = Object.keys(targeting);
  const unknown = keys.filter(key => !recognized.includes(key));
  if (unknown.length) fail(field + " contains unsupported targeting keys: " + unknown.join(", "));
  if (requireTargeting && keys.length === 0) fail(field + " must contain at least one targeting key");
  return keys.length > 0;
}

function validateAuthorization(auth, field, expectedAction) {
  if (!isObject(auth)) fail(field + " authorization is required");
  if (auth.approved !== true) fail(field + ".approved must be true");
  const action = firstString(auth, ["action", "commandType", "command_type"]);
  if (action !== expectedAction) fail(field + ".action must be " + expectedAction);
  requiredString(firstString(auth, ["actorId", "actor_id"]), field + ".actorId");
  const role = firstString(auth, ["actorRole", "actor_role", "role"]);
  if (!acceptedRoles.has(role)) fail(field + ".actorRole is not accepted: " + (role || "missing"));
  optionalIso(auth.authorizedAt || auth.authorized_at, field + ".authorizedAt");
  requiredString(firstString(auth, ["auditId", "audit_id", "adminAuditId", "admin_audit_id"]), field + ".auditId");
}

let payload;
try {
  payload = JSON.parse(fs.readFileSync(file, "utf8"));
} catch (error) {
  fail("invalid JSON: " + error.message);
}

if (!isObject(payload)) fail("broadcast bundle root must be an object");
if (payload.ok === false) fail("broadcast bundle ok=false");
if (payload.schemaVersion !== undefined && payload.schemaVersion !== 1) fail("schemaVersion must be 1 when present");
if (payload.kind !== undefined && payload.kind !== "autopoiesis_frames_broadcast_contract") {
  fail("kind must be autopoiesis_frames_broadcast_contract when present");
}
optionalIso(payload.generatedAt, "generatedAt");

const raw = JSON.stringify(payload);
for (const pattern of forbiddenPatterns) {
  if (pattern.test(raw)) fail("bundle exposes forbidden sensitive or local-only data: " + pattern);
}

const broadcasts = extractArray(payload, ["broadcasts", "adminBroadcasts", "campaigns"], "broadcasts");
const commands = extractArray(payload, ["commands", "commandQueue", "queuedCommands", "adminCommands"], "commands", requireCommands);
const deliveries = extractArray(payload, ["deliveries", "deliveryLogs", "broadcastDeliveries"], "deliveries", requireDelivery);
const broadcastIds = new Set();
let targetedBroadcasts = 0;
let scheduledBroadcasts = 0;

for (const [index, broadcast] of broadcasts.entries()) {
  const field = "broadcasts[" + index + "]";
  if (!isObject(broadcast)) fail(field + " must be an object");
  const id = firstString(broadcast, ["id", "broadcastId", "broadcast_id"]);
  requiredString(id, field + ".id");
  if (broadcastIds.has(id)) fail("duplicate broadcast id: " + id);
  broadcastIds.add(id);

  const type = firstString(broadcast, ["type", "broadcastType", "broadcast_type"]) || "broadcast";
  if (!allowedBroadcastTypes.has(type)) fail(field + ".type is not recognized: " + type);
  const status = firstString(broadcast, ["status", "state"]) || "active";
  if (!allowedStatuses.has(status)) fail(field + ".status is not recognized: " + status);
  const priority = (firstString(broadcast, ["priority"]) || "normal").toLowerCase();
  if (!allowedPriorities.has(priority)) fail(field + ".priority is not recognized: " + priority);

  optionalString(broadcast.title, field + ".title");
  optionalString(broadcast.body || broadcast.message || broadcast.description, field + ".body");
  optionalString(broadcast.mediaUrl || broadcast.media_url, field + ".mediaUrl");
  optionalNumber(broadcast.durationSeconds ?? broadcast.duration, field + ".durationSeconds", 1, 86400);
  optionalNumber(broadcast.targetCount ?? broadcast.target_count, field + ".targetCount", 0);
  optionalNumber(broadcast.deliveredCount ?? broadcast.delivered_count, field + ".deliveredCount", 0);
  optionalIso(broadcast.createdAt || broadcast.created_at, field + ".createdAt");
  optionalIso(broadcast.startsAt || broadcast.starts_at || broadcast.scheduledAt || broadcast.scheduled_at, field + ".startsAt");
  optionalIso(broadcast.expiresAt || broadcast.expires_at, field + ".expiresAt");
  optionalBoolean(broadcast.dismissible, field + ".dismissible");
  optionalBoolean(broadcast.cacheAllowed ?? broadcast.cache_allowed, field + ".cacheAllowed");
  optionalBoolean(broadcast.soundAllowed ?? broadcast.sound_allowed, field + ".soundAllowed");
  if (broadcast.startsAt || broadcast.starts_at || broadcast.scheduledAt || broadcast.scheduled_at) scheduledBroadcasts += 1;
  if (validateTargeting(broadcast.targeting ?? broadcast.audience ?? broadcast.visibility, field + ".targeting")) {
    targetedBroadcasts += 1;
  }
}

if (requireTargeting && targetedBroadcasts === 0) fail("at least one broadcast must include explicit targeting/audience");

let showBroadcastCommands = 0;
const commandIds = new Set();
for (const [index, command] of commands.entries()) {
  const field = "commands[" + index + "]";
  if (!isObject(command)) fail(field + " must be an object");
  const id = firstString(command, ["id", "commandId", "command_id"]);
  requiredString(id, field + ".id");
  if (commandIds.has(id)) fail("duplicate command id: " + id);
  commandIds.add(id);
  requiredString(firstString(command, ["deviceId", "device_id"]), field + ".deviceId");
  const type = firstString(command, ["commandType", "command_type", "action", "type"]);
  requiredString(type, field + ".commandType");
  const status = firstString(command, ["status", "state"]) || "queued";
  if (!allowedCommandStatuses.has(status)) fail(field + ".status is not recognized: " + status);
  optionalIso(command.createdAt || command.created_at || command.queuedAt || command.queued_at, field + ".createdAt");
  optionalIso(command.acknowledgedAt || command.acknowledged_at, field + ".acknowledgedAt");
  optionalIso(command.completedAt || command.completed_at, field + ".completedAt");

  if (type === "show_broadcast") {
    showBroadcastCommands += 1;
    const broadcastId = nestedBroadcastId(command);
    requiredString(broadcastId, field + ".payload.broadcastId");
    if (broadcastIds.size && !broadcastIds.has(broadcastId)) {
      fail(field + " references unknown broadcast id: " + broadcastId);
    }
    const auth = (isObject(command.payload) && command.payload.authorization) || command.authorization || null;
    validateAuthorization(auth, field, "show_broadcast");
  }
}

if (requireCommands && showBroadcastCommands === 0) fail("at least one queued show_broadcast command is required");

let displayEvents = 0;
let failedDeliveries = 0;
for (const [index, delivery] of deliveries.entries()) {
  const field = "deliveries[" + index + "]";
  if (!isObject(delivery)) fail(field + " must be an object");
  const broadcastId = nestedBroadcastId(delivery);
  requiredString(broadcastId, field + ".broadcastId");
  if (broadcastIds.size && !broadcastIds.has(broadcastId)) {
    fail(field + " references unknown broadcast id: " + broadcastId);
  }
  requiredString(firstString(delivery, ["deviceId", "device_id"]), field + ".deviceId");
  const event = firstString(delivery, ["event", "eventType", "event_type", "status", "state"]);
  requiredString(event, field + ".event");
  if (!allowedDeliveryEvents.has(event)) fail(field + ".event is not recognized: " + event);
  optionalIso(delivery.observedAt || delivery.observed_at || delivery.createdAt || delivery.created_at || delivery.deliveredAt || delivery.delivered_at || delivery.shownAt || delivery.shown_at, field + ".observedAt");
  optionalString(delivery.commandId || delivery.command_id, field + ".commandId");
  optionalString(delivery.rolloutId || delivery.rollout_id, field + ".rolloutId");
  if (["shown", "broadcast_shown", "delivered", "completed"].includes(event)) displayEvents += 1;
  if (["failed", "expired", "broadcast_skipped"].includes(event)) failedDeliveries += 1;
}

if (requireDelivery && displayEvents === 0) {
  fail("at least one broadcast display/delivery evidence row is required");
}

const summary = payload.summary || payload.broadcastSummary || null;
if (summary !== null) {
  if (!isObject(summary)) fail("summary must be an object when present");
  for (const key of ["totalBroadcasts", "activeBroadcasts", "scheduledBroadcasts", "queuedCommands", "deliveryRows", "shownCount", "failedCount"]) {
    optionalNumber(summary[key], "summary." + key, 0);
  }
}

console.log(
  "broadcast contract ok: broadcasts=" + broadcasts.length +
    " targeted=" + targetedBroadcasts +
    " scheduled=" + scheduledBroadcasts +
    " showBroadcastCommands=" + showBroadcastCommands +
    " deliveryRows=" + deliveries.length +
    " displayEvents=" + displayEvents +
    " failedDeliveries=" + failedDeliveries
);
NODE
