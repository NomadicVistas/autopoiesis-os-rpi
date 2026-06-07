#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQUIRE_ALL=0
REQUIRED_LIST="${AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE:-}"
MANIFEST_SOURCE="${AUTOPOIESIS_HOSTED_CONTRACT_MANIFEST:-${AUTOPOIESIS_HOSTED_CONTRACT_BUNDLE:-}}"
MANIFEST_FILE=""
MANIFEST_BASE=""
MANIFEST_REQUIRE_ALL=0
MANIFEST_REQUIRED_LIST=""
TMP_FILES=()
RAN_COUNT=0
SKIPPED=()
PASSED=()

cleanup() {
  if [[ "${#TMP_FILES[@]}" -gt 0 ]]; then
    rm -f "${TMP_FILES[@]}"
  fi
}
trap cleanup EXIT

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/hosted-contract-suite-check.sh [--strict]

Environment:
  AUTOPOIESIS_HOSTED_CONTRACT_MANIFEST      optional JSON manifest mapping gates to sources
  AUTOPOIESIS_HOSTED_CONTRACT_BUNDLE        alias for AUTOPOIESIS_HOSTED_CONTRACT_MANIFEST
  AUTOPOIESIS_HOSTED_CONTRACT_MANIFEST_TOKEN optional bearer token for manifest URL fetches
  AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE       comma-separated required gates
                                            migrations,schema,pairing,device-auth,settings,profile-ownership,heartbeat,command-poll,command-ack,stream,cache,online-admin,broadcast,release,release-rollout
  AUTOPOIESIS_AOS_MIGRATION_CONTRACT_SOURCE migration directory or manifest
  AUTOPOIESIS_AOS_SCHEMA_CONTRACT_SOURCE    schema JSON or SQLite database
  AUTOPOIESIS_PAIRING_CONTRACT_SOURCE       pairing lifecycle bundle file or URL
  AUTOPOIESIS_DEVICE_AUTH_CONTRACT_SOURCE   device route auth bundle file or URL
  AUTOPOIESIS_SETTINGS_CONTRACT_SOURCE      settings conflict bundle file or URL
  AUTOPOIESIS_PROFILE_OWNERSHIP_CONTRACT_SOURCE Profile account ownership bundle file or URL
  AUTOPOIESIS_HEARTBEAT_CONTRACT_SOURCE     heartbeat bundle/response file or URL
  AUTOPOIESIS_COMMAND_POLL_CONTRACT_SOURCE  command polling lifecycle bundle file or URL
  AUTOPOIESIS_COMMAND_ACK_CONTRACT_SOURCE   command acknowledgement lifecycle bundle file or URL
  AUTOPOIESIS_STREAM_CONTRACT_SOURCE        stream response file or URL
  AUTOPOIESIS_CACHE_CONTRACT_SOURCE         cache/offline bundle file or URL
  AUTOPOIESIS_ONLINE_ADMIN_CONTRACT_SOURCE  Profile/Admin bundle file or URL
  AUTOPOIESIS_BROADCAST_CONTRACT_SOURCE     broadcast lifecycle bundle file or URL
  AUTOPOIESIS_RELEASE_MANIFEST_SOURCE       release manifest file or URL
  AUTOPOIESIS_RELEASE_ROLLOUT_CONTRACT_SOURCE release rollout bundle file or URL

--strict requires every hosted gate source. Otherwise the suite runs all
provided sources and fails if a gate named in AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE
is missing.

When AUTOPOIESIS_HOSTED_CONTRACT_MANIFEST is set, the suite reads sources and
optional requirements from a JSON object such as
{"require":["pairing","stream"],"sources":{"pairing":"pairing.json","stream":"stream.json"}}.
Set {"strict":true} or {"requireAll":true} in the manifest to require every
hosted gate. Relative file paths are resolved from the manifest directory.
Per-gate source environment variables override manifest entries.

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
    stream|stream-contract|stream_contract) echo "stream" ;;
    cache|offline-cache|offline_cache|cache-contract|cache_contract) echo "cache" ;;
    admin|online-admin|online_admin|online-admin-contract|online_admin_contract) echo "online-admin" ;;
    broadcast|broadcasts|broadcast-contract|broadcast_contract) echo "broadcast" ;;
    release|release-manifest|release_manifest) echo "release" ;;
    release-rollout|release_rollout|rollout|release-rollout-contract|release_rollout_contract) echo "release-rollout" ;;
    *) echo "$1" ;;
  esac
}

