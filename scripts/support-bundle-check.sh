#!/usr/bin/env bash
set -euo pipefail

LOCAL_URL="${AUTOPOIESIS_LOCAL_URL:-http://127.0.0.1:3030}"
SERVICES="${AUTOPOIESIS_SUPPORT_BUNDLE_SERVICES:-0}"
AUDIT_LIMIT="${AUTOPOIESIS_SUPPORT_BUNDLE_AUDIT_LIMIT:-10}"
DELIVERY_LIMIT="${AUTOPOIESIS_SUPPORT_BUNDLE_DELIVERY_LIMIT:-10}"
RELEASE_LIMIT="${AUTOPOIESIS_SUPPORT_BUNDLE_RELEASE_LIMIT:-10}"
EVENT_LIMIT="${AUTOPOIESIS_SUPPORT_BUNDLE_EVENT_LIMIT:-10}"
OUTPUT_PATH="${AUTOPOIESIS_SUPPORT_BUNDLE_CHECK_OUTPUT:-${1:-}}"
SUPPORT_URL="${LOCAL_URL%/}/local/support-bundle?services=${SERVICES}&auditLimit=${AUDIT_LIMIT}&deliveryLimit=${DELIVERY_LIMIT}&releaseLimit=${RELEASE_LIMIT}&eventLimit=${EVENT_LIMIT}"
TMP_JSON="$(mktemp)"

cleanup() {
  rm -f "$TMP_JSON"
}
trap cleanup EXIT

curl -fsS "$SUPPORT_URL" >"$TMP_JSON"

node - "$TMP_JSON" "$OUTPUT_PATH" <<'NODE'
const fs = require("fs");
const path = require("path");

const bundle = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const outputPath = process.argv[3] || "";

function fail(message, code = 2) {
  console.error("support bundle check failed: " + message);
  process.exit(code);
}

function asArray(value) {
  return Array.isArray(value) ? value : [];
}

function objectAt(value, name) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    fail(name + " must be an object");
  }
  return value;
}

function numeric(value, name) {
  if (!Number.isFinite(Number(value))) fail(name + " must be numeric");
}

function boolean(value, name) {
  if (typeof value !== "boolean") fail(name + " must be boolean");
}

function parseableTime(value, name) {
  if (!value || Number.isNaN(Date.parse(value))) fail(name + " must be an ISO timestamp");
}

function containsKey(value, keyPattern) {
  if (!value || typeof value !== "object") return false;
  if (Array.isArray(value)) return value.some(item => containsKey(item, keyPattern));
  return Object.entries(value).some(([key, child]) => keyPattern.test(key) || containsKey(child, keyPattern));
}

function containsString(value, pattern) {
  if (typeof value === "string") return pattern.test(value);
  if (!value || typeof value !== "object") return false;
  if (Array.isArray(value)) return value.some(item => containsString(item, pattern));
  return Object.values(value).some(child => containsString(child, pattern));
}

if (!bundle.ok || bundle.kind !== "autopoiesis_frame_support_bundle") fail("unexpected support bundle kind");
if (bundle.schemaVersion !== 1) fail("unexpected support bundle schema version");
if (bundle.redacted !== true) fail("support bundle is not marked redacted");
parseableTime(bundle.generatedAt, "generatedAt");

const serialized = JSON.stringify(bundle);
if (containsKey(bundle, /^(deviceApiKey|device_api_key|apiKey|api_key|pairingCodeHash|pairing_code_hash)$/i)) {
  fail("support bundle leaked a sensitive field name");
}
if (containsString(bundle, /BEGIN (RSA |EC |OPENSSH |PRIVATE )?KEY|x-frame-device-key|x-admin-token/i)) {
  fail("support bundle leaked key or token-looking material");
}
if (/"payload"\s*:/.test(serialized)) fail("support bundle exposed raw command payloads");
if (/"checksum"\s*:|sha256/i.test(serialized)) fail("support bundle exposed release checksum material");
if (/artifactUrl|artifact_url/i.test(serialized)) fail("support bundle exposed release artifact URLs");

const device = objectAt(bundle.device, "device");
if (!device.deviceId) fail("device.deviceId is missing");
if (!device.softwareVersion) fail("device.softwareVersion is missing");

const summary = objectAt(bundle.summary, "summary");
if (!["ok", "warning", "error", "unknown"].includes(String(summary.healthStatus || ""))) {
  fail("summary.healthStatus has unexpected value: " + summary.healthStatus);
}
if (!["ready", "not_ready", "blocked", "unknown"].includes(String(summary.readinessStatus || ""))) {
  fail("summary.readinessStatus has unexpected value: " + summary.readinessStatus);
}
if (!Array.isArray(summary.issueCodes)) fail("summary.issueCodes must be an array");
if (!Array.isArray(summary.blockers)) fail("summary.blockers must be an array");
for (const blocker of summary.blockers) {
  objectAt(blocker, "summary.blockers item");
  if (!blocker.phase || !blocker.status) fail("readiness blocker must include phase and status");
}

