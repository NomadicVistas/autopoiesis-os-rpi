#!/usr/bin/env bash
set -euo pipefail

LOCAL_URL="${AUTOPOIESIS_LOCAL_URL:-http://127.0.0.1:3030}"
EVENTS_URL="${LOCAL_URL%/}/local/events/export?limit=${AUTOPOIESIS_EVENTS_EXPORT_LIMIT:-25}"
TMP_JSON="$(mktemp)"

cleanup() {
  rm -f "$TMP_JSON"
}
trap cleanup EXIT

curl -fsS "$EVENTS_URL" >"$TMP_JSON"

node - "$TMP_JSON" <<'NODE'
const fs = require("fs");
const payload = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const events = Array.isArray(payload.events) ? payload.events : null;
const counts = payload.counts || {};
const cursor = payload.cursor || {};
const allowedSources = new Set(["command_audit", "display_delivery", "release_history"]);
const serialized = JSON.stringify(payload);
function fail(message) {
  console.error("events export check failed: " + message);
  process.exit(2);
}
if (!payload.ok || payload.kind !== "autopoiesis_frame_event_export") fail("unexpected payload kind");
if (payload.schemaVersion !== 1) fail("unexpected schema version");
if (payload.redacted !== true) fail("payload is not marked redacted");
if (!payload.device || !payload.device.deviceId) fail("missing device id");
if (!events) fail("events is not an array");
if (!Number.isFinite(Number(counts.exported))) fail("missing exported count");
if (Number(counts.exported) !== events.length) fail("exported count does not match events length");
if (serialized.includes("deviceApiKey") || serialized.includes("device_api_key")) fail("device API key field leaked");
let previousObservedAt = Number.POSITIVE_INFINITY;
const keys = new Set();
for (const event of events) {
  if (!event || typeof event !== "object") fail("event entry is not an object");
  if (!allowedSources.has(event.source)) fail("unsupported source " + String(event.source));
  if (!event.eventKey || typeof event.eventKey !== "string") fail("event missing stable eventKey");
  if (!event.observedAt || Number.isNaN(Date.parse(event.observedAt))) fail("event has invalid observedAt");
  const observedAt = Date.parse(event.observedAt);
  if (observedAt > previousObservedAt) fail("events are not newest-first");
  previousObservedAt = observedAt;
  if (keys.has(event.eventKey)) fail("duplicate eventKey " + event.eventKey);
  keys.add(event.eventKey);
}
if (events.length) {
  if (cursor.latestObservedAt !== events[0].observedAt) fail("cursor latestObservedAt does not match newest event");
  if (cursor.latestEventKey !== events[0].eventKey) fail("cursor latestEventKey does not match newest event");
}
console.log([
  "Autopoiesis Frame events export",
  "device=" + payload.device.deviceId,
  "exported=" + events.length,
  "commandAudit=" + (counts.commandAudit || 0),
  "deliveryLog=" + (counts.deliveryLog || 0),
  "releaseHistory=" + (counts.releaseHistory || 0),
  "latest=" + (cursor.latestEventKey || "none")
].join(" "));
NODE
