#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQUIRE_ALL=0
PLAN_ONLY=0
LIST_GATES=0
MANIFEST_TEMPLATE=0
REQUIRED_LIST="${AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE:-}"
MANIFEST_SOURCE="${AUTOPOIESIS_HOSTED_CONTRACT_MANIFEST:-${AUTOPOIESIS_HOSTED_CONTRACT_BUNDLE:-}}"
MANIFEST_FILE=""
MANIFEST_BASE=""
MANIFEST_REQUIRE_ALL=0
MANIFEST_REQUIRED_LIST=""
MANIFEST_REQUIRE_DEPENDENCIES=0
REQUIRE_DEPENDENCIES="${AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE_DEPENDENCIES:-0}"
REPORT_PATH="${AUTOPOIESIS_HOSTED_CONTRACT_REPORT:-}"
TMP_FILES=()
RAN_COUNT=0
SKIPPED=()
PASSED=()
PLANNED=()
REPORT_ROWS=()
DEPENDENCY_BLOCKERS=()
declare -A SOURCE_BY_GATE=()
FAILED_GATE=""
FAILURE_REASON=""

cleanup() {
  if [[ "${#TMP_FILES[@]}" -gt 0 ]]; then
    rm -f "${TMP_FILES[@]}"
  fi
}

write_report() {
  local exit_code="$1"
  if [[ "$LIST_GATES" == "1" || "$MANIFEST_TEMPLATE" == "1" ]]; then
    return 0
  fi
  if [[ -z "$REPORT_PATH" ]]; then
    return 0
  fi

  local report_dir
  report_dir="$(dirname "$REPORT_PATH")"
  mkdir -p "$report_dir"

  local rows required_csv passed_csv skipped_csv planned_csv
  rows="$(printf '%s\n' "${REPORT_ROWS[@]}")"
  required_csv="$(normalized_required_gate_csv)"
  passed_csv="$(printf '%s,' "${PASSED[@]}")"
  skipped_csv="$(printf '%s,' "${SKIPPED[@]}")"
  planned_csv="$(printf '%s,' "${PLANNED[@]}")"

  REPORT_ROWS_CONTENT="$rows" \
  REPORT_REQUIRED_CSV="$required_csv" \
  REPORT_PASSED_CSV="$passed_csv" \
  REPORT_SKIPPED_CSV="$skipped_csv" \
  REPORT_PLANNED_CSV="$planned_csv" \
  REPORT_DEPENDENCY_BLOCKERS="$(printf '%s\n' "${DEPENDENCY_BLOCKERS[@]}")" \
  REPORT_EXIT_CODE="$exit_code" \
  REPORT_RAN_COUNT="$RAN_COUNT" \
  REPORT_FAILURE_REASON="$FAILURE_REASON" \
  REPORT_FAILED_GATE="$FAILED_GATE" \
  REPORT_MANIFEST_SOURCE_PROVIDED="$([[ -n "$MANIFEST_SOURCE" ]] && echo 1 || echo 0)" \
  REPORT_MANIFEST_REQUIRE_ALL="$MANIFEST_REQUIRE_ALL" \
  REPORT_MANIFEST_REQUIRE_DEPENDENCIES="$MANIFEST_REQUIRE_DEPENDENCIES" \
  REPORT_CLI_REQUIRE_ALL="$REQUIRE_ALL" \
  REPORT_CLI_REQUIRE_DEPENDENCIES="$REQUIRE_DEPENDENCIES" \
  REPORT_PLAN_ONLY="$PLAN_ONLY" \
  node - "$REPORT_PATH" <<'NODE'
const fs = require("fs");

const reportPath = process.argv[2];
const exitCode = Number(process.env.REPORT_EXIT_CODE || "0");
const required = new Set(
  String(process.env.REPORT_REQUIRED_CSV || "")
    .split(",")
    .map(entry => entry.trim())
    .filter(Boolean)
);
const rows = String(process.env.REPORT_ROWS_CONTENT || "")
  .split("\n")
  .filter(Boolean)
  .map(row => {
    const [gate, status, requiredFlag, sourceProvided, envName, ...labelParts] = row.split("|");
    return {
      gate,
      status,
      required: requiredFlag === "1" || required.has(gate),
      sourceProvided: sourceProvided === "1",
      sourceEnv: envName,
      label: labelParts.join("|")
    };
  });

const passed = String(process.env.REPORT_PASSED_CSV || "")
  .split(",")
  .map(entry => entry.trim())
  .filter(Boolean);
const skipped = String(process.env.REPORT_SKIPPED_CSV || "")
  .split(",")
  .map(entry => entry.trim())
  .filter(Boolean);
const planned = String(process.env.REPORT_PLANNED_CSV || "")
  .split(",")
  .map(entry => entry.trim())
  .filter(Boolean);
const failedGate = process.env.REPORT_FAILED_GATE || "";
const failureReason = process.env.REPORT_FAILURE_REASON || "";
const dependencyBlockers = String(process.env.REPORT_DEPENDENCY_BLOCKERS || "")
  .split("\n")
  .filter(Boolean)
  .map(row => {
    const [gate, dependency] = row.split("|");
    return { gate, dependency };
  });

const report = {
  schemaVersion: 1,
  suite: "hosted-contract-suite",
  generatedAt: new Date().toISOString(),
  status: exitCode === 0 ? "passed" : "failed",
  exitCode,
  manifest: {
    provided: process.env.REPORT_MANIFEST_SOURCE_PROVIDED === "1",
    requireAll: process.env.REPORT_MANIFEST_REQUIRE_ALL === "1",
    requireDependencies: process.env.REPORT_MANIFEST_REQUIRE_DEPENDENCIES === "1"
  },
  cli: {
    requireAll: process.env.REPORT_CLI_REQUIRE_ALL === "1",
    requireDependencies: process.env.REPORT_CLI_REQUIRE_DEPENDENCIES === "1"
  },
  mode: process.env.REPORT_PLAN_ONLY === "1" ? "plan" : "run",
  requiredGates: Array.from(required),
  summary: {
    ran: Number(process.env.REPORT_RAN_COUNT || "0"),
    planned: planned.length,
    passed: passed.length,
    skipped: skipped.length,
    failed: exitCode === 0 ? 0 : 1,
    dependencyBlockers: dependencyBlockers.length
  },
  gates: rows,
  dependencyBlockers,
  planned,
  passed,
  skipped
};

if (failedGate) report.failedGate = failedGate;
if (failureReason) report.failureReason = failureReason;

fs.writeFileSync(reportPath, JSON.stringify(report, null, 2) + "\n");
NODE
}

