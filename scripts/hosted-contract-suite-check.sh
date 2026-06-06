#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQUIRE_ALL=0
REQUIRED_LIST="${AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE:-}"
RAN_COUNT=0
SKIPPED=()
PASSED=()

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/hosted-contract-suite-check.sh [--strict]

Environment:
  AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE       comma-separated required gates
                                            migrations,schema,pairing,device-auth,heartbeat,stream,online-admin,release
  AUTOPOIESIS_AOS_MIGRATION_CONTRACT_SOURCE migration directory or manifest
  AUTOPOIESIS_AOS_SCHEMA_CONTRACT_SOURCE    schema JSON or SQLite database
  AUTOPOIESIS_PAIRING_CONTRACT_SOURCE       pairing lifecycle bundle file or URL
  AUTOPOIESIS_DEVICE_AUTH_CONTRACT_SOURCE   device route auth bundle file or URL
  AUTOPOIESIS_HEARTBEAT_CONTRACT_SOURCE     heartbeat bundle/response file or URL
  AUTOPOIESIS_STREAM_CONTRACT_SOURCE        stream response file or URL
  AUTOPOIESIS_ONLINE_ADMIN_CONTRACT_SOURCE  Profile/Admin bundle file or URL
  AUTOPOIESIS_RELEASE_MANIFEST_SOURCE       release manifest file or URL

--strict requires every hosted gate source. Otherwise the suite runs all
provided sources and fails if a gate named in AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE
is missing.

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
    heartbeat|heartbeat-contract|heartbeat_contract|event-ingestion|event_ingestion) echo "heartbeat" ;;
    stream|stream-contract|stream_contract) echo "stream" ;;
    admin|online-admin|online_admin|online-admin-contract|online_admin_contract) echo "online-admin" ;;
    release|release-manifest|release_manifest) echo "release" ;;
    *) echo "$1" ;;
  esac
}

required_gate_csv() {
  if [[ "$REQUIRE_ALL" == "1" ]]; then
    echo "migrations,schema,pairing,device-auth,heartbeat,stream,online-admin,release"
  else
    echo "$REQUIRED_LIST"
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
  printf '%s' "${!env_name:-}"
}

run_gate() {
  local gate="$1"
  local env_name="$2"
  local script="$3"
  local label="$4"
  local source
  source="$(source_value "$env_name")"

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

run_gate "migrations" "AUTOPOIESIS_AOS_MIGRATION_CONTRACT_SOURCE" "aos-migration-contract-check.sh" "AOS migration contract"
run_gate "schema" "AUTOPOIESIS_AOS_SCHEMA_CONTRACT_SOURCE" "aos-schema-contract-check.sh" "AOS schema contract"
run_gate "pairing" "AUTOPOIESIS_PAIRING_CONTRACT_SOURCE" "pairing-contract-check.sh" "Hosted pairing contract"
run_gate "device-auth" "AUTOPOIESIS_DEVICE_AUTH_CONTRACT_SOURCE" "device-auth-contract-check.sh" "Hosted device auth contract"
run_gate "heartbeat" "AUTOPOIESIS_HEARTBEAT_CONTRACT_SOURCE" "heartbeat-contract-check.sh" "Hosted heartbeat contract"
run_gate "stream" "AUTOPOIESIS_STREAM_CONTRACT_SOURCE" "stream-contract-check.sh" "Hosted stream contract"
run_gate "online-admin" "AUTOPOIESIS_ONLINE_ADMIN_CONTRACT_SOURCE" "online-admin-contract-check.sh" "Hosted Profile/Admin contract"
run_gate "release" "AUTOPOIESIS_RELEASE_MANIFEST_SOURCE" "release-manifest-check.sh" "Release manifest contract"

if [[ "$RAN_COUNT" -eq 0 ]]; then
  usage
  echo "hosted contract suite failed: no contract sources were provided" >&2
  exit 2
fi

echo
echo "hosted contract suite ok: passed=${PASSED[*]} skipped=${SKIPPED[*]:-none}"
