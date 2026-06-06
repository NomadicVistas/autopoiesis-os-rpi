#!/usr/bin/env bash
set -euo pipefail

LOCAL_URL="${AUTOPOIESIS_LOCAL_URL:-http://127.0.0.1:3030}"
DIAGNOSTICS_URL="${LOCAL_URL%/}/local/diagnostics"
HEALTH_URL="${LOCAL_URL%/}/local/health?services=0"
READINESS_URL="${LOCAL_URL%/}/local/readiness?services=0"
SUPPORT_URL="${LOCAL_URL%/}/local/support-bundle?services=0"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

curl -fsS "$DIAGNOSTICS_URL" >"$TMP_DIR/diagnostics.json"
curl -fsS "$HEALTH_URL" >"$TMP_DIR/health.json"
curl -fsS "$READINESS_URL" >"$TMP_DIR/readiness.json"
curl -fsS "$SUPPORT_URL" >"$TMP_DIR/support-bundle.json"

node - "$TMP_DIR/diagnostics.json" "$TMP_DIR/health.json" "$TMP_DIR/readiness.json" "$TMP_DIR/support-bundle.json" <<'NODE'
const fs = require("fs");
const diagnosticsPayload = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const health = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const readiness = JSON.parse(fs.readFileSync(process.argv[4], "utf8"));
const support = JSON.parse(fs.readFileSync(process.argv[5], "utf8"));
const requireSync = process.env.AUTOPOIESIS_REQUIRE_CLOCK_SYNC === "1";
const requireAvailable = process.env.AUTOPOIESIS_REQUIRE_CLOCK_AVAILABLE === "1" || requireSync;
const raw = [diagnosticsPayload, health, readiness, support].map(value => JSON.stringify(value)).join("\n");

function fail(message, code = 3) {
  console.error(message);
  process.exit(code);
}

if (/deviceApiKey|device_api_key|apiKey|secret|token/i.test(raw)) {
  fail("Clock diagnostics surfaces contain sensitive-looking key material.", 4);
}

const diagnostics = diagnosticsPayload.diagnostics || diagnosticsPayload;
if (!diagnostics || typeof diagnostics !== "object") fail("Diagnostics payload is not an object.");
const clock = diagnostics.clock || null;
if (!clock || typeof clock !== "object") fail("Diagnostics payload is missing clock.");
if (typeof clock.systemTime !== "string" || Number.isNaN(Date.parse(clock.systemTime))) {
  fail("clock.systemTime must be a parseable ISO timestamp.");
}
if (!Number.isFinite(clock.epochSeconds)) fail("clock.epochSeconds must be numeric.");
if (!["synchronized", "unsynchronized", "unavailable", "unknown"].includes(clock.status)) {
  fail("clock.status has unexpected value: " + clock.status);
}
if (typeof clock.ok !== "boolean") fail("clock.ok must be a boolean.");

if (!health.clock || typeof health.clock !== "object") fail("/local/health is missing clock summary.");
if (!readiness.phases || !readiness.phases.clock) fail("/local/readiness is missing clock phase.");
if (!support.summary || !support.summary.clock) fail("/local/support-bundle is missing summary.clock.");

const issueCodes = ((health.health || {}).issues || []).map(issue => issue.code).filter(Boolean);
if (clock.status === "unsynchronized" && !issueCodes.includes("clock_unsynchronized")) {
  fail("Unsynchronized clock did not produce clock_unsynchronized health issue.");
}
if (clock.status === "unavailable" && !issueCodes.includes("clock_unknown")) {
  fail("Unavailable clock did not produce clock_unknown health issue.");
}
if (clock.ntpEnabled === false && !issueCodes.includes("clock_ntp_disabled")) {
  fail("Disabled NTP did not produce clock_ntp_disabled health issue.");
}

if (requireAvailable && clock.status === "unavailable") fail("Clock synchronization status is unavailable.", 2);
if (requireSync && clock.status !== "synchronized") {
  fail("System clock is not synchronized: status=" + clock.status, 2);
}

console.log([
  "Autopoiesis Frame clock",
  "status=" + clock.status,
  "ntp=" + (clock.ntpEnabled === null ? "unknown" : clock.ntpEnabled),
  "ntpSync=" + (clock.ntpSynchronized === null ? "unknown" : clock.ntpSynchronized),
  "systemSync=" + (clock.systemClockSynchronized === null ? "unknown" : clock.systemClockSynchronized),
  "timezone=" + (clock.timezone || "unknown"),
  "readiness=" + (readiness.phases.clock.status || "unknown"),
  "issues=" + (issueCodes.length ? issueCodes.join(",") : "none")
].join(" "));
NODE