on_exit() {
  local exit_code="$?"
  write_report "$exit_code"
  cleanup
}
trap on_exit EXIT

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/hosted-contract-suite-check.sh [--strict] [--require-dependencies] [--plan]
  scripts/hosted-contract-suite-check.sh --list-gates
  scripts/hosted-contract-suite-check.sh --manifest-template

Environment:
  AUTOPOIESIS_HOSTED_CONTRACT_MANIFEST      optional JSON manifest mapping gates to sources
  AUTOPOIESIS_HOSTED_CONTRACT_BUNDLE        alias for AUTOPOIESIS_HOSTED_CONTRACT_MANIFEST
  AUTOPOIESIS_HOSTED_CONTRACT_MANIFEST_TOKEN optional bearer token for manifest URL fetches
  AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE       comma-separated required gates
                                            migrations,schema,pairing,device-auth,settings,profile-ownership,heartbeat,command-poll,command-ack,command-state,stream,cache,online-admin,broadcast,release,release-rollout
  AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE_DEPENDENCIES
                                            when 1, required downstream gates must also have prerequisite sources or requirements
  AUTOPOIESIS_HOSTED_CONTRACT_REPORT        optional JSON report output path
  AUTOPOIESIS_AOS_MIGRATION_CONTRACT_SOURCE migration directory or manifest
  AUTOPOIESIS_AOS_SCHEMA_CONTRACT_SOURCE    schema JSON or SQLite database
  AUTOPOIESIS_PAIRING_CONTRACT_SOURCE       pairing lifecycle bundle file or URL
  AUTOPOIESIS_DEVICE_AUTH_CONTRACT_SOURCE   device route auth bundle file or URL
  AUTOPOIESIS_SETTINGS_CONTRACT_SOURCE      settings conflict bundle file or URL
  AUTOPOIESIS_PROFILE_OWNERSHIP_CONTRACT_SOURCE Profile account ownership bundle file or URL
  AUTOPOIESIS_HEARTBEAT_CONTRACT_SOURCE     heartbeat bundle/response file or URL
  AUTOPOIESIS_COMMAND_POLL_CONTRACT_SOURCE  command polling lifecycle bundle file or URL
  AUTOPOIESIS_COMMAND_ACK_CONTRACT_SOURCE   command acknowledgement lifecycle bundle file or URL
  AUTOPOIESIS_COMMAND_STATE_CONTRACT_SOURCE command outbox state bundle file or URL
  AUTOPOIESIS_STREAM_CONTRACT_SOURCE        stream response file or URL
  AUTOPOIESIS_CACHE_CONTRACT_SOURCE         cache/offline bundle file or URL
  AUTOPOIESIS_ONLINE_ADMIN_CONTRACT_SOURCE  Profile/Admin bundle file or URL
  AUTOPOIESIS_BROADCAST_CONTRACT_SOURCE     broadcast lifecycle bundle file or URL
  AUTOPOIESIS_RELEASE_MANIFEST_SOURCE       release manifest file or URL
  AUTOPOIESIS_RELEASE_ROLLOUT_CONTRACT_SOURCE release rollout bundle file or URL

--strict requires every hosted gate source. Otherwise the suite runs all
provided sources and fails if a gate named in AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE
is missing.

--plan validates manifest and required-gate configuration, then prints a
redacted gate/source matrix without running the individual contract checkers.
Required gates still fail when their source is missing. This is useful for CI
and rollout annotations before fetching live fixtures or mutating staging state.

--require-dependencies makes required downstream gates prove that their
prerequisite gate sources are also present or required. Manifests can set
`requireDependencies: true` or `require_dependencies: true` for the same
behavior. Without this option, dependency blockers are reported but remain
advisory so narrow owner-specific CI jobs can still run one contract fixture.

--list-gates prints the hosted gate catalog as JSON and exits without loading a
manifest or running contract checkers. CI can use this to generate manifest
templates, validate staging artifact coverage, or annotate rollout jobs without
scraping README text.

--manifest-template prints a disabled JSON manifest skeleton generated from the
same hosted gate catalog and exits without loading an existing manifest or
running contract checkers. CI can fill the source fields it owns, enable those
gates, and then run --plan or the full suite against the generated manifest.

When AUTOPOIESIS_HOSTED_CONTRACT_MANIFEST is set, the suite reads sources and
optional requirements from a JSON object such as
{"require":["pairing","stream"],"sources":{"pairing":"pairing.json","stream":"stream.json"}}.
Set {"strict":true} or {"requireAll":true} in the manifest to require every
hosted gate. Relative file paths are resolved from the manifest directory.
Per-gate source environment variables override manifest entries.
When AUTOPOIESIS_HOSTED_CONTRACT_REPORT is set, the suite writes a redacted JSON
summary with gate names, pass/skip status, required gates, and source-presence
booleans. Raw source paths and URLs are not stored in the report.

Token and strictness environment variables for the individual gates are passed
through unchanged, for example AUTOPOIESIS_STREAM_CONTRACT_TOKEN or
AUTOPOIESIS_RELEASE_REQUIRE_ARTIFACT.
EOF
}

