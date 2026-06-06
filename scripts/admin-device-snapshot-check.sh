#!/usr/bin/env bash
set -euo pipefail

LOCAL_URL="${AUTOPOIESIS_LOCAL_URL:-http://127.0.0.1:3030}"
SERVICES="${AUTOPOIESIS_ADMIN_SNAPSHOT_SERVICES:-0}"
AUDIT_LIMIT="${AUTOPOIESIS_ADMIN_SNAPSHOT_AUDIT_LIMIT:-25}"
DELIVERY_LIMIT="${AUTOPOIESIS_ADMIN_SNAPSHOT_DELIVERY_LIMIT:-25}"
RELEASE_LIMIT="${AUTOPOIESIS_ADMIN_SNAPSHOT_RELEASE_LIMIT:-25}"
EVENT_LIMIT="${AUTOPOIESIS_ADMIN_SNAPSHOT_EVENT_LIMIT:-25}"
REQUIRE_READY="${AUTOPOIESIS_REQUIRE_DEVICE_ADMIN_READY:-0}"
OUTPUT_PATH="${AUTOPOIESIS_ADMIN_SNAPSHOT_PATH:-${1:-}}"
SUPPORT_URL="${LOCAL_URL%/}/local/support-bundle?services=${SERVICES}&auditLimit=${AUDIT_LIMIT}&deliveryLimit=${DELIVERY_LIMIT}&releaseLimit=${RELEASE_LIMIT}&eventLimit=${EVENT_LIMIT}"
TMP_JSON="$(mktemp)"

cleanup() {
  rm -f "$TMP_JSON"
}
trap cleanup EXIT

curl -fsS "$SUPPORT_URL" >"$TMP_JSON"

node - "$TMP_JSON" "$OUTPUT_PATH" "$REQUIRE_READY" <<'NODE'
const fs = require("fs");
const path = require("path");

const support = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const outputPath = process.argv[3] || "";
const requireReady = process.argv[4] === "1";

function fail(message) {
  console.error("admin device snapshot check failed: " + message);
  process.exit(2);
}

function asArray(value) {
  return Array.isArray(value) ? value : [];
}

function numberValue(value, fallback = 0) {
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
}

function text(value, fallback = null) {
  if (value === undefined || value === null || value === "") return fallback;
  return String(value);
}

if (!support.ok || support.kind !== "autopoiesis_frame_support_bundle") fail("unexpected support bundle kind");
if (support.schemaVersion !== 1) fail("unexpected support bundle schema version");
if (support.redacted !== true) fail("support bundle is not marked redacted");

const serialized = JSON.stringify(support);
if (serialized.includes("deviceApiKey") || serialized.includes("device_api_key")) {
  fail("device API key field leaked into support bundle");
}

const device = support.device || {};
if (!device.deviceId) fail("missing device id");

const summary = support.summary || {};
const healthStatus = text(summary.healthStatus, "unknown");
const readinessStatus = text(summary.readinessStatus, "unknown");
if (!healthStatus) fail("missing health status");
if (!readinessStatus) fail("missing readiness status");

const adminCapabilities = support.adminCapabilities || {};
if (adminCapabilities.kind !== "autopoiesis_frame_admin_capabilities") {
  fail("support bundle missing admin capabilities contract");
}
if (adminCapabilities.redacted !== true) fail("admin capabilities are not marked redacted");

const adminDevice = adminCapabilities.device || {};
for (const field of ["paired", "deviceKeyPresent", "remoteEnabled"]) {
  if (typeof adminDevice[field] !== "boolean") fail("admin device " + field + " is not boolean");
}

const authorization = adminCapabilities.authorization || {};
const acceptedActorRoles = asArray(authorization.acceptedActorRoles);
if (!acceptedActorRoles.length) fail("missing accepted admin actor roles");
if (!Number.isFinite(Number(authorization.authorizationWindowSeconds))) {
  fail("authorization window is missing or invalid");
}

const commands = asArray(adminCapabilities.commands);
if (!commands.length) fail("admin capabilities did not include command policies");
const commandTypes = new Set(commands.map(command => command.commandType).filter(Boolean));
for (const requiredType of ["sync_settings", "clear_cache", "restart_display", "show_broadcast", "update_device", "disable_device"]) {
  if (!commandTypes.has(requiredType)) fail("missing remote action policy for " + requiredType);
}

for (const command of commands) {
  if (!command.commandType) fail("command policy missing commandType");
  if (!command.risk) fail(command.commandType + " missing risk");
  if (typeof command.requiresAuthorization !== "boolean") fail(command.commandType + " requiresAuthorization is not boolean");
  if (typeof command.requiresAuditId !== "boolean") fail(command.commandType + " requiresAuditId is not boolean");
  if (!command.execution || !command.execution.status) fail(command.commandType + " missing execution status");
}

const frameState = support.frameState || {};
if (frameState.kind !== "autopoiesis_frame_state") fail("support bundle missing frame-state contract");
if (!frameState.playback || typeof frameState.playback !== "object") fail("frame-state playback summary missing");
for (const field of ["totalItems", "displayQueueItems", "playableItems", "cachedPlayableItems"]) {
  if (!Number.isFinite(Number(frameState[field]))) fail("frame-state " + field + " is not numeric");
}

const offlineCache = support.offlineCache || {};
if (!Number.isFinite(Number(offlineCache.playableItems || 0))) fail("offline-cache playableItems is not numeric");

