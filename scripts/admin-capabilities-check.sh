#!/usr/bin/env bash
set -euo pipefail

LOCAL_URL="${AUTOPOIESIS_LOCAL_URL:-http://127.0.0.1:3030}"
CAPABILITIES_URL="${LOCAL_URL%/}/local/admin/capabilities"
TMP_JSON="$(mktemp)"

cleanup() {
  rm -f "$TMP_JSON"
}
trap cleanup EXIT

curl -fsS "$CAPABILITIES_URL" >"$TMP_JSON"

node - "$TMP_JSON" <<'NODE'
const fs = require("fs");
const payload = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const expectedRoles = ["admin", "maintainer", "ops", "owner", "super_admin", "support"];
const expectedPolicies = {
  sync_settings: { risk: "low", requiresAuthorization: false, requiresAuditId: false },
  clear_cache: { risk: "medium", requiresAuthorization: true, requiresAuditId: false },
  restart_display: { risk: "medium", requiresAuthorization: true, requiresAuditId: false },
  enable_device: { risk: "medium", requiresAuthorization: true, requiresAuditId: false },
  show_broadcast: { risk: "medium", requiresAuthorization: true, requiresAuditId: false },
  restart_device: { risk: "high", requiresAuthorization: true, requiresAuditId: true },
  update_device: { risk: "high", requiresAuthorization: true, requiresAuditId: true },
  disable_device: { risk: "high", requiresAuthorization: true, requiresAuditId: true },
  factory_reset_request: {
    risk: "critical",
    requiresAuthorization: true,
    requiresAuditId: true,
    requiresLocalConfirmation: true
  }
};

function fail(message) {
  console.error("admin capabilities check failed: " + message);
  process.exit(2);
}

if (!payload.ok || payload.kind !== "autopoiesis_frame_admin_capabilities") fail("unexpected payload kind");
if (payload.schemaVersion !== 1) fail("unexpected schema version");
if (payload.redacted !== true) fail("payload is not marked redacted");

const serialized = JSON.stringify(payload);
if (serialized.includes("deviceApiKey") || serialized.includes("device_api_key")) fail("device API key field leaked");

const device = payload.device || {};
if (!device.deviceId) fail("missing device id");
if (typeof device.paired !== "boolean") fail("device.paired is not boolean");
if (typeof device.deviceKeyPresent !== "boolean") fail("device.deviceKeyPresent is not boolean");
if (typeof device.remoteEnabled !== "boolean") fail("device.remoteEnabled is not boolean");

const authorization = payload.authorization || {};
const roles = Array.isArray(authorization.acceptedActorRoles) ? authorization.acceptedActorRoles : [];
if (JSON.stringify(roles) !== JSON.stringify(expectedRoles)) fail("accepted actor roles changed unexpectedly");
if (!Number.isFinite(Number(authorization.authorizationWindowSeconds)) || Number(authorization.authorizationWindowSeconds) <= 0) {
  fail("authorization window is missing or invalid");
}
if (authorization.highRiskRequiresAuditId !== true || authorization.criticalRiskRequiresAuditId !== true) {
  fail("high/critical audit-id requirements are missing");
}

const commands = Array.isArray(payload.commands) ? payload.commands : null;
if (!commands) fail("commands is not an array");
const byType = new Map(commands.map(command => [command.commandType, command]));
for (const [commandType, policy] of Object.entries(expectedPolicies)) {
  const command = byType.get(commandType);
  if (!command) fail("missing command policy for " + commandType);
  if (command.risk !== policy.risk) fail(commandType + " risk mismatch");
  if (command.requiresAuthorization !== policy.requiresAuthorization) fail(commandType + " authorization requirement mismatch");
  if (command.requiresAuditId !== policy.requiresAuditId) fail(commandType + " audit-id requirement mismatch");
  if (Boolean(command.requiresLocalConfirmation) !== Boolean(policy.requiresLocalConfirmation)) {
    fail(commandType + " local-confirmation requirement mismatch");
  }
  if (policy.requiresAuthorization) {
    const commandRoles = Array.isArray(command.acceptedActorRoles) ? command.acceptedActorRoles : [];
    if (JSON.stringify(commandRoles) !== JSON.stringify(expectedRoles)) fail(commandType + " accepted roles mismatch");
  }
  const execution = command.execution || {};
  if (!execution.status) fail(commandType + " execution status missing");
}

const restartDevice = byType.get("restart_device");
if (!["available", "requires_runtime_opt_in"].includes((restartDevice.execution || {}).status)) {
  fail("restart_device execution status is not an expected runtime state");
}
const factoryReset = byType.get("factory_reset_request");
if ((factoryReset.execution || {}).status !== "blocked_until_local_confirmation") {
  fail("factory_reset_request must remain blocked until local confirmation");
}

if (!Number.isFinite(Number(payload.pendingCommands))) fail("pendingCommands is not numeric");
if (process.env.AUTOPOIESIS_REQUIRE_REMOTE_ADMIN_READY === "1") {
  if (!device.paired || !device.deviceKeyPresent || !device.remoteEnabled) {
    fail("remote admin is not ready: requires paired device, stored key, and remoteEnabled=true");
  }
}

console.log([
  "Autopoiesis Frame admin capabilities",
  "device=" + device.deviceId,
  "paired=" + device.paired,
  "key=" + device.deviceKeyPresent,
  "remoteEnabled=" + device.remoteEnabled,
  "commands=" + commands.length,
  "pending=" + Number(payload.pendingCommands || 0)
].join(" "));
NODE