required_gate_csv() {
  if [[ "$REQUIRE_ALL" == "1" || "$MANIFEST_REQUIRE_ALL" == "1" ]]; then
    echo "migrations,schema,pairing,device-auth,settings,profile-ownership,heartbeat,command-poll,command-ack,stream,cache,online-admin,broadcast,release,release-rollout"
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

source_value() {
  local env_name="$1"
  local gate="$2"
  local env_value
  env_value="${!env_name:-}"
  if [[ -n "$env_value" ]]; then
    printf '%s' "$env_value"
    return 0
  fi
  manifest_source_value "$gate"
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
      echo "hosted contract suite failed: could not fetch manifest URL" >&2
      exit 1
    }
    MANIFEST_BASE="$MANIFEST_SOURCE"
  else
    [[ -f "$MANIFEST_SOURCE" ]] || {
      echo "hosted contract suite failed: manifest file not found: $MANIFEST_SOURCE" >&2
      exit 1
    }
    MANIFEST_FILE="$MANIFEST_SOURCE"
    MANIFEST_BASE="$(cd "$(dirname "$MANIFEST_SOURCE")" && pwd)"
  fi

  node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$MANIFEST_FILE" || {
    echo "hosted contract suite failed: manifest is not valid JSON: $MANIFEST_SOURCE" >&2
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

process.stdout.write(strict + "\n" + normalized.join(","));
NODE
)" || {
    echo "hosted contract suite failed: manifest requirements are invalid: $MANIFEST_SOURCE" >&2
    exit 1
  }
  MANIFEST_REQUIRE_ALL="$(printf '%s\n' "$manifest_requirements" | sed -n '1p')"
  MANIFEST_REQUIRED_LIST="$(printf '%s\n' "$manifest_requirements" | sed -n '2p')"
}

run_gate() {
  local gate="$1"
  local env_name="$2"
  local script="$3"
  local label="$4"
  local source
  source="$(source_value "$env_name" "$gate")"

  if [[ -z "$source" ]]; then
    if gate_is_required "$gate"; then
      echo "hosted contract suite failed: required $gate source is missing ($env_name)" >&2
      exit 1
    fi
    SKIPPED+=("$gate")
    return 0
  fi

  echo
  echo "==> $label"
  "$SCRIPT_DIR/$script" "$source"
  PASSED+=("$gate")
  RAN_COUNT=$((RAN_COUNT + 1))
}

for arg in "$@"; do
  case "$arg" in
    --strict|--require-all)
      REQUIRE_ALL=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      echo "unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

load_manifest

run_gate "migrations" "AUTOPOIESIS_AOS_MIGRATION_CONTRACT_SOURCE" "aos-migration-contract-check.sh" "AOS migration contract"
run_gate "schema" "AUTOPOIESIS_AOS_SCHEMA_CONTRACT_SOURCE" "aos-schema-contract-check.sh" "AOS schema contract"
run_gate "pairing" "AUTOPOIESIS_PAIRING_CONTRACT_SOURCE" "pairing-contract-check.sh" "Hosted pairing contract"
run_gate "device-auth" "AUTOPOIESIS_DEVICE_AUTH_CONTRACT_SOURCE" "device-auth-contract-check.sh" "Hosted device auth contract"
run_gate "settings" "AUTOPOIESIS_SETTINGS_CONTRACT_SOURCE" "settings-contract-check.sh" "Hosted settings conflict contract"
run_gate "profile-ownership" "AUTOPOIESIS_PROFILE_OWNERSHIP_CONTRACT_SOURCE" "profile-ownership-contract-check.sh" "Hosted profile ownership contract"
run_gate "heartbeat" "AUTOPOIESIS_HEARTBEAT_CONTRACT_SOURCE" "heartbeat-contract-check.sh" "Hosted heartbeat contract"
run_gate "command-poll" "AUTOPOIESIS_COMMAND_POLL_CONTRACT_SOURCE" "command-poll-contract-check.sh" "Hosted command polling contract"
run_gate "command-ack" "AUTOPOIESIS_COMMAND_ACK_CONTRACT_SOURCE" "command-ack-contract-check.sh" "Hosted command acknowledgement contract"
run_gate "stream" "AUTOPOIESIS_STREAM_CONTRACT_SOURCE" "stream-contract-check.sh" "Hosted stream contract"
run_gate "cache" "AUTOPOIESIS_CACHE_CONTRACT_SOURCE" "cache-contract-check.sh" "Hosted cache/offline contract"
run_gate "online-admin" "AUTOPOIESIS_ONLINE_ADMIN_CONTRACT_SOURCE" "online-admin-contract-check.sh" "Hosted Profile/Admin contract"
run_gate "broadcast" "AUTOPOIESIS_BROADCAST_CONTRACT_SOURCE" "broadcast-contract-check.sh" "Hosted broadcast contract"
run_gate "release" "AUTOPOIESIS_RELEASE_MANIFEST_SOURCE" "release-manifest-check.sh" "Release manifest contract"
run_gate "release-rollout" "AUTOPOIESIS_RELEASE_ROLLOUT_CONTRACT_SOURCE" "release-rollout-contract-check.sh" "Hosted release rollout contract"

if [[ "$RAN_COUNT" -eq 0 ]]; then
  usage
  echo "hosted contract suite failed: no contract sources were provided" >&2
  exit 2
fi

echo
echo "hosted contract suite ok: passed=${PASSED[*]} skipped=${SKIPPED[*]:-none}"