const deviceEvents = support.deviceEvents || {};
if (deviceEvents.kind !== "autopoiesis_frame_event_export") fail("support bundle missing device event export");
if (deviceEvents.redacted !== true) fail("device event export is not marked redacted");
if (!Number.isFinite(Number((deviceEvents.counts || {}).exported || 0))) {
  fail("device event export missing numeric exported count");
}

const readiness = support.readiness || {};
const blockers = asArray(readiness.blockers);
const issueCodes = asArray(summary.issueCodes).map(String);
const eventIngestion = summary.eventIngestion || {};
const commandAudit = summary.commandAudit || {};
const displayDelivery = summary.displayDelivery || {};
const releaseHistory = summary.releaseHistory || {};

if (!Number.isFinite(Number(adminCapabilities.pendingCommands))) fail("pendingCommands is not numeric");
if (!commandAudit || !Number.isFinite(Number(commandAudit.totalEntries || 0))) fail("command audit summary missing");
if (!displayDelivery || !Number.isFinite(Number(displayDelivery.totalEntries || 0))) fail("display delivery summary missing");
if (!releaseHistory || !Number.isFinite(Number(releaseHistory.totalEntries || 0))) fail("release history summary missing");

if (requireReady) {
  if (!adminDevice.paired || !adminDevice.deviceKeyPresent || !adminDevice.remoteEnabled) {
    fail("device is not ready for role-gated remote admin: requires paired, stored key, and remoteEnabled=true");
  }
  if (healthStatus === "error") fail("device health is error");
}

const snapshot = {
  ok: true,
  kind: "autopoiesis_frame_admin_device_snapshot",
  schemaVersion: 1,
  redacted: true,
  generatedAt: new Date().toISOString(),
  device: {
    deviceId: text(device.deviceId),
    deviceName: text(device.deviceName),
    softwareVersion: text(device.softwareVersion)
  },
  status: {
    healthStatus,
    readinessStatus,
    issueCodes,
    blockers: blockers.map(blocker => ({
      phase: text(blocker.phase, "unknown"),
      status: text(blocker.status, "unknown"),
      summary: text(blocker.summary, "")
    }))
  },
  pairing: {
    paired: Boolean(adminDevice.paired),
    deviceKeyPresent: Boolean(adminDevice.deviceKeyPresent),
    remoteEnabled: Boolean(adminDevice.remoteEnabled)
  },
  playback: {
    status: text(frameState.playback.status, "unknown"),
    ready: Boolean(frameState.playback.ready),
    totalItems: numberValue(frameState.totalItems),
    displayQueueItems: numberValue(frameState.displayQueueItems),
    playableItems: numberValue(frameState.playableItems),
    cachedPlayableItems: numberValue(frameState.cachedPlayableItems),
    offlinePlayableItems: numberValue(offlineCache.playableItems)
  },
  remoteActions: {
    pendingCommands: numberValue(adminCapabilities.pendingCommands),
    acceptedActorRoles,
    authorizationWindowSeconds: numberValue(authorization.authorizationWindowSeconds),
    highRiskRequiresAuditId: Boolean(authorization.highRiskRequiresAuditId),
    criticalRiskRequiresAuditId: Boolean(authorization.criticalRiskRequiresAuditId),
    commands: commands.map(command => ({
      commandType: command.commandType,
      risk: command.risk,
      requiresAuthorization: Boolean(command.requiresAuthorization),
      requiresAuditId: Boolean(command.requiresAuditId),
      requiresLocalConfirmation: Boolean(command.requiresLocalConfirmation),
      executionStatus: text((command.execution || {}).status, "unknown")
    }))
  },
  evidence: {
    commandAudit: {
      totalEntries: numberValue(commandAudit.totalEntries),
      lastStatus: text(commandAudit.lastStatus),
      recentErrors: numberValue(commandAudit.recentErrors)
    },
    displayDelivery: {
      totalEntries: numberValue(displayDelivery.totalEntries),
      lastEventType: text(displayDelivery.lastEventType),
      recentBroadcastEvents: numberValue(displayDelivery.recentBroadcastEvents)
    },
    releaseHistory: {
      totalEntries: numberValue(releaseHistory.totalEntries),
      lastStatus: text(releaseHistory.lastStatus),
      lastVersion: text(releaseHistory.lastVersion),
      recentFailures: numberValue(releaseHistory.recentFailures)
    },
    deviceEvents: {
      exported: numberValue((deviceEvents.counts || {}).exported),
      hasMore: Boolean((deviceEvents.cursor || {}).hasMore),
      latestEventKey: text((deviceEvents.cursor || {}).latestEventKey),
      acceptedThroughObservedAt: text(eventIngestion.acceptedThroughObservedAt),
      replaySince: text(eventIngestion.replaySince)
    }
  }
};

if (JSON.stringify(snapshot).includes("deviceApiKey") || JSON.stringify(snapshot).includes("device_api_key")) {
  fail("snapshot contains a device API key field");
}

if (outputPath) {
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, JSON.stringify(snapshot, null, 2) + "\n");
  console.log("snapshot=" + outputPath);
} else {
  console.log([
    "Autopoiesis Frame admin snapshot",
    "device=" + snapshot.device.deviceId,
    "health=" + snapshot.status.healthStatus,
    "readiness=" + snapshot.status.readinessStatus,
    "paired=" + snapshot.pairing.paired,
    "key=" + snapshot.pairing.deviceKeyPresent,
    "remoteEnabled=" + snapshot.pairing.remoteEnabled,
    "playback=" + snapshot.playback.status,
    "events=" + snapshot.evidence.deviceEvents.exported,
    "pending=" + snapshot.remoteActions.pendingCommands
  ].join(" "));
}
NODE