normalize_gate_name() {
  case "$1" in
    migration|migrations|aos-migration|aos_migration) echo "migrations" ;;
    schema|aos-schema|aos_schema) echo "schema" ;;
    pairing|pairing-contract|pairing_contract) echo "pairing" ;;
    device-auth|device_auth|auth|device-auth-contract|device_auth_contract) echo "device-auth" ;;
    settings|settings-sync|settings_sync|settings-contract|settings_contract) echo "settings" ;;
    profile-ownership|profile_ownership|ownership|profile-auth|profile_auth|account-ownership|account_ownership) echo "profile-ownership" ;;
    heartbeat|heartbeat-contract|heartbeat_contract|event-ingestion|event_ingestion) echo "heartbeat" ;;
    command-poll|command_poll|commands|command-queue|command_queue|poll|polling|command-poll-contract|command_poll_contract) echo "command-poll" ;;
    command-ack|command_ack|commands-ack|commands_ack|ack|acknowledgement|acknowledgment|command-ack-contract|command_ack_contract) echo "command-ack" ;;
    command-state|command_state|commands-state|commands_state|command-lifecycle|command_lifecycle|outbox|command-outbox|command_outbox|command-state-contract|command_state_contract) echo "command-state" ;;
    stream|stream-contract|stream_contract) echo "stream" ;;
    cache|offline-cache|offline_cache|cache-contract|cache_contract) echo "cache" ;;
    admin|online-admin|online_admin|online-admin-contract|online_admin_contract) echo "online-admin" ;;
    broadcast|broadcasts|broadcast-contract|broadcast_contract) echo "broadcast" ;;
    release|release-manifest|release_manifest) echo "release" ;;
    release-rollout|release_rollout|rollout|release-rollout-contract|release_rollout_contract) echo "release-rollout" ;;
    *) echo "$1" ;;
  esac
}

for_each_gate() {
  cat <<'EOF'
migrations|AUTOPOIESIS_AOS_MIGRATION_CONTRACT_SOURCE|aos-migration-contract-check.sh|AOS migration contract
schema|AUTOPOIESIS_AOS_SCHEMA_CONTRACT_SOURCE|aos-schema-contract-check.sh|AOS schema contract
pairing|AUTOPOIESIS_PAIRING_CONTRACT_SOURCE|pairing-contract-check.sh|Hosted pairing contract
device-auth|AUTOPOIESIS_DEVICE_AUTH_CONTRACT_SOURCE|device-auth-contract-check.sh|Hosted device auth contract
settings|AUTOPOIESIS_SETTINGS_CONTRACT_SOURCE|settings-contract-check.sh|Hosted settings conflict contract
profile-ownership|AUTOPOIESIS_PROFILE_OWNERSHIP_CONTRACT_SOURCE|profile-ownership-contract-check.sh|Hosted profile ownership contract
heartbeat|AUTOPOIESIS_HEARTBEAT_CONTRACT_SOURCE|heartbeat-contract-check.sh|Hosted heartbeat contract
command-poll|AUTOPOIESIS_COMMAND_POLL_CONTRACT_SOURCE|command-poll-contract-check.sh|Hosted command polling contract
command-ack|AUTOPOIESIS_COMMAND_ACK_CONTRACT_SOURCE|command-ack-contract-check.sh|Hosted command acknowledgement contract
command-state|AUTOPOIESIS_COMMAND_STATE_CONTRACT_SOURCE|command-state-contract-check.sh|Hosted command state contract
stream|AUTOPOIESIS_STREAM_CONTRACT_SOURCE|stream-contract-check.sh|Hosted stream contract
cache|AUTOPOIESIS_CACHE_CONTRACT_SOURCE|cache-contract-check.sh|Hosted cache/offline contract
online-admin|AUTOPOIESIS_ONLINE_ADMIN_CONTRACT_SOURCE|online-admin-contract-check.sh|Hosted Profile/Admin contract
broadcast|AUTOPOIESIS_BROADCAST_CONTRACT_SOURCE|broadcast-contract-check.sh|Hosted broadcast contract
release|AUTOPOIESIS_RELEASE_MANIFEST_SOURCE|release-manifest-check.sh|Release manifest contract
release-rollout|AUTOPOIESIS_RELEASE_ROLLOUT_CONTRACT_SOURCE|release-rollout-contract-check.sh|Hosted release rollout contract
EOF
}

for_each_gate_dependency() {
  cat <<'EOF'
schema|migrations
pairing|schema
device-auth|pairing
settings|device-auth
profile-ownership|settings
heartbeat|profile-ownership
command-poll|heartbeat
command-ack|command-poll
command-state|command-ack
stream|heartbeat
cache|stream
online-admin|cache,command-state
broadcast|online-admin
release-rollout|release,online-admin
EOF
}

all_gate_csv() {
  local gate env_name script label output
  output=""
  while IFS='|' read -r gate env_name script label; do
    [[ -n "$gate" ]] || continue
    if [[ -n "$output" ]]; then
      output="$output,$gate"
    else
      output="$gate"
    fi
  done < <(for_each_gate)
  echo "$output"
}

print_gate_catalog() {
  GATE_CATALOG_ROWS="$(for_each_gate)" GATE_DEPENDENCY_ROWS="$(for_each_gate_dependency)" node - <<'NODE'
const dependencyMap = new Map(
  String(process.env.GATE_DEPENDENCY_ROWS || "")
    .split("\n")
    .filter(Boolean)
    .map(line => {
      const [gate, dependencies = ""] = line.split("|");
      return [gate, dependencies.split(",").map(entry => entry.trim()).filter(Boolean)];
    })
);

const gates = String(process.env.GATE_CATALOG_ROWS || "")
  .split("\n")
  .filter(Boolean)
  .map((line, index) => {
    const [gate, sourceEnv, checker, ...labelParts] = line.split("|");
    return {
      gate,
      order: index + 1,
      sourceEnv,
      checker,
      label: labelParts.join("|"),
      dependencies: dependencyMap.get(gate) || []
    };
  });

process.stdout.write(JSON.stringify({
  schemaVersion: 1,
  suite: "hosted-contract-suite",
  gates
}, null, 2) + "\n");
NODE
}

print_manifest_template() {
  GATE_CATALOG_ROWS="$(for_each_gate)" GATE_DEPENDENCY_ROWS="$(for_each_gate_dependency)" node - <<'NODE'
const dependencyMap = new Map(
  String(process.env.GATE_DEPENDENCY_ROWS || "")
    .split("\n")
    .filter(Boolean)
    .map(line => {
      const [gate, dependencies = ""] = line.split("|");
      return [gate, dependencies.split(",").map(entry => entry.trim()).filter(Boolean)];
    })
);

const gates = String(process.env.GATE_CATALOG_ROWS || "")
  .split("\n")
  .filter(Boolean)
  .map((line, index) => {
    const [gate, sourceEnv, checker, ...labelParts] = line.split("|");
    return {
      gate,
      order: index + 1,
      sourceEnv,
      checker,
      label: labelParts.join("|")
    };
  });

const sources = {};
for (const gate of gates) {
  sources[gate.gate] = {
    enabled: false,
    source: "",
    sourceEnv: gate.sourceEnv,
    checker: gate.checker,
    label: gate.label,
    dependencies: dependencyMap.get(gate.gate) || []
  };
}

process.stdout.write(JSON.stringify({
  schemaVersion: 1,
  suite: "hosted-contract-suite",
  strict: false,
  require: [],
  sources
}, null, 2) + "\n");
NODE
}

