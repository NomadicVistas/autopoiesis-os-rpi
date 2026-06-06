#!/usr/bin/env bash
set -euo pipefail

SOURCE="${1:-${AUTOPOIESIS_HEARTBEAT_CONTRACT_SOURCE:-}}"
REQUEST_SOURCE="${AUTOPOIESIS_HEARTBEAT_CONTRACT_REQUEST:-}"
REQUIRE_EVENTS_ACK="${AUTOPOIESIS_REQUIRE_HEARTBEAT_EVENTS_ACK:-1}"
REQUIRE_EVENTS="${AUTOPOIESIS_REQUIRE_HEARTBEAT_EVENTS:-1}"
REQUIRE_SETTINGS="${AUTOPOIESIS_REQUIRE_HEARTBEAT_SETTINGS:-0}"
REQUIRE_COMMANDS="${AUTOPOIESIS_REQUIRE_HEARTBEAT_COMMANDS:-0}"
TMP_FILE=""

cleanup() {
  if [[ -n "$TMP_FILE" ]]; then
    rm -f "$TMP_FILE"
  fi
}
trap cleanup EXIT

fail() {
  echo "heartbeat contract check failed: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/heartbeat-contract-check.sh <heartbeat-bundle-or-response.json>
  scripts/heartbeat-contract-check.sh https://example/api/frames/device/<deviceId>/heartbeat

Environment:
  AUTOPOIESIS_HEARTBEAT_CONTRACT_SOURCE   default bundle/response file or URL when no argument is passed
  AUTOPOIESIS_HEARTBEAT_CONTRACT_REQUEST  request JSON file for live URL POST checks
  AUTOPOIESIS_HEARTBEAT_CONTRACT_TOKEN    optional bearer token for URL checks
  AUTOPOIESIS_REQUIRE_HEARTBEAT_EVENTS_ACK require eventsAck/deviceEventsAck, default 1
  AUTOPOIESIS_REQUIRE_HEARTBEAT_EVENTS    require exported request events, default 1
  AUTOPOIESIS_REQUIRE_HEARTBEAT_SETTINGS  require response settings payload, default 0
  AUTOPOIESIS_REQUIRE_HEARTBEAT_COMMANDS  require at least one response command, default 0

Saved files may be either a heartbeat response object or a bundle with request
and response/body/heartbeatResponse sections.
EOF
}

if [[ -z "$SOURCE" ]]; then
  usage
  exit 2
fi

if [[ "$SOURCE" =~ ^https?:// ]]; then
  [[ -n "$REQUEST_SOURCE" ]] || fail "live URL checks require AUTOPOIESIS_HEARTBEAT_CONTRACT_REQUEST"
  [[ -f "$REQUEST_SOURCE" ]] || fail "request JSON file not found: $REQUEST_SOURCE"
  TMP_FILE="$(mktemp)"
  CURL_ARGS=(-fsS -X POST -H "content-type: application/json" --data-binary "@$REQUEST_SOURCE")
  if [[ -n "${AUTOPOIESIS_HEARTBEAT_CONTRACT_TOKEN:-}" ]]; then
    CURL_ARGS+=(-H "Authorization: Bearer ${AUTOPOIESIS_HEARTBEAT_CONTRACT_TOKEN}")
  fi
  curl "${CURL_ARGS[@]}" "$SOURCE" >"$TMP_FILE" || fail "could not fetch heartbeat URL"
  SOURCE="$TMP_FILE"
fi

[[ -f "$SOURCE" ]] || fail "heartbeat bundle/response file not found: $SOURCE"

node - "$SOURCE" "$REQUEST_SOURCE" "$REQUIRE_EVENTS_ACK" "$REQUIRE_EVENTS" "$REQUIRE_SETTINGS" "$REQUIRE_COMMANDS" <<'NODE'
const fs = require("fs");

const [
  file,
  requestSource,
  requireEventsAckValue,
  requireEventsValue,
  requireSettingsValue,
  requireCommandsValue
] = process.argv.slice(2);

const requireEventsAck = requireEventsAckValue !== "0";
const requireEvents = requireEventsValue !== "0";
const requireSettings = requireSettingsValue === "1";
const requireCommands = requireCommandsValue === "1";

const forbiddenPatterns = [
  /deviceApiKey/i,
  /device_api_key/i,
  /pairingCodeHash/i,
  /pairing_code_hash/i,
  /accessToken/i,
  /refreshToken/i,
  /apiKey/i,
  /secret/i,
  /password/i,
  /privateToken/i,
  /adminToken/i,
  /\/var\/lib\/autopoiesis-os/i,
  /\/opt\/autopoiesis-os/i,
  /\/home\/frame/i
];

const commandPolicies = {
  sync_settings: { risk: "low", authorization: false, auditId: false },
  clear_cache: { risk: "medium", authorization: true, auditId: false },
  restart_display: { risk: "medium", authorization: true, auditId: false },
  enable_device: { risk: "medium", authorization: true, auditId: false },
  show_broadcast: { risk: "medium", authorization: true, auditId: false },
  restart_device: { risk: "high", authorization: true, auditId: true },
  update_device: { risk: "high", authorization: true, auditId: true },
  disable_device: { risk: "high", authorization: true, auditId: true },
  factory_reset_request: { risk: "critical", authorization: true, auditId: true }
};

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

function optionalNumber(value, field) {
  if (value === undefined || value === null || value === "") return;
  if (!Number.isFinite(Number(value))) fail(field + " must be numeric when present");
}

function optionalArray(value, field) {
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value)) fail(field + " must be an array when present");
  return value;
}

