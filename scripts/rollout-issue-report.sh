#!/usr/bin/env bash
set -euo pipefail

LOCAL_URL="${AUTOPOIESIS_LOCAL_URL:-http://127.0.0.1:3030}"
PROFILE="${AUTOPOIESIS_ROLLOUT_PROFILE:-staged}"
STRICT_CONTENT="${AUTOPOIESIS_ROLLOUT_STRICT_CONTENT:-0}"
SERVICES="${AUTOPOIESIS_ROLLOUT_REPORT_SERVICES:-0}"
EVENT_LIMIT="${AUTOPOIESIS_ROLLOUT_REPORT_EVENT_LIMIT:-25}"
OUTPUT_PATH="${AUTOPOIESIS_ROLLOUT_REPORT_PATH:-${1:-}}"
ACCEPTANCE_URL="${LOCAL_URL%/}/local/rollout/acceptance?profile=${PROFILE}&strictContent=${STRICT_CONTENT}&services=${SERVICES}&eventLimit=${EVENT_LIMIT}"
SUPPORT_URL="${LOCAL_URL%/}/local/support-bundle?services=${SERVICES}&auditLimit=25&deliveryLimit=25&releaseLimit=25&eventLimit=${EVENT_LIMIT}"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

curl -fsS "$ACCEPTANCE_URL" >"$TMP_DIR/acceptance.json"
curl -fsS "$SUPPORT_URL" >"$TMP_DIR/support-bundle.json"

node - "$TMP_DIR/acceptance.json" "$TMP_DIR/support-bundle.json" "$PROFILE" "$STRICT_CONTENT" "$SERVICES" "$LOCAL_URL" >"$TMP_DIR/report.md" <<'NODE'
const fs = require("fs");

const acceptance = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const support = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const profile = process.argv[4] || "staged";
const strictContent = process.argv[5] || "0";
const services = process.argv[6] || "0";
const localUrl = process.argv[7] || "http://127.0.0.1:3030";

function fail(message) {
  console.error("rollout issue report failed: " + message);
  process.exit(3);
}

if (acceptance.kind !== "autopoiesis_frame_rollout_acceptance" || acceptance.redacted !== true) {
  fail("unexpected or unredacted rollout acceptance payload");
}
if (support.kind !== "autopoiesis_frame_support_bundle" || support.redacted !== true) {
  fail("unexpected or unredacted support bundle payload");
}

const serialized = JSON.stringify({ acceptance, support });
if (serialized.includes("deviceApiKey") || serialized.includes("device_api_key")) {
  fail("device API key field leaked into report inputs");
}

function text(value, fallback = "unknown") {
  if (value === undefined || value === null || value === "") return fallback;
  return String(value);
}

function listItems(items, emptyText) {
  if (!Array.isArray(items) || items.length === 0) return ["- " + emptyText];
  return items.map(item => {
    const id = item.id || item.phase || item.code || "unknown";
    const label = item.label || item.summary || item.message || item.status || "No summary provided.";
    const status = item.status ? " [" + item.status + "]" : "";
    return "- " + id + status + ": " + label;
  });
}

const device = acceptance.device || support.device || {};
const summary = support.summary || {};
const supportEvents = support.deviceEvents || {};
const supportReadiness = support.readiness || {};
const supportHealth = support.health || {};
const issueCodes = Array.isArray(summary.issueCodes) && summary.issueCodes.length
  ? summary.issueCodes.join(", ")
  : "none";
const readinessBlockers = Array.isArray(supportReadiness.blockers) ? supportReadiness.blockers.length : 0;
const healthIssues = Array.isArray(supportHealth.issues) ? supportHealth.issues.length : 0;
const generatedAt = new Date().toISOString();

