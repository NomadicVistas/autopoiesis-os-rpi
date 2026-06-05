#!/usr/bin/env bash
set -euo pipefail

LOCAL_URL="${AUTOPOIESIS_LOCAL_URL:-http://127.0.0.1:3030}"
READINESS_URL="${LOCAL_URL%/}/local/readiness"
TMP_JSON="$(mktemp)"

cleanup() {
  rm -f "$TMP_JSON"
}
trap cleanup EXIT

curl -fsS "$READINESS_URL" >"$TMP_JSON"

node - "$TMP_JSON" <<'NODE'
const fs = require("fs");
const payload = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const phases = payload.phases || {};
const blockers = Array.isArray(payload.blockers) ? payload.blockers : [];
const phaseSummary = Object.entries(phases)
  .map(([name, value]) => name + "=" + (value.status || "unknown"))
  .join(" ");

console.log([
  "Autopoiesis Frame readiness",
  "status=" + (payload.status || "unknown"),
  "health=" + (payload.healthStatus || "unknown"),
  "device=" + ((payload.device || {}).deviceId || "unknown"),
  phaseSummary
].filter(Boolean).join(" "));

if (blockers.length) {
  console.log("blockers=" + blockers.map(item => item.phase + ":" + item.status).join(","));
}

if (payload.status === "blocked") process.exit(2);
if (!payload.status || payload.status === "unknown") process.exit(3);
NODE