function readJson(path, label) {
  try {
    return JSON.parse(fs.readFileSync(path, "utf8"));
  } catch (error) {
    fail("invalid " + label + " JSON: " + error.message);
  }
}

function assertRedacted(value, field) {
  const raw = JSON.stringify(value);
  for (const pattern of forbiddenPatterns) {
    if (pattern.test(raw)) fail(field + " appears to expose sensitive or local-only data: " + pattern);
  }
}

function validateSettings(settings, field) {
  if (!isObject(settings)) fail(field + " must be an object");
  optionalIso(settings.updatedAt || settings.updated_at, field + ".updatedAt");
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
    "showArtworkInfoOnTap"
  ]) {
    optionalBoolean(settings[key], field + "." + key);
  }
  for (const key of ["volume", "imageDuration", "brightness", "cacheSizeLimitMb"]) {
    optionalNumber(settings[key], field + "." + key);
  }
  optionalString(settings.displayMode, field + ".displayMode");
  optionalString(settings.streamProfile, field + ".streamProfile");
}

function validateDiagnostics(diagnostics, field) {
  if (diagnostics === undefined || diagnostics === null) return;
  if (!isObject(diagnostics)) fail(field + " must be an object when present");
  optionalIso(diagnostics.collectedAt || diagnostics.generatedAt, field + ".collectedAt");
  optionalString(diagnostics.deviceId, field + ".deviceId");
  optionalString(diagnostics.deviceName, field + ".deviceName");
  optionalString(diagnostics.softwareVersion, field + ".softwareVersion");
  optionalString(diagnostics.hostname, field + ".hostname");
  optionalString(diagnostics.platform, field + ".platform");
  optionalString(diagnostics.arch, field + ".arch");
  optionalNumber(diagnostics.uptimeSeconds, field + ".uptimeSeconds");
  if (diagnostics.network !== undefined && !isObject(diagnostics.network)) fail(field + ".network must be an object when present");
  if (diagnostics.pairing !== undefined && !isObject(diagnostics.pairing)) fail(field + ".pairing must be an object when present");
  if (diagnostics.settingsSync !== undefined && !isObject(diagnostics.settingsSync)) fail(field + ".settingsSync must be an object when present");
}

function validateEventCursor(cursor, field) {
  if (cursor === undefined || cursor === null) return;
  if (!isObject(cursor)) fail(field + " must be an object when present");
  optionalString(cursor.status, field + ".status");
  optionalIso(cursor.acceptedAt, field + ".acceptedAt");
  optionalIso(cursor.acceptedThroughObservedAt || cursor.latestObservedAt, field + ".acceptedThroughObservedAt");
  optionalString(cursor.acceptedThroughEventKey || cursor.latestEventKey, field + ".acceptedThroughEventKey");
  optionalIso(cursor.replaySince, field + ".replaySince");
}

