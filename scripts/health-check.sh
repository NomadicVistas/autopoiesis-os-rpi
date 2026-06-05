#!/usr/bin/env bash
set -euo pipefail

LOCAL_URL="${AUTOPOIESIS_LOCAL_URL:-http://127.0.0.1:3030}"
HEALTH_URL="${LOCAL_URL%/}/local/health"
TMP_JSON="$(mktemp)"

cleanup() {
  rm -f "$TMP_JSON"
}
trap cleanup EXIT

curl -fsS "$HEALTH_URL" >"$TMP_JSON"

node - "$TMP_JSON" <<'NODE'
const fs = require("fs");
const payload = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const issueCodes = ((payload.health || {}).issues || []).map(issue => issue.code).filter(Boolean);
const deviceId = (payload.device || {}).deviceId || "unknown";
const version = (payload.device || {}).softwareVersion || "unknown";
const mode = payload.mode || "unknown";
const network = payload.network && payload.network.online ? (payload.network.primary || "online") : "offline";

console.log([
  "Autopoiesis Frame health",
  "status=" + (payload.status || "unknown"),
  "device=" + deviceId,
  "version=" + version,
  "mode=" + mode,
  "network=" + network,
  "issues=" + (issueCodes.length ? issueCodes.join(",") : "none")
].join(" "));

if (payload.status === "error") process.exit(2);
if (!payload.status || payload.status === "unknown") process.exit(3);
NODE
