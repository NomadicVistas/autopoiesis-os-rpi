#!/usr/bin/env bash
set -euo pipefail

LOCAL_URL="${AUTOPOIESIS_LOCAL_URL:-http://127.0.0.1:3030}"
READINESS_URL="${LOCAL_URL%/}/local/readiness"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CURL_BIN="${AUTOPOIESIS_CURL_BIN:-curl}"
DIAGNOSTICS_BIN="${AUTOPOIESIS_DIAGNOSTICS_BIN:-$ROOT_DIR/scripts/diagnostics.sh}"
TMP_JSON="$(mktemp)"
JSON=0

cleanup() {
  rm -f "$TMP_JSON"
}
trap cleanup EXIT

for arg in "$@"; do
  case "$arg" in
    --json) JSON=1 ;;
    -h|--help)
      cat <<'HELP'
Usage: readiness-check.sh [--json]

Checks /local/readiness first. If the local UI endpoint is unavailable, falls
back to diagnostics.sh and maps the result into a readiness summary.
HELP
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

emit_payload() {
  local payload="$1"
  if [[ "$JSON" == "1" ]]; then
    printf '%s\n' "$payload"
    return
  fi
  node - "$payload" <<'NODE'
const payload = JSON.parse(process.argv[2]);
const phaseSummary = Object.entries(payload.phases || {})
  .map(([name, value]) => name + "=" + String(value || "unknown"))
  .join(" ");
console.log([
  "Autopoiesis Frame readiness",
  "source=" + (payload.source || "unknown"),
  "status=" + (payload.status || "unknown"),
  "health=" + (payload.healthStatus || "unknown"),
  "device=" + (payload.deviceId || "unknown"),
  payload.diagnostics ? "diagnostics=" + payload.diagnostics : "",
  phaseSummary
].filter(Boolean).join(" "));
if (Array.isArray(payload.blockers) && payload.blockers.length > 0) {
  console.log("blockers=" + payload.blockers.map(item => item.phase + ":" + item.status).join(","));
}
if (Array.isArray(payload.warnings) && payload.warnings.length > 0) {
  console.log("warnings=" + payload.warnings.map(item => item.name + ":" + item.status).join(","));
}
NODE
}

map_local_payload() {
  node - "$TMP_JSON" <<'NODE'
const fs = require("fs");
const payload = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const mapped = {
  source: "local-ui",
  status: payload.status || "unknown",
  healthStatus: payload.healthStatus || "unknown",
  deviceId: (payload.device || {}).deviceId || "unknown",
  phases: Object.fromEntries(Object.entries(payload.phases || {}).map(([name, value]) => [name, value && value.status ? value.status : "unknown"])),
  blockers: Array.isArray(payload.blockers) ? payload.blockers.map(item => ({
    phase: item.phase || "unknown",
    status: item.status || "unknown"
  })) : [],
  warnings: []
};
process.stdout.write(JSON.stringify(mapped));
NODE
}

map_diagnostics_payload() {
  local diag_json="$1"
  node - "$diag_json" <<'NODE'
const payload = JSON.parse(process.argv[2]);
const results = Array.isArray(payload.results) ? payload.results : [];
const warnings = results
  .filter(item => item && item.status === "warn")
  .map(item => ({ name: item.name || "warning", status: "warn" }));
const blockers = results
  .filter(item => item && item.status === "fail")
  .map(item => ({ phase: item.name || "unknown", status: "fail" }));
const failCount = Number((((payload.checks || {}).fail) ?? 0));
const warnCount = Number((((payload.checks || {}).warn) ?? 0));
let status = "unknown";
if (failCount > 0 || String(((payload.appliance || {}).targetStatus) || "").toLowerCase() === "failed") {
  status = "blocked";
} else if (warnCount > 0 || payload.network?.online === false) {
  status = "degraded";
} else if (String(((payload.appliance || {}).targetStatus) || "").toLowerCase() === "active") {
  status = "ready";
}
const mapped = {
  source: "diagnostics",
  diagnostics: "available",
  status,
  healthStatus: failCount > 0 ? "error" : warnCount > 0 ? "warning" : "healthy",
  deviceId: (payload.device || {}).id || "unknown",
  network: {
    online: payload.network?.online === true
  },
  phases: {
    setup: status === "blocked" ? "blocked" : status === "degraded" ? "degraded" : "ready"
  },
  blockers,
  warnings
};
process.stdout.write(JSON.stringify(mapped));
NODE
}

if "$CURL_BIN" -fsS "$READINESS_URL" >"$TMP_JSON"; then
  PAYLOAD="$(map_local_payload)"
  emit_payload "$PAYLOAD"
  STATUS="$(node -e 'const p=JSON.parse(process.argv[1]); process.stdout.write(p.status || "unknown")' "$PAYLOAD")"
  if [[ "$STATUS" == "blocked" ]]; then
    exit 2
  fi
  if [[ "$STATUS" == "unknown" || -z "$STATUS" ]]; then
    exit 3
  fi
  exit 0
fi

if [[ ! -x "$DIAGNOSTICS_BIN" ]]; then
  PAYLOAD='{"source":"diagnostics","diagnostics":"missing","status":"unknown","healthStatus":"unknown","deviceId":"unknown","phases":{},"blockers":[],"warnings":[]}'
  emit_payload "$PAYLOAD"
  exit 3
fi

DIAG_RC=0
DIAG_OUT="$("$DIAGNOSTICS_BIN" --json 2>/dev/null)" || DIAG_RC=$?
PAYLOAD="$(map_diagnostics_payload "$DIAG_OUT")"
emit_payload "$PAYLOAD"
STATUS="$(node -e 'const p=JSON.parse(process.argv[1]); process.stdout.write(p.status || "unknown")' "$PAYLOAD")"
if [[ "$STATUS" == "blocked" ]]; then
  exit 2
fi
if [[ "$STATUS" == "unknown" || -z "$STATUS" ]]; then
  exit 3
fi
exit 0