function validateEvents(eventsPayload, field) {
  if (!isObject(eventsPayload)) fail(field + " must be an object");
  const events = optionalArray(eventsPayload.events, field + ".events");
  if (requireEvents && events.length === 0) fail(field + ".events must include at least one exported event");
  if (eventsPayload.cursor !== undefined && !isObject(eventsPayload.cursor)) fail(field + ".cursor must be an object when present");
  if (eventsPayload.sourceCursors !== undefined && !isObject(eventsPayload.sourceCursors)) fail(field + ".sourceCursors must be an object when present");
  const keys = new Set();
  for (const [index, event] of events.entries()) {
    const prefix = field + ".events[" + index + "]";
    if (!isObject(event)) fail(prefix + " must be an object");
    if (!event.source || typeof event.source !== "string") fail(prefix + ".source is required");
    if (!event.eventKey || typeof event.eventKey !== "string") fail(prefix + ".eventKey is required");
    if (keys.has(event.eventKey)) fail("duplicate heartbeat eventKey: " + event.eventKey);
    keys.add(event.eventKey);
    optionalString(event.eventType || event.type, prefix + ".eventType");
    if (!validIso(event.observedAt || event.createdAt || event.completedAt)) fail(prefix + ".observedAt is required");
  }
  return events;
}

function validateRequest(request) {
  if (!isObject(request)) fail("request must be a JSON object");
  assertRedacted(request, "request");
  if (!request.softwareVersion || typeof request.softwareVersion !== "string") fail("request.softwareVersion is required");
  optionalString(request.currentMode, "request.currentMode");
  optionalString(request.currentArtworkId, "request.currentArtworkId");
  optionalBoolean(request.networkOnline, "request.networkOnline");
  optionalString(request.networkType, "request.networkType");
  if (request.storageStatus !== undefined && request.storageStatus !== null && !isObject(request.storageStatus) && typeof request.storageStatus !== "string") {
    fail("request.storageStatus must be an object or string when present");
  }
  validateDiagnostics(request.diagnostics, "request.diagnostics");
  validateEventCursor(request.eventIngestionCursor, "request.eventIngestionCursor");
  if (request.events === undefined || request.events === null) {
    if (requireEvents) fail("request.events is required");
  } else {
    validateEvents(request.events, "request.events");
  }
}

function validateCommand(command, field) {
  if (!isObject(command)) fail(field + " must be an object");
  const id = command.id || command.commandId || command.command_id;
  if (!id || typeof id !== "string") fail(field + ".id is required");
  const commandType = command.commandType || command.command_type || command.type;
  if (!commandType || typeof commandType !== "string") fail(field + ".commandType is required");
  const policy = commandPolicies[commandType];
  if (!policy) fail(field + ".commandType is unsupported: " + commandType);
  optionalIso(command.createdAt || command.created_at || command.queuedAt || command.queued_at, field + ".createdAt");
  if (command.payload !== undefined && command.payload !== null && !isObject(command.payload)) fail(field + ".payload must be an object when present");
  const authorization = ((command.payload || {}).authorization) || command.authorization || null;
  if (policy.authorization) {
    if (!isObject(authorization)) fail(field + ".payload.authorization is required for " + commandType);
    if (authorization.approved !== true) fail(field + ".payload.authorization.approved must be true");
    if (authorization.action && authorization.action !== commandType) fail(field + ".payload.authorization.action must match commandType");
    if (!authorization.actorId || typeof authorization.actorId !== "string") fail(field + ".payload.authorization.actorId is required");
    if (!authorization.actorRole || typeof authorization.actorRole !== "string") fail(field + ".payload.authorization.actorRole is required");
    if (!validIso(authorization.authorizedAt)) fail(field + ".payload.authorization.authorizedAt is required");
    if (policy.auditId && (!authorization.auditId || typeof authorization.auditId !== "string")) {
      fail(field + ".payload.authorization.auditId is required for " + commandType);
    }
  }
}