gate_exists() {
  local gate="$1"
  case ",$(all_gate_csv)," in
    *",$gate,"*) return 0 ;;
    *) return 1 ;;
  esac
}

required_gate_csv() {
  if [[ "$REQUIRE_ALL" == "1" || "$MANIFEST_REQUIRE_ALL" == "1" ]]; then
    all_gate_csv
  else
    local required_csv="$REQUIRED_LIST"
    if [[ -n "$MANIFEST_REQUIRED_LIST" ]]; then
      if [[ -n "$required_csv" ]]; then
        required_csv="$required_csv,$MANIFEST_REQUIRED_LIST"
      else
        required_csv="$MANIFEST_REQUIRED_LIST"
      fi
    fi
    echo "$required_csv"
  fi
}

normalized_required_gate_csv() {
  local required_csv entry normalized output
  required_csv="$(required_gate_csv)"
  output=""
  [[ -n "$required_csv" ]] || return 0

  IFS="," read -ra entries <<<"$required_csv"
  for entry in "${entries[@]}"; do
    entry="${entry//[[:space:]]/}"
    [[ -n "$entry" ]] || continue
    normalized="$(normalize_gate_name "$entry")"
    case ",$output," in
      *",$normalized,"*) ;;
      *)
        if [[ -n "$output" ]]; then
          output="$output,$normalized"
        else
          output="$normalized"
        fi
        ;;
    esac
  done
  echo "$output"
}

validate_required_gates() {
  local required_csv entry normalized
  required_csv="$(required_gate_csv)"
  [[ -n "$required_csv" ]] || return 0

  IFS="," read -ra entries <<<"$required_csv"
  for entry in "${entries[@]}"; do
    entry="${entry//[[:space:]]/}"
    [[ -n "$entry" ]] || continue
    normalized="$(normalize_gate_name "$entry")"
    if ! gate_exists "$normalized"; then
      FAILED_GATE="$entry"
      FAILURE_REASON="unknown required gate"
      echo "hosted contract suite failed: unknown required gate: $entry" >&2
      exit 2
    fi
  done
}

gate_is_required() {
  local gate="$1"
  local required_csv
  required_csv="$(required_gate_csv)"
  [[ -n "$required_csv" ]] || return 1

  local entry normalized
  IFS=',' read -ra entries <<<"$required_csv"
  for entry in "${entries[@]}"; do
    entry="${entry//[[:space:]]/}"
    [[ -n "$entry" ]] || continue
    normalized="$(normalize_gate_name "$entry")"
    if [[ "$normalized" == "$gate" ]]; then
      return 0
    fi
  done
  return 1
}

gate_dependencies_csv() {
  local target_gate="$1"
  local gate dependencies
  while IFS='|' read -r gate dependencies; do
    [[ "$gate" == "$target_gate" ]] || continue
    echo "$dependencies"
    return 0
  done < <(for_each_gate_dependency)
  echo ""
}

gate_source_present() {
  local target_gate="$1"
  local gate env_name script label
  while IFS='|' read -r gate env_name script label; do
    [[ "$gate" == "$target_gate" ]] || continue
    if [[ -n "$(source_value "$env_name" "$gate")" ]]; then
      return 0
    fi
    return 1
  done < <(for_each_gate)
  return 1
}

add_dependency_blocker() {
  local gate="$1"
  local dependency="$2"
  local blocker="$gate|$dependency"
  local existing
  for existing in "${DEPENDENCY_BLOCKERS[@]}"; do
    [[ "$existing" == "$blocker" ]] && return 0
  done
  DEPENDENCY_BLOCKERS+=("$blocker")
}

collect_gate_dependency_blockers() {
  local root_gate="$1"
  local current_gate="$2"
  local seen_csv="${3:-}"
  local dependencies dependency
  dependencies="$(gate_dependencies_csv "$current_gate")"
  [[ -n "$dependencies" ]] || return 0

  IFS=',' read -ra dependency_entries <<<"$dependencies"
  for dependency in "${dependency_entries[@]}"; do
    dependency="${dependency//[[:space:]]/}"
    [[ -n "$dependency" ]] || continue
    case ",$seen_csv," in
      *",$dependency,"*) continue ;;
    esac
    if ! gate_is_required "$dependency" && ! gate_source_present "$dependency"; then
      add_dependency_blocker "$root_gate" "$dependency"
    fi
    collect_gate_dependency_blockers "$root_gate" "$dependency" "$seen_csv,$dependency"
  done
}

collect_dependency_blockers() {
  DEPENDENCY_BLOCKERS=()
  local required_csv entry gate
  required_csv="$(normalized_required_gate_csv)"
  [[ -n "$required_csv" ]] || return 0

  IFS=',' read -ra required_entries <<<"$required_csv"
  for entry in "${required_entries[@]}"; do
    gate="${entry//[[:space:]]/}"
    [[ -n "$gate" ]] || continue
    collect_gate_dependency_blockers "$gate" "$gate" "$gate"
  done
}

dependency_enforcement_enabled() {
  [[ "$REQUIRE_DEPENDENCIES" == "1" || "$REQUIRE_DEPENDENCIES" == "true" || "$REQUIRE_DEPENDENCIES" == "yes" || "$MANIFEST_REQUIRE_DEPENDENCIES" == "1" ]]
}

source_value() {
  local env_name="$1"
  local gate="$2"
  local env_value
  if [[ -n "${SOURCE_BY_GATE[$gate]+set}" ]]; then
    printf '%s' "${SOURCE_BY_GATE[$gate]}"
    return 0
  fi
  env_value="${!env_name:-}"
  if [[ -n "$env_value" ]]; then
    printf '%s' "$env_value"
    return 0
  fi
  manifest_source_value "$gate"
}