const input = objectAt(summary.input, "summary.input");
for (const field of ["touchscreenPresent", "pointerPresent", "keyboardPresent"]) {
  boolean(input[field], "summary.input." + field);
}
numeric(input.totalDevices, "summary.input.totalDevices");

if (summary.clock !== null) objectAt(summary.clock, "summary.clock");
const storage = objectAt(summary.storage, "summary.storage");
const runtime = objectAt(storage.runtime, "summary.storage.runtime");
if (!["ready", "blocked"].includes(String(runtime.status || ""))) fail("summary.storage.runtime.status is unexpected");
boolean(runtime.ok, "summary.storage.runtime.ok");
for (const name of ["dataDir", "cacheDir", "logDir"]) {
  const entry = objectAt((runtime.paths || {})[name], "summary.storage.runtime.paths." + name);
  for (const field of ["exists", "directory", "readable", "writable", "writeProbe", "ok"]) {
    boolean(entry[field], "summary.storage.runtime.paths." + name + "." + field);
  }
}

numeric(summary.pendingCommands, "summary.pendingCommands");
numeric(summary.offlinePlayableItems, "summary.offlinePlayableItems");
objectAt(summary.framePlayback, "summary.framePlayback");
objectAt(summary.commandAudit, "summary.commandAudit");
objectAt(summary.displayDelivery, "summary.displayDelivery");
objectAt(summary.releaseHistory, "summary.releaseHistory");
objectAt(summary.eventIngestion, "summary.eventIngestion");
for (const name of ["commandAudit.totalEntries", "displayDelivery.totalEntries", "releaseHistory.totalEntries"]) {
  const [section, field] = name.split(".");
  numeric(summary[section][field], "summary." + name);
}

const diagnostics = objectAt(bundle.diagnostics, "diagnostics");
if (!diagnostics.health || !diagnostics.storage) fail("diagnostics must include health and storage");
if (!bundle.health || !bundle.health.status) fail("health summary is missing");
if (!bundle.readiness || !bundle.readiness.status || !bundle.readiness.phases) fail("readiness summary is missing");

const frameState = objectAt(bundle.frameState, "frameState");
if (frameState.kind !== "autopoiesis_frame_state") fail("frameState kind is unexpected");
objectAt(frameState.playback, "frameState.playback");
for (const field of ["totalItems", "displayQueueItems", "playableItems", "cachedPlayableItems"]) {
  numeric(frameState[field], "frameState." + field);
}

const offlineCache = objectAt(bundle.offlineCache, "offlineCache");
numeric(offlineCache.playableItems || 0, "offlineCache.playableItems");

const adminCapabilities = objectAt(bundle.adminCapabilities, "adminCapabilities");
if (adminCapabilities.kind !== "autopoiesis_frame_admin_capabilities") fail("adminCapabilities kind is unexpected");
if (adminCapabilities.redacted !== true) fail("adminCapabilities must be redacted");
const commandTypes = new Set(asArray(adminCapabilities.commands).map(command => command.commandType).filter(Boolean));
for (const type of ["sync_settings", "clear_cache", "restart_display", "show_broadcast", "update_device", "disable_device", "factory_reset_request"]) {
  if (!commandTypes.has(type)) fail("adminCapabilities missing command policy for " + type);
}

const deviceEvents = objectAt(bundle.deviceEvents, "deviceEvents");
if (deviceEvents.kind !== "autopoiesis_frame_event_export") fail("deviceEvents kind is unexpected");
if (deviceEvents.redacted !== true) fail("deviceEvents must be redacted");
numeric((deviceEvents.counts || {}).exported || 0, "deviceEvents.counts.exported");

for (const section of ["feed", "commandAudit", "deliveryLog", "releaseHistory"]) {
  objectAt(bundle[section], section);
}

if (outputPath) {
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, JSON.stringify(bundle, null, 2) + "\n");
  console.log("bundle=" + outputPath);
} else {
  console.log([
    "Autopoiesis Frame support bundle contract",
    "device=" + device.deviceId,
    "health=" + summary.healthStatus,
    "readiness=" + summary.readinessStatus,
    "storage=" + runtime.status,
    "input=" + (input.status || "unknown"),
    "events=" + ((deviceEvents.counts || {}).exported || 0),
    "pending=" + summary.pendingCommands
  ].join(" "));
}
NODE