const lines = [];
lines.push("# Autopoiesis Frame rollout issue report");
lines.push("");
lines.push("Generated: " + generatedAt);
lines.push("");
lines.push("## Summary");
lines.push("");
lines.push("- Device: " + text(device.deviceName) + " (" + text(device.deviceId) + ")");
lines.push("- Software version: " + text(device.softwareVersion));
lines.push("- Profile: " + text(acceptance.profile || profile));
lines.push("- Acceptance status: " + text(acceptance.status));
lines.push("- Health status: " + text(acceptance.healthStatus || summary.healthStatus));
lines.push("- Readiness status: " + text(acceptance.readinessStatus || summary.readinessStatus));
lines.push("- Strict content: " + (strictContent === "1" ? "yes" : "no"));
lines.push("- Services checked: " + (services === "1" ? "yes" : "no"));
lines.push("- Issue codes: " + issueCodes);
lines.push("");
lines.push("## Acceptance blockers");
lines.push("");
lines.push(...listItems(acceptance.blockers, "No required rollout blockers reported."));
lines.push("");
lines.push("## Acceptance warnings");
lines.push("");
lines.push(...listItems(acceptance.warnings, "No rollout warnings reported."));
lines.push("");
lines.push("## Support evidence");
lines.push("");
lines.push("- Pending commands: " + text(summary.pendingCommands, "0"));
lines.push("- Offline playable items: " + text(summary.offlinePlayableItems, "0"));
lines.push("- Exported device events: " + text((supportEvents.counts || {}).exported, "0"));
lines.push("- Readiness blockers in support bundle: " + readinessBlockers);
lines.push("- Health issues in support bundle: " + healthIssues);
lines.push("- Input status: " + text((summary.input || {}).status));
lines.push("- Timer status: " + text((summary.timers || {}).status));
lines.push("- Release status: " + text((summary.releaseHistory || {}).lastStatus, "none"));
lines.push("");
lines.push("## Recommended next action");
lines.push("");
if (Array.isArray(acceptance.blockers) && acceptance.blockers.length) {
  const first = acceptance.blockers[0];
  lines.push("Resolve '" + text(first.id || first.phase, "first_blocker") + "' first: " + text(first.summary || first.label || first.message, "No blocker summary provided."));
} else if (Array.isArray(acceptance.warnings) && acceptance.warnings.length) {
  const first = acceptance.warnings[0];
  lines.push("Review '" + text(first.id || first.phase, "first_warning") + "' before promotion: " + text(first.summary || first.label || first.message, "No warning summary provided."));
} else {
  lines.push("No rollout blocker was reported. If this is a physical validation issue, attach the generated support bundle and the exact hardware model.");
}
lines.push("");
lines.push("## Reproduction commands");
lines.push("");
lines.push("~~~bash");
lines.push("AUTOPOIESIS_LOCAL_URL=" + localUrl + " AUTOPOIESIS_ROLLOUT_PROFILE=" + profile + " AUTOPOIESIS_ROLLOUT_STRICT_CONTENT=" + strictContent + " ./scripts/rollout-acceptance-check.sh");
lines.push("AUTOPOIESIS_LOCAL_URL=" + localUrl + " ./scripts/support-bundle.sh ./support-bundle.json");
lines.push("AUTOPOIESIS_LOCAL_URL=" + localUrl + " AUTOPOIESIS_ROLLOUT_PROFILE=" + profile + " ./scripts/rollout-issue-report.sh ./rollout-issue.md");
lines.push("~~~");
lines.push("");
lines.push("## Notes");
lines.push("");
lines.push("- This report is generated from redacted local endpoints only.");
lines.push("- It intentionally omits stored device API keys, raw command payloads, local cache paths, release artifact URLs, and checksums.");
lines.push("- For hardware-only failures, attach /proc/bus/input/devices, relevant systemctl state, and the support bundle if they do not expose secrets.");

console.log(lines.join("\n"));
NODE

if [[ -n "$OUTPUT_PATH" ]]; then
  mkdir -p "$(dirname "$OUTPUT_PATH")"
  cp "$TMP_DIR/report.md" "$OUTPUT_PATH"
  echo "report=$OUTPUT_PATH"
else
  cat "$TMP_DIR/report.md"
fi