resolve_gate_sources() {
  local gate resolved_source
  while IFS=$'\t' read -r gate resolved_source; do
    [[ -n "$gate" ]] || continue
    SOURCE_BY_GATE["$gate"]="$resolved_source"
  done < <(GATE_CATALOG_ROWS="$(for_each_gate)" RESOLVE_MANIFEST_FILE="$MANIFEST_FILE" RESOLVE_MANIFEST_BASE="$MANIFEST_BASE" node - <<'NODE'
const fs = require("fs");
const path = require("path");

const manifestFile = process.env.RESOLVE_MANIFEST_FILE || "";
const base = process.env.RESOLVE_MANIFEST_BASE || "";
const manifest = manifestFile ? JSON.parse(fs.readFileSync(manifestFile, "utf8")) : {};
const gates = String(process.env.GATE_CATALOG_ROWS || "")
  .split("\n")
  .filter(Boolean)
  .map(line => {
    const [gate, sourceEnv] = line.split("|");
    return { gate, sourceEnv };
  });

function normalize(value) {
  switch (String(value || "")) {
    case "migration":
    case "migrations":
    case "aos-migration":
    case "aos_migration":
      return "migrations";
    case "schema":
    case "aos-schema":
    case "aos_schema":
      return "schema";
    case "pairing":
    case "pairing-contract":
    case "pairing_contract":
      return "pairing";
    case "device-auth":
    case "device_auth":
    case "auth":
    case "device-auth-contract":
    case "device_auth_contract":
      return "device-auth";
    case "settings":
    case "settings-sync":
    case "settings_sync":
    case "settings-contract":
    case "settings_contract":
      return "settings";
    case "profile-ownership":
    case "profile_ownership":
    case "ownership":
    case "profile-auth":
    case "profile_auth":
    case "account-ownership":
    case "account_ownership":
      return "profile-ownership";
    case "heartbeat":
    case "heartbeat-contract":
    case "heartbeat_contract":
    case "event-ingestion":
    case "event_ingestion":
      return "heartbeat";
    case "command-poll":
    case "command_poll":
    case "commands":
    case "command-queue":
    case "command_queue":
    case "poll":
    case "polling":
    case "command-poll-contract":
    case "command_poll_contract":
      return "command-poll";
    case "command-ack":
    case "command_ack":
    case "commands-ack":
    case "commands_ack":
    case "ack":
    case "acknowledgement":
    case "acknowledgment":
    case "command-ack-contract":
    case "command_ack_contract":
      return "command-ack";
    case "command-state":
    case "command_state":
    case "commands-state":
    case "commands_state":
    case "command-lifecycle":
    case "command_lifecycle":
    case "outbox":
    case "command-outbox":
    case "command_outbox":
    case "command-state-contract":
    case "command_state_contract":
      return "command-state";
    case "stream":
    case "stream-contract":
    case "stream_contract":
      return "stream";
    case "cache":
    case "offline-cache":
    case "offline_cache":
    case "cache-contract":
    case "cache_contract":
      return "cache";
    case "admin":
    case "online-admin":
    case "online_admin":
    case "online-admin-contract":
    case "online_admin_contract":
      return "online-admin";
    case "broadcast":
    case "broadcasts":
    case "broadcast-contract":
    case "broadcast_contract":
      return "broadcast";
    case "release":
    case "release-manifest":
    case "release_manifest":
      return "release";
    case "release-rollout":
    case "release_rollout":
    case "rollout":
    case "release-rollout-contract":
    case "release_rollout_contract":
      return "release-rollout";
    default:
      return String(value || "");
  }
}

function sourceFrom(entry) {
  if (entry === false || entry === null || entry === undefined) return "";
  if (typeof entry === "string") return entry;
  if (typeof entry !== "object" || Array.isArray(entry)) return "";
  if (entry.enabled === false) return "";
  return entry.source || entry.path || entry.file || entry.url || "";
}

function resolveSource(source) {
  if (!source || typeof source !== "string") return "";
  if (/^https?:\/\//i.test(source) || path.isAbsolute(source)) return source;
  if (/^https?:\/\//i.test(base)) return new URL(source, base).toString();
  return path.resolve(base || process.cwd(), source);
}

function manifestSource(gate) {
  const containers = [
    manifest.sources,
    manifest.contracts,
    manifest.gates,
    manifest.contractSources,
    manifest
  ].filter(value => value && typeof value === "object" && !Array.isArray(value));

  for (const container of containers) {
    for (const [key, entry] of Object.entries(container)) {
      if (normalize(key) !== gate) continue;
      const source = sourceFrom(entry);
      return source ? resolveSource(source) : "";
    }
  }
  return "";
}

for (const gate of gates) {
  const envSource = process.env[gate.sourceEnv] || "";
  const source = envSource || manifestSource(gate.gate);
  process.stdout.write(gate.gate + "\t" + source + "\n");
}
NODE
)
}

manifest_source_value() {
  local gate="$1"
  if [[ -z "$MANIFEST_FILE" ]]; then
    return 0
  fi

  node - "$MANIFEST_FILE" "$MANIFEST_BASE" "$gate" <<'NODE'
const fs = require("fs");
const path = require("path");

const file = process.argv[2];
const base = process.argv[3] || "";
const gate = process.argv[4];

function normalize(value) {
  switch (String(value || "")) {
    case "migration":
    case "migrations":
    case "aos-migration":
    case "aos_migration":
      return "migrations";
    case "schema":
    case "aos-schema":
    case "aos_schema":
      return "schema";
    case "pairing":
    case "pairing-contract":
    case "pairing_contract":
      return "pairing";
    case "device-auth":
    case "device_auth":
    case "auth":
    case "device-auth-contract":
    case "device_auth_contract":
      return "device-auth";
    case "settings":
    case "settings-sync":
    case "settings_sync":
    case "settings-contract":
    case "settings_contract":
      return "settings";
    case "profile-ownership":
    case "profile_ownership":
    case "ownership":
    case "profile-auth":
    case "profile_auth":
    case "account-ownership":
    case "account_ownership":
      return "profile-ownership";
    case "heartbeat":
    case "heartbeat-contract":
    case "heartbeat_contract":
    case "event-ingestion":
    case "event_ingestion":
      return "heartbeat";
    case "command-poll":
    case "command_poll":
    case "commands":
    case "command-queue":
    case "command_queue":
    case "poll":
    case "polling":
    case "command-poll-contract":
    case "command_poll_contract":
      return "command-poll";
    case "command-ack":
    case "command_ack":
    case "commands-ack":
    case "commands_ack":
    case "ack":
    case "acknowledgement":
    case "acknowledgment":
    case "command-ack-contract":
    case "command_ack_contract":
      return "command-ack";
    case "command-state":
    case "command_state":
    case "commands-state":
    case "commands_state":
    case "command-lifecycle":
    case "command_lifecycle":
    case "outbox":
    case "command-outbox":
    case "command_outbox":
    case "command-state-contract":
    case "command_state_contract":
      return "command-state";
    case "stream":
    case "stream-contract":
    case "stream_contract":
      return "stream";
    case "cache":
    case "offline-cache":
    case "offline_cache":
    case "cache-contract":
    case "cache_contract":
      return "cache";
    case "admin":
    case "online-admin":
    case "online_admin":
    case "online-admin-contract":
    case "online_admin_contract":
      return "online-admin";
    case "broadcast":
    case "broadcasts":
    case "broadcast-contract":
    case "broadcast_contract":
      return "broadcast";
    case "release":
    case "release-manifest":
    case "release_manifest":
      return "release";
    case "release-rollout":
    case "release_rollout":
    case "rollout":
    case "release-rollout-contract":
    case "release_rollout_contract":
      return "release-rollout";
    default:
      return String(value || "");
  }
}

function sourceFrom(entry) {
  if (entry === false || entry === null || entry === undefined) return "";
  if (typeof entry === "string") return entry;
  if (typeof entry !== "object" || Array.isArray(entry)) return "";
  if (entry.enabled === false) return "";
  return entry.source || entry.path || entry.file || entry.url || "";
}

function resolveSource(source) {
  if (!source || typeof source !== "string") return "";
  if (/^https?:\/\//i.test(source) || path.isAbsolute(source)) return source;
  if (/^https?:\/\//i.test(base)) return new URL(source, base).toString();
  return path.resolve(base || process.cwd(), source);
}

const manifest = JSON.parse(fs.readFileSync(file, "utf8"));
const containers = [
  manifest.sources,
  manifest.contracts,
  manifest.gates,
  manifest.contractSources,
  manifest
].filter(value => value && typeof value === "object" && !Array.isArray(value));

for (const container of containers) {
  for (const [key, entry] of Object.entries(container)) {
    if (normalize(key) !== gate) continue;
    const source = sourceFrom(entry);
    if (source) process.stdout.write(resolveSource(source));
    process.exit(0);
  }
}
NODE
}

load_manifest() {
  if [[ -z "$MANIFEST_SOURCE" ]]; then
    return 0
  fi

  if [[ "$MANIFEST_SOURCE" =~ ^https?:// ]]; then
    MANIFEST_FILE="$(mktemp)"
    TMP_FILES+=("$MANIFEST_FILE")
    local curl_args=(-fsS)
    if [[ -n "${AUTOPOIESIS_HOSTED_CONTRACT_MANIFEST_TOKEN:-}" ]]; then
      curl_args+=(-H "Authorization: Bearer ${AUTOPOIESIS_HOSTED_CONTRACT_MANIFEST_TOKEN}")
    fi
    curl "${curl_args[@]}" "$MANIFEST_SOURCE" >"$MANIFEST_FILE" || {
      FAILURE_REASON="could not fetch manifest URL"
      echo "hosted contract suite failed: could not fetch manifest URL" >&2
      exit 1
    }
    MANIFEST_BASE="$MANIFEST_SOURCE"
  else
    [[ -f "$MANIFEST_SOURCE" ]] || {
      FAILURE_REASON="manifest file not found"
      echo "hosted contract suite failed: manifest file not found: $MANIFEST_SOURCE" >&2
      exit 1
    }
    MANIFEST_FILE="$MANIFEST_SOURCE"
    MANIFEST_BASE="$(cd "$(dirname "$MANIFEST_SOURCE")" && pwd)"
  fi

  node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$MANIFEST_FILE" || {
    FAILURE_REASON="manifest is not valid JSON"
    echo "hosted contract suite failed: manifest is not valid JSON: $MANIFEST_SOURCE" >&2
    exit 1
  }

  node - "$MANIFEST_FILE" <<'NODE' || {
const fs = require("fs");

process.on("uncaughtException", error => {
  console.error(error.message);
  process.exit(1);
});

const file = process.argv[2];
const allGates = new Set([
  "migrations",
  "schema",
  "pairing",
  "device-auth",
  "settings",
  "profile-ownership",
  "heartbeat",
  "command-poll",
  "command-ack",
  "command-state",
  "stream",
  "cache",
  "online-admin",
  "broadcast",
  "release",
  "release-rollout"
]);
const aliases = new Map([
  ["migration", "migrations"],
  ["migrations", "migrations"],
  ["aos-migration", "migrations"],
  ["aos_migration", "migrations"],
  ["schema", "schema"],
  ["aos-schema", "schema"],
  ["aos_schema", "schema"],
  ["pairing", "pairing"],
  ["pairing-contract", "pairing"],
  ["pairing_contract", "pairing"],
  ["device-auth", "device-auth"],
  ["device_auth", "device-auth"],
  ["auth", "device-auth"],
  ["device-auth-contract", "device-auth"],
  ["device_auth_contract", "device-auth"],
  ["settings", "settings"],
  ["settings-sync", "settings"],
  ["settings_sync", "settings"],
  ["settings-contract", "settings"],
  ["settings_contract", "settings"],
  ["profile-ownership", "profile-ownership"],
  ["profile_ownership", "profile-ownership"],
  ["ownership", "profile-ownership"],
  ["profile-auth", "profile-ownership"],
  ["profile_auth", "profile-ownership"],
  ["account-ownership", "profile-ownership"],
  ["account_ownership", "profile-ownership"],
  ["heartbeat", "heartbeat"],
  ["heartbeat-contract", "heartbeat"],
  ["heartbeat_contract", "heartbeat"],
  ["event-ingestion", "heartbeat"],
  ["event_ingestion", "heartbeat"],
  ["command-poll", "command-poll"],
  ["command_poll", "command-poll"],
  ["commands", "command-poll"],
  ["command-queue", "command-poll"],
  ["command_queue", "command-poll"],
  ["poll", "command-poll"],
  ["polling", "command-poll"],
  ["command-poll-contract", "command-poll"],
  ["command_poll_contract", "command-poll"],
  ["command-ack", "command-ack"],
  ["command_ack", "command-ack"],
  ["commands-ack", "command-ack"],
  ["commands_ack", "command-ack"],
  ["ack", "command-ack"],
  ["acknowledgement", "command-ack"],
  ["acknowledgment", "command-ack"],
  ["command-ack-contract", "command-ack"],
  ["command_ack_contract", "command-ack"],
  ["command-state", "command-state"],
  ["command_state", "command-state"],
  ["commands-state", "command-state"],
  ["commands_state", "command-state"],
  ["command-lifecycle", "command-state"],
  ["command_lifecycle", "command-state"],
  ["outbox", "command-state"],
  ["command-outbox", "command-state"],
  ["command_outbox", "command-state"],
  ["command-state-contract", "command-state"],
  ["command_state_contract", "command-state"],
  ["stream", "stream"],
  ["stream-contract", "stream"],
  ["stream_contract", "stream"],
  ["cache", "cache"],
  ["offline-cache", "cache"],
  ["offline_cache", "cache"],
  ["cache-contract", "cache"],
  ["cache_contract", "cache"],
  ["admin", "online-admin"],
  ["online-admin", "online-admin"],
  ["online_admin", "online-admin"],
  ["online-admin-contract", "online-admin"],
  ["online_admin_contract", "online-admin"],
  ["broadcast", "broadcast"],
  ["broadcasts", "broadcast"],
  ["broadcast-contract", "broadcast"],
  ["broadcast_contract", "broadcast"],
  ["release", "release"],
  ["release-manifest", "release"],
  ["release_manifest", "release"],
  ["release-rollout", "release-rollout"],
  ["release_rollout", "release-rollout"],
  ["rollout", "release-rollout"],
  ["release-rollout-contract", "release-rollout"],
  ["release_rollout_contract", "release-rollout"]
]);

function normalize(value) {
  return aliases.get(String(value || "")) || String(value || "");
}

function sourceValue(entry) {
  if (entry === false || entry === null || entry === undefined) return "";
  if (typeof entry === "string") return entry;
  if (typeof entry !== "object" || Array.isArray(entry)) return "";
  if (entry.enabled === false) return "";
  return entry.source || entry.path || entry.file || entry.url || "";
}

function validateSourceEntry(containerName, key, entry) {
  const gate = normalize(key);
  if (!allGates.has(gate)) {
    throw new Error(`unknown source gate in manifest ${containerName}: ${key}`);
  }
  if (entry === false || entry === null || entry === undefined) return;
  if (typeof entry === "string") {
    if (!entry.trim()) throw new Error(`empty source for manifest gate ${gate}`);
    return;
  }
  if (typeof entry !== "object" || Array.isArray(entry)) {
    throw new Error(`invalid source entry for manifest gate ${gate}`);
  }
  if (entry.enabled === false) return;
  if (!String(sourceValue(entry) || "").trim()) {
    throw new Error(`enabled manifest gate ${gate} is missing source, path, file, or url`);
  }
}

const manifest = JSON.parse(fs.readFileSync(file, "utf8"));
for (const containerName of ["sources", "contracts", "gates", "contractSources"]) {
  const container = manifest[containerName];
  if (container === undefined || container === null) continue;
  if (typeof container !== "object" || Array.isArray(container)) {
    throw new Error(`manifest ${containerName} must be an object keyed by gate name`);
  }
  for (const [key, entry] of Object.entries(container)) {
    validateSourceEntry(containerName, key, entry);
  }
}
for (const [key, entry] of Object.entries(manifest)) {
  if (allGates.has(normalize(key))) validateSourceEntry("top-level", key, entry);
}
NODE
    FAILURE_REASON="manifest sources are invalid"
    echo "hosted contract suite failed: manifest sources are invalid: $MANIFEST_SOURCE" >&2
    exit 1
  }

  local manifest_requirements
  manifest_requirements="$(node - "$MANIFEST_FILE" <<'NODE'
const fs = require("fs");

const file = process.argv[2];
const allGates = new Set([
  "migrations",
  "schema",
  "pairing",
  "device-auth",
  "settings",
  "profile-ownership",
  "heartbeat",
  "command-poll",
  "command-ack",
  "command-state",
  "stream",
  "cache",
  "online-admin",
  "broadcast",
  "release",
  "release-rollout"
]);

function normalize(value) {
  switch (String(value || "")) {
    case "migration":
    case "migrations":
    case "aos-migration":
    case "aos_migration":
      return "migrations";
    case "schema":
    case "aos-schema":
    case "aos_schema":
      return "schema";
    case "pairing":
    case "pairing-contract":
    case "pairing_contract":
      return "pairing";
    case "device-auth":
    case "device_auth":
    case "auth":
    case "device-auth-contract":
    case "device_auth_contract":
      return "device-auth";
    case "settings":
    case "settings-sync":
    case "settings_sync":
    case "settings-contract":
    case "settings_contract":
      return "settings";
    case "profile-ownership":
    case "profile_ownership":
    case "ownership":
    case "profile-auth":
    case "profile_auth":
    case "account-ownership":
    case "account_ownership":
      return "profile-ownership";
    case "heartbeat":
    case "heartbeat-contract":
    case "heartbeat_contract":
    case "event-ingestion":
    case "event_ingestion":
      return "heartbeat";
    case "command-poll":
    case "command_poll":
    case "commands":
    case "command-queue":
    case "command_queue":
    case "poll":
    case "polling":
    case "command-poll-contract":
    case "command_poll_contract":
      return "command-poll";
    case "command-ack":
    case "command_ack":
    case "commands-ack":
    case "commands_ack":
    case "ack":
    case "acknowledgement":
    case "acknowledgment":
    case "command-ack-contract":
    case "command_ack_contract":
      return "command-ack";
    case "command-state":
    case "command_state":
    case "commands-state":
    case "commands_state":
    case "command-lifecycle":
    case "command_lifecycle":
    case "outbox":
    case "command-outbox":
    case "command_outbox":
    case "command-state-contract":
    case "command_state_contract":
      return "command-state";
    case "stream":
    case "stream-contract":
    case "stream_contract":
      return "stream";
    case "cache":
    case "offline-cache":
    case "offline_cache":
    case "cache-contract":
    case "cache_contract":
      return "cache";
    case "admin":
    case "online-admin":
    case "online_admin":
    case "online-admin-contract":
    case "online_admin_contract":
      return "online-admin";
    case "broadcast":
    case "broadcasts":
    case "broadcast-contract":
    case "broadcast_contract":
      return "broadcast";
    case "release":
    case "release-manifest":
    case "release_manifest":
      return "release";
    case "release-rollout":
    case "release_rollout":
    case "rollout":
    case "release-rollout-contract":
    case "release_rollout_contract":
      return "release-rollout";
    default:
      return String(value || "");
  }
}

function requirementEntries(value) {
  if (value === undefined || value === null || value === false) return [];
  if (typeof value === "string") return value.split(",").map(entry => entry.trim()).filter(Boolean);
  if (Array.isArray(value)) return value;
  if (typeof value === "object") {
    return Object.entries(value)
      .filter(([, enabled]) => enabled !== false && enabled !== null && enabled !== undefined)
      .map(([key]) => key);
  }
  return [];
}

const manifest = JSON.parse(fs.readFileSync(file, "utf8"));
const strict = manifest.strict === true || manifest.requireAll === true || manifest.require_all === true ? "1" : "0";
const requireDependencies = manifest.requireDependencies === true || manifest.require_dependencies === true ? "1" : "0";
const rawEntries = [
  ...requirementEntries(manifest.require),
  ...requirementEntries(manifest.required),
  ...requirementEntries(manifest.requireGates),
  ...requirementEntries(manifest.requiredGates),
  ...requirementEntries(manifest.required_gates)
];
const normalized = [];
for (const entry of rawEntries) {
  const gate = normalize(entry);
  if (!allGates.has(gate)) {
    console.error("unknown required gate in manifest: " + entry);
    process.exit(1);
  }
  if (!normalized.includes(gate)) normalized.push(gate);
}

process.stdout.write(strict + "\n" + normalized.join(",") + "\n" + requireDependencies);
NODE
)" || {
    FAILURE_REASON="manifest requirements are invalid"
    echo "hosted contract suite failed: manifest requirements are invalid: $MANIFEST_SOURCE" >&2
    exit 1
  }
  MANIFEST_REQUIRE_ALL="$(printf '%s\n' "$manifest_requirements" | sed -n '1p')"
  MANIFEST_REQUIRED_LIST="$(printf '%s\n' "$manifest_requirements" | sed -n '2p')"
  MANIFEST_REQUIRE_DEPENDENCIES="$(printf '%s\n' "$manifest_requirements" | sed -n '3p')"
}

run_gate() {
  local gate="$1"
  local env_name="$2"
  local script="$3"
  local label="$4"
  local source required_flag source_present
  source="$(source_value "$env_name" "$gate")"
  required_flag=0
  if gate_is_required "$gate"; then
    required_flag=1
  fi

  if [[ -z "$source" ]]; then
    if [[ "$required_flag" == "1" ]]; then
      REPORT_ROWS+=("$gate|missing-required|$required_flag|0|$env_name|$label")
      FAILED_GATE="$gate"
      FAILURE_REASON="required source is missing"
      echo "hosted contract suite failed: required $gate source is missing ($env_name)" >&2
      exit 1
    fi
    REPORT_ROWS+=("$gate|skipped|$required_flag|0|$env_name|$label")
    SKIPPED+=("$gate")
    return 0
  fi

  source_present=1
  if [[ "$PLAN_ONLY" == "1" ]]; then
    REPORT_ROWS+=("$gate|planned|$required_flag|$source_present|$env_name|$label")
    PLANNED+=("$gate")
    echo "plan: $gate source present ($env_name)"
    return 0
  fi

  echo
  echo "==> $label"
  if ! "$SCRIPT_DIR/$script" "$source"; then
    REPORT_ROWS+=("$gate|failed|$required_flag|$source_present|$env_name|$label")
    FAILED_GATE="$gate"
    FAILURE_REASON="$label failed"
    exit 1
  fi
  REPORT_ROWS+=("$gate|passed|$required_flag|$source_present|$env_name|$label")
  PASSED+=("$gate")
  RAN_COUNT=$((RAN_COUNT + 1))
}

for arg in "$@"; do
  case "$arg" in
    --strict|--require-all)
      REQUIRE_ALL=1
      ;;
    --require-dependencies|--dependencies)
      REQUIRE_DEPENDENCIES=1
      ;;
    --plan|--dry-run)
      PLAN_ONLY=1
      ;;
    --list-gates|--catalog)
      LIST_GATES=1
      ;;
    --manifest-template|--template)
      MANIFEST_TEMPLATE=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      FAILURE_REASON="unknown argument"
      echo "unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

