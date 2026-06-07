#!/usr/bin/env bash
set -euo pipefail

LOCAL_URL="${AUTOPOIESIS_LOCAL_URL:-http://127.0.0.1:3030}"
DIAGNOSTICS_URL="${LOCAL_URL%/}/local/diagnostics?services=0"
HEALTH_URL="${LOCAL_URL%/}/local/health?services=0"
READINESS_URL="${LOCAL_URL%/}/local/readiness?services=0"
SUPPORT_URL="${LOCAL_URL%/}/local/support-bundle?services=0"
REQUIRE_SUPPORTED="${AUTOPOIESIS_REQUIRE_SUPPORTED_HARDWARE:-0}"
REQUIRE_RECOMMENDED="${AUTOPOIESIS_REQUIRE_RECOMMENDED_HARDWARE:-0}"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

curl -fsS "$DIAGNOSTICS_URL" >"$TMP_DIR/diagnostics.json"
curl -fsS "$HEALTH_URL" >"$TMP_DIR/health.json"
curl -fsS "$READINESS_URL" >"$TMP_DIR/readiness.json"
curl -fsS "$SUPPORT_URL" >"$TMP_DIR/support-bundle.json"

node - "$TMP_DIR/diagnostics.json" "$TMP_DIR/health.json" "$TMP_DIR/readiness.json" "$TMP_DIR/support-bundle.json" "$REQUIRE_SUPPORTED" "$REQUIRE_RECOMMENDED" <<'NODE'
const fs = require("fs");
const diagnosticsPayload = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const health = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const readiness = JSON.parse(fs.readFileSync(process.argv[4], "utf8"));
const support = JSON.parse(fs.readFileSync(process.argv[5], "utf8"));
const requireSupported = process.argv[6] === "1";
const requireRecommended = process.argv[7] === "1";

function fail(message, code = 3) {
  console.error("hardware profile check failed: " + message);
  process.exit(code);
}
function objectAt(value, name) {
  if (!value || typeof value !== "object" || Array.isArray(value)) fail(name + " must be an object");
  return value;
}

const raw = [diagnosticsPayload, health, readiness, support].map(value => JSON.stringify(value)).join("\n");
if (/deviceApiKey|device_api_key|apiKey|secret|token/i.test(raw)) {
  fail("hardware profile surfaces contain sensitive-looking key material.", 4);
}

const diagnostics = diagnosticsPayload.diagnostics || diagnosticsPayload;
const hardware = objectAt(diagnostics.hardware, "diagnostics.hardware");
if (!hardware.status) fail("hardware.status is missing");
if (typeof hardware.supported !== "boolean") fail("hardware.supported must be boolean");
if (typeof hardware.recommended !== "boolean") fail("hardware.recommended must be boolean");
if (!hardware.summary) fail("hardware.summary is missing");
if (!hardware.arch) fail("hardware.arch is missing");
if (!Number.isFinite(Number(hardware.ramMb))) fail("hardware.ramMb must be numeric");
if (!hardware.recommendedDevice || !hardware.supportedBaseline) fail("hardware recommendation metadata is missing");

const allowedStatuses = new Set(["recommended", "supported_baseline", "underpowered", "unknown_pi_supported_ram", "unknown_pi_low_ram", "development_host", "low_ram", "unknown"]);
if (!allowedStatuses.has(hardware.status)) fail("unexpected hardware.status: " + hardware.status);
if (hardware.throttling) {
  objectAt(hardware.throttling, "hardware.throttling");
  if (typeof hardware.throttling.available !== "boolean") fail("hardware.throttling.available must be boolean");
}

if (!health.hardware || typeof health.hardware !== "object") fail("/local/health is missing hardware summary");
if (!readiness.phases || !readiness.phases.hardware) fail("/local/readiness is missing hardware phase");
if (!support.summary || !support.summary.hardware) fail("/local/support-bundle is missing summary.hardware");

const issueCodes = ((health.health || {}).issues || []).map(issue => issue.code).filter(Boolean);
if ((hardware.status === "underpowered" || hardware.status === "low_ram") && !issueCodes.includes("hardware_underpowered")) fail("underpowered hardware did not produce hardware_underpowered health issue");
if (hardware.status === "unknown_pi_low_ram" && !issueCodes.includes("hardware_low_ram")) fail("low-RAM unknown Pi did not produce hardware_low_ram health issue");
if (hardware.status === "unknown" && !issueCodes.includes("hardware_unknown")) fail("unknown hardware did not produce hardware_unknown health issue");
if ((hardware.throttling || {}).underVoltage && !issueCodes.includes("hardware_undervoltage")) fail("under-voltage throttling did not produce hardware_undervoltage health issue");
if (((hardware.throttling || {}).throttled || (hardware.throttling || {}).frequencyCapped || (hardware.throttling || {}).softTemperatureLimit) && !issueCodes.includes("hardware_throttled")) fail("throttling did not produce hardware_throttled health issue");

if (requireSupported && !hardware.supported) fail("hardware is not supported: " + hardware.status, 2);
if (requireRecommended && !hardware.recommended) fail("hardware is not recommended: " + hardware.status, 2);

console.log("Autopoiesis Frame hardware status=" + hardware.status + " supported=" + hardware.supported + " recommended=" + hardware.recommended + " model=" + (hardware.model || "unknown") + " arch=" + hardware.arch + " ramMb=" + hardware.ramMb + " throttle=" + ((hardware.throttling || {}).raw || "unavailable") + " readiness=" + (readiness.phases.hardware.status || "unknown") + " issues=" + (issueCodes.length ? issueCodes.join(",") : "none"));
NODE