function validateEventsAck(ack, field) {
  if (!isObject(ack)) fail(field + " must be an object");
  if (!ack.status || typeof ack.status !== "string") fail(field + ".status is required");
  optionalIso(ack.acceptedAt || ack.ingestedAt || ack.updatedAt, field + ".acceptedAt");
  const observedAt = ack.acceptedThroughObservedAt || ack.latestObservedAt || ack.observedAt || ((ack.cursor || {}).latestObservedAt);
  const eventKey = ack.acceptedThroughEventKey || ack.latestEventKey || ack.eventKey || ((ack.cursor || {}).latestEventKey);
  if (!observedAt && !eventKey) fail(field + " must include acceptedThroughObservedAt or acceptedThroughEventKey");
  optionalIso(observedAt, field + ".acceptedThroughObservedAt");
  if (eventKey !== undefined && eventKey !== null && typeof eventKey !== "string") fail(field + ".acceptedThroughEventKey must be a string");
  if (ack.sourceCursors !== undefined && ack.sourceCursors !== null && !isObject(ack.sourceCursors)) fail(field + ".sourceCursors must be an object when present");
  if (ack.counts !== undefined && ack.counts !== null && !isObject(ack.counts)) fail(field + ".counts must be an object when present");
}

function validateItems(items, field) {
  if (items === undefined || items === null) return 0;
  if (!Array.isArray(items)) fail(field + " must be an array when present");
  const ids = new Set();
  for (const [index, item] of items.entries()) {
    const prefix = field + "[" + index + "]";
    if (!isObject(item)) fail(prefix + " must be an object");
    if (!item.id || typeof item.id !== "string") fail(prefix + ".id is required");
    if (ids.has(item.id)) fail("duplicate heartbeat item id: " + item.id);
    ids.add(item.id);
    if (!item.type || typeof item.type !== "string") fail(prefix + ".type is required");
    optionalString(item.title, prefix + ".title");
    optionalString(item.artist, prefix + ".artist");
    optionalString(item.artistId, prefix + ".artistId");
    optionalString(item.mediaUrl || item.media_url, prefix + ".mediaUrl");
    optionalIso(item.startsAt || item.starts_at, prefix + ".startsAt");
    optionalIso(item.expiresAt || item.expires_at, prefix + ".expiresAt");
  }
  return items.length;
}

let payload = readJson(file, "heartbeat contract");
let request = null;
let response = payload;

if (isObject(payload) && (payload.request || payload.heartbeatRequest)) {
  request = payload.request || payload.heartbeatRequest;
}
if (isObject(payload) && (payload.response || payload.body || payload.heartbeatResponse)) {
  response = payload.response || payload.body || payload.heartbeatResponse;
}
if (requestSource) {
  request = readJson(requestSource, "heartbeat request");
}

if (request) validateRequest(request);

if (!isObject(response)) fail("response must be a JSON object");
assertRedacted(response, "response");
if (response.ok === false) fail("response ok=false");

const settings = response.settings || response.preferences || null;
if (settings) validateSettings(settings, "response.settings");
if (requireSettings && !settings) fail("response.settings is required");

const commands = response.commands || response.commandQueue || [];
if (!Array.isArray(commands)) fail("response.commands must be an array when present");
if (requireCommands && commands.length === 0) fail("response.commands must include at least one command");
commands.forEach((command, index) => validateCommand(command, "response.commands[" + index + "]"));

const ack =
  response.eventsAck ||
  response.eventAck ||
  response.deviceEventsAck ||
  response.device_events_ack ||
  response.eventIngestionCursor ||
  response.ingestionCursor ||
  null;
if (ack) validateEventsAck(ack, "response.eventsAck");
if (requireEventsAck && !ack) fail("response.eventsAck/deviceEventsAck is required");

const itemCount = validateItems(response.items || response.feed || response.artworks || null, "response.items");

console.log(
  "heartbeat contract ok: request=" + (request ? "yes" : "no") +
    " settings=" + (settings ? "yes" : "no") +
    " commands=" + commands.length +
    " eventsAck=" + (ack ? "yes" : "no") +
    " items=" + itemCount
);
NODE
