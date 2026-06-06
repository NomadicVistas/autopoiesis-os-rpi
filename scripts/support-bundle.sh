#!/usr/bin/env bash
set -euo pipefail

LOCAL_URL="${AUTOPOIESIS_LOCAL_URL:-http://127.0.0.1:3030}"
SUPPORT_URL="${LOCAL_URL%/}/local/support-bundle"
OUTPUT_PATH="${AUTOPOIESIS_SUPPORT_BUNDLE_PATH:-${1:-}}"
TMP_JSON="$(mktemp)"

cleanup() {
  rm -f "$TMP_JSON"
}
trap cleanup EXIT

curl -fsS "$SUPPORT_URL" >"$TMP_JSON"

node - "$TMP_JSON" <<'NODE'
const fs = require("fs");
const payload = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const summary = payload.summary || {};
const device = payload.device || {};
const issues = Array.isArray(summary.issueCodes) && summary.issueCodes.length
  ? summary.issueCodes.join(",")
  : "none";
const blockers = Array.isArray(summary.blockers) && summary.blockers.length
  ? summary.blockers.map(item => item.phase + ":" + item.status).join(",")
  : "none";

console.error([
  "Autopoiesis Frame support bundle",
  "device=" + (device.deviceId || "unknown"),
  "version=" + (device.softwareVersion || "unknown"),
  "health=" + (summary.healthStatus || "unknown"),
  "readiness=" + (summary.readinessStatus || "unknown"),
  "issues=" + issues,
  "blockers=" + blockers,
  "offlinePlayable=" + (summary.offlinePlayableItems || 0)
].join(" "));

if (!payload.ok || payload.kind !== "autopoiesis_frame_support_bundle") process.exit(3);
NODE

if [[ -n "$OUTPUT_PATH" ]]; then
  mkdir -p "$(dirname "$OUTPUT_PATH")"
  cp "$TMP_JSON" "$OUTPUT_PATH"
  echo "bundle=$OUTPUT_PATH"
else
  cat "$TMP_JSON"
fi
