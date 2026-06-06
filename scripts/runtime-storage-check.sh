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
const requireReady = process.env.AUTOPOIESIS_REQUIRE_RUNTIME_STORAGE === "1";
const allowUnready = process.env.AUTOPOIESIS_ALLOW_RUNTIME_STORAGE_UNREADY === "1";
const raw = [diagnosticsPayload, health, readiness, support].map(value => JSON.stringify(value)).join("\n");

function fail(message, code = 3) {
  console.error(message);
  process.exit(code);
}

if (/deviceApiKey|device_api_key|apiKey|secret|token/i.test(raw)) {
  fail("Runtime storage surfaces contain sensitive-looking key material.", 4);
}

const diagnostics = diagnosticsPayload.diagnostics || diagnosticsPayload;
if (!diagnostics || typeof diagnostics !== "object") fail("Diagnostics payload is not an object.");
if (!diagnostics.storage || typeof diagnostics.storage !== "object") fail("Diagnostics payload is missing storage.");
const runtime = diagnostics.storage.runtime || null;
if (!runtime || typeof runtime !== "object") fail("Diagnostics storage is missing runtime path checks.");
if (!["ready", "blocked"].includes(runtime.status)) fail("runtime.status has unexpected value: " + runtime.status);
if (typeof runtime.ok !== "boolean") fail("runtime.ok must be a boolean.");

for (const name of ["dataDir", "cacheDir", "logDir"]) {
  const entry = runtime.paths && runtime.paths[name];
  if (!entry || typeof entry !== "object") fail("runtime.paths." + name + " is missing.");
  for (const key of ["exists", "directory", "readable", "writable", "writeProbe", "ok"]) {
    if (typeof entry[key] !== "boolean") fail("runtime.paths." + name + "." + key + " must be a boolean.");
  }
}

if (!health.storage || !health.storage.runtime) fail("/local/health is missing storage.runtime summary.");
if (!readiness.phases || !readiness.phases.storage) fail("/local/readiness is missing storage phase.");
if (!support.summary || !support.summary.storage || !support.summary.storage.runtime) {
  fail("/local/support-bundle is missing summary.storage.runtime.");
}

const issueCodes = ((health.health || {}).issues || []).map(issue => issue.code).filter(Boolean);
if (runtime.ok === false && !issueCodes.includes("runtime_storage_unavailable")) {
  fail("Blocked runtime storage did not produce runtime_storage_unavailable health issue.");
}

if (runtime.ok === false && (requireReady || !allowUnready)) {
  const blocked = Array.isArray(runtime.blocked)
    ? runtime.blocked.map(item => item.name + ":" + (item.error || "not_writable")).join(",")
    : "unknown";
  fail("Runtime storage is not ready: " + blocked, 2);
}

console.log([
  "Autopoiesis Frame runtime storage",
  "status=" + runtime.status,
  "data=" + (runtime.paths.dataDir.ok ? "writable" : "blocked"),
  "cache=" + (runtime.paths.cacheDir.ok ? "writable" : "blocked"),
  "log=" + (runtime.paths.logDir.ok ? "writable" : "blocked"),
  "readiness=" + (readiness.phases.storage.status || "unknown"),
  "issues=" + (issueCodes.length ? issueCodes.join(",") : "none")
].join(" "));
NODE