if [[ "$LIST_GATES" == "1" ]]; then
  print_gate_catalog
  exit 0
fi

if [[ "$MANIFEST_TEMPLATE" == "1" ]]; then
  print_manifest_template
  exit 0
fi

load_manifest
validate_required_gates
resolve_gate_sources
collect_dependency_blockers

if dependency_enforcement_enabled && [[ "${#DEPENDENCY_BLOCKERS[@]}" -gt 0 ]]; then
  local_blockers="$(printf '%s, ' "${DEPENDENCY_BLOCKERS[@]}")"
  FAILURE_REASON="required gate dependencies are missing"
  FAILED_GATE="$(printf '%s' "${DEPENDENCY_BLOCKERS[0]}" | cut -d'|' -f1)"
  echo "hosted contract suite failed: required gate dependencies are missing: ${local_blockers%, }" >&2
  exit 1
fi

while IFS='|' read -r gate env_name script label; do
  [[ -n "$gate" ]] || continue
  run_gate "$gate" "$env_name" "$script" "$label"
done < <(for_each_gate)

if [[ "$PLAN_ONLY" == "1" ]]; then
  echo
  echo "hosted contract suite plan ok: planned=${PLANNED[*]:-none} skipped=${SKIPPED[*]:-none}"
  exit 0
fi

if [[ "$RAN_COUNT" -eq 0 ]]; then
  usage
  FAILURE_REASON="no contract sources were provided"
  echo "hosted contract suite failed: no contract sources were provided" >&2
  exit 2
fi

echo
echo "hosted contract suite ok: passed=${PASSED[*]} skipped=${SKIPPED[*]:-none}"
