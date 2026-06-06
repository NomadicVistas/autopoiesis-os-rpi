#!/usr/bin/env bash
set -euo pipefail

LOCAL_URL="${AUTOPOIESIS_LOCAL_URL:-http://127.0.0.1:3030}"
PROFILE="${AUTOPOIESIS_ROLLOUT_PROFILE:-staged}"
STRICT_CONTENT="${AUTOPOIESIS_ROLLOUT_STRICT_CONTENT:-0}"
ACCEPT_WARNINGS="${AUTOPOIESIS_ROLLOUT_ACCEPT_WARNINGS:-1}"
ACCEPTANCE_URL="${LOCAL_URL%/}/local/rollout/acceptance?profile=${PROFILE}&strictContent=${STRICT_CONTENT}"
TMP_JSON="$(mktemp)"

cleanup() {
  rm -f "$TMP_JSON"
}
trap cleanup EXIT

curl -fsS "$ACCEPTANCE_URL" >"$TMP_JSON"

node - "$TMP_JSON" "$ACCEPT_WARNINGS" <<'NODE'
const fs = require("fs");
const payload = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const acceptWarnings = process.argv[3] !== "0";
const blockers = Array.isArray(payload.blockers) ? payload.blockers : [];
const warnings = Array.isArray(payload.warnings) ? payload.warnings : [];
const summary = payload.summary || {};
const required = String(summary.requiredPassed || 0) + "/" + String(summary.requiredTotal || 0);

console.log([
  "Autopoiesis Frame rollout acceptance",
  "profile=" + (payload.profile || "unknown"),
  "status=" + (payload.status || "unknown"),
  "device=" + ((payload.device || {}).deviceId || "unknown"),
  "health=" + (payload.healthStatus || "unknown"),
  "readiness=" + (payload.readinessStatus || "unknown"),
  "required=" + required,
  "events=" + (summary.exportedEvents || 0)
].join(" "));

if (blockers.length) {
  console.log("blockers=" + blockers.map(item => item.id + ":" + (item.summary || item.label || "blocked")).join(" | "));
}
if (warnings.length) {
  console.log("warnings=" + warnings.map(item => item.id + ":" + (item.summary || item.label || "warning")).join(" | "));
}

if (!payload.ok || payload.status === "blocked") process.exit(2);
if (payload.status === "warning" && !acceptWarnings) process.exit(4);
if (payload.kind !== "autopoiesis_frame_rollout_acceptance" || payload.redacted !== true) process.exit(3);
NODE
