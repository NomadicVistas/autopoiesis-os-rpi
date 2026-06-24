#!/usr/bin/env bash
set -euo pipefail

NMCLI_BIN="${AUTOPOIESIS_NMCLI_BIN:-nmcli}"
DEVICE=""
RESCAN=0
REQUIRE_CONNECTED=0
REQUIRE_VISIBLE=0
VERIFY_INTERNET=0
DRY_RUN=0
PLAN_JSON=0
SSID=""
PASSWORD=""
PASSWORD_SUPPLIED=0
PASSWORD_SOURCE="none"

usage() {
  cat >&2 <<'USAGE'
Usage: connect-wifi.sh [--device IFACE] [--rescan] [--require-visible] [--require-connected] [--verify-internet] [--dry-run] [--plan-json] SSID [PASSWORD|-]

Connects the appliance to Wi-Fi through nmcli.
Use PASSWORD=- to read the password from stdin without putting it in the process list.
Use --require-visible to fail before connecting when the SSID is not present in the current scan results.
Use --verify-internet to fail if internet connectivity is not available after connecting.
Use --plan-json to print a redacted, non-mutating connection plan for local UI/support tooling.
USAGE
}

fail_usage() {
  usage
  exit 2
}

resolve_nmcli() {
  if [[ "$NMCLI_BIN" == */* ]]; then
    [[ -x "$NMCLI_BIN" ]] && return 0
  else
    command -v "$NMCLI_BIN" >/dev/null 2>&1 && return 0
  fi

  echo "nmcli is not installed or not executable: $NMCLI_BIN" >&2
  exit 3
}

nmcli_available() {
  if [[ "$NMCLI_BIN" == */* ]]; then
    [[ -x "$NMCLI_BIN" ]] && return 0
  else
    command -v "$NMCLI_BIN" >/dev/null 2>&1 && return 0
  fi
  return 1
}

run_nmcli() {
  "$NMCLI_BIN" "$@"
}

unescape_nmcli_field() {
  local value="$1"
  value="${value//\\:/:}"
  value="${value//\\\\/\\}"
  printf '%s\n' "$value"
}

ssid_visible_in_scan() {
  local scan_output="$1"
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ "$(unescape_nmcli_field "$line")" == "$SSID" ]]; then
      return 0
    fi
  done <<<"$scan_output"
  return 1
}

json_string() {
  node -e 'process.stdout.write(JSON.stringify(process.argv[1] || ""))' -- "$1"
}

json_bool() {
  if [[ "$1" == "1" ]]; then
    printf 'true'
  else
    printf 'false'
  fi
}

emit_json_string_array() {
  local first=1
  local value
  printf '['
  for value in "$@"; do
    if [[ "$first" == "0" ]]; then
      printf ','
    fi
    first=0
    json_string "$value"
  done
  printf ']'
}

emit_plan_json() {
  local available=0
  local connect_plan=(device wifi connect "[ssid]")
  local list_plan=(-t -f SSID device wifi list --rescan no)
  local rescan_plan=(device wifi rescan)
  local status_plan=(-t -f DEVICE,TYPE,STATE,CONNECTION device status)
  local next_actions=()
  local operator_status="ready"
  local operator_severity="info"
  local operator_primary_action="connect_wifi"
  local operator_blocked=0
  local operator_attention=0
  local operator_can_attempt=1
  local operator_completion_gate="nmcli_connect_command_succeeds"

  if nmcli_available; then
    available=1
  else
    next_actions+=("install_or_restore_nmcli")
    operator_status="blocked"
    operator_severity="error"
    operator_primary_action="install_or_restore_nmcli"
    operator_blocked=1
    operator_can_attempt=0
  fi

  if [[ "$PASSWORD_SUPPLIED" -eq 1 ]]; then
    connect_plan+=(password "[redacted]")
  fi
  if [[ -n "$DEVICE" ]]; then
    rescan_plan+=(ifname "$DEVICE")
    list_plan+=(ifname "$DEVICE")
    connect_plan+=(ifname "$DEVICE")
  else
    next_actions+=("select_wifi_device_if_multiple_adapters")
    if [[ "$operator_blocked" -eq 0 ]]; then
      operator_status="attention"
      operator_severity="warning"
      operator_primary_action="connect_wifi_select_device_if_needed"
      operator_attention=1
    fi
  fi
  if [[ "$REQUIRE_VISIBLE" -eq 1 ]]; then
    next_actions+=("scan_before_connect")
    if [[ "$operator_blocked" -eq 0 && "$operator_attention" -eq 0 ]]; then
      operator_primary_action="scan_and_connect"
    fi
  fi
  if [[ "$REQUIRE_CONNECTED" -eq 1 ]]; then
    next_actions+=("verify_connected_state_after_connect")
    operator_completion_gate="wifi_connection_verified"
    if [[ "$operator_blocked" -eq 0 && "$operator_attention" -eq 0 ]]; then
      if [[ "$REQUIRE_VISIBLE" -eq 1 ]]; then
        operator_//primary_action="scan_connect_verify"
      else
        operator_primary_action="connect_and_verify"
      fi
    fi
  fi
  if [[ "$VERIFY_INTERNET" -eq 1 ]]; then
    next_actions+=("verify_internet_connectivity_after_connect")
    if [[ "$operator_blocked" -eq 0 && "$operator_attention" -eq 0 ]]; then
      if [[ "$REQUIRE_CONNECTED" -eq 0 ]]; then
        operator_//primary_action="connect_verify_internet"
      else
        operator_//primary_action="connect_verify_connected_verify_internet"
      fi
    fi
  fi

  printf '{'
  printf '"action":"connect_wifi",'
  printf '"dryRun":true,'
  printf '"redacted":true,'
  printf '"nmcli":{'
  printf '"available":'; json_bool "$available"; printf ','
  printf '"configuredPath":'; json_string "$NMCLI_BIN"
  printf '},'
  printf '"request":{'
  printf '"ssidPresent":'; json_bool "$([[ -n "$SSID" ]] && printf 1 || printf 0)"; printf ','
  printf '"ssidLength":%s,' "${#SSID}"
  printf '"passwordSupplied":'; json_bool "$PASSWORD_SUPPLIED"; printf ','
  printf '"passwordSource":'; json_string "$PASSWORD_SOURCE"; printf ','
  printf '"deviceSpecified":'; json_bool "$([[ -n "$DEVICE" ]] && printf 1 || printf 0)"; printf ','
  printf '"device":'; json_string "$DEVICE"; printf ','
  printf '"rescan":'; json_bool "$RESCAN"; printf ','
  printf '"requireVisible":'; json_bool "$REQUIRE_VISIBLE"; printf ','
  printf '"requireConnected":'; json_bool "$REQUIRE_CONNECTED"
  printf '},'
  printf '"commandPlan":{'
  printf '"rescan":'; emit_json_string_array "${rescan_plan[@]}"; printf ','
  printf '"visibilityScan":'; emit_json_string_array "${list_plan[@]}"; printf ','
  printf '"connect":'; emit_json_string_array "${connect_plan[@]}"; printf ','
  printf '"status":'; emit_json_string_array "${status_plan[@]}"
  printf '},'
  printf '"operatorStatus":{'
  printf '"status":'; json_string "$operator_status"; printf ','
  printf '"severity":'; json_string "$operator_severity"; printf ','
  printf '"queue":'; json_string "wifi_setup"; printf ','
  printf '"primaryAction":'; json_string "$operator_primary_action"; printf ','
  printf '"blocked":'; json_bool "$operator_blocked"; printf ','
  printf '"attention":'; json_bool "$operator_attention"; printf ','
  printf '"canAttemptConnect":'; json_bool "$operator_can_attempt"; printf ','
  printf '"requiresNmcli":true,'
  printf '"requiresVisibilityScan":'; json_bool "$REQUIRE_VISIBLE"; printf ','
  printf '"requiresConnectedVerification":'; json_bool "$REQUIRE_CONNECTED"; printf ','
  printf '"commandRef":'; json_string "commandPlan.connect"; printf ','
  printf '"verificationRef":'; json_string "commandPlan.status"; printf ','
  printf '"completionGate":'; json_string "$operator_completion_gate"; printf ','
  printf '"counts":{'
  printf '"commandPlanEntries":4,'
  printf '"nextActions":%s' "${#next_actions[@]}"
  printf '},'
  printf '"redaction":{'
  printf '"ssidRaw":false,'
  printf '"passwordRaw":false'
  printf '}'
  printf '},'
  printf '"nextActions":'; emit_json_string_array "${next_actions[@]}"
  printf '}\n'
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --device)
      [[ "$#" -ge 2 && -n "$2" ]] || fail_usage
      DEVICE="$2"
      shift 2
      ;;
    --rescan)
      RESCAN=1
      shift
      ;;
    --require-connected)
      REQUIRE_CONNECTED=1
      shift
      ;;
    --require-visible)
      REQUIRE_VISIBLE=1
      shift
      ;;
    --verify-internet)
      VERIFY_INTERNET=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --plan-json)
      PLAN_JSON=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      fail_usage
      ;;
    *)
      break
      ;;
  esac
done

[[ "$#" -ge 1 ]] || fail_usage
[[ "$#" -le 2 ]] || fail_usage

SSID="$1"
PASSWORD="${2:-}"

[[ -n "$SSID" ]] || fail_usage

if [[ "$#" -eq 2 ]]; then
  PASSWORD_SUPPLIED=1
  if [[ "$PASSWORD" == "-" ]]; then
    PASSWORD_SOURCE="stdin"
    if [[ "$PLAN_JSON" -eq 0 ]]; then
      IFS= read -r PASSWORD || PASSWORD=""
    fi
  else
    PASSWORD_SOURCE="argument"
  fi
fi

if [[ "$PLAN_JSON" -eq 1 ]]; then
  emit_plan_json
  exit 0
fi

resolve_nmcli

rescan_args=(device wifi rescan)
list_args=(-t -f SSID device wifi list --rescan no)
connect_args=(device wifi connect "$SSID")
status_args=(-t -f DEVICE,TYPE,STATE,CONNECTION device status)

if [[ -n "$PASSWORD" ]]; then
  connect_args+=(password "$PASSWORD")
fi

if [[ -n "$DEVICE" ]]; then
  rescan_args+=(ifname "$DEVICE")
  list_args+=(ifname "$DEVICE")
  connect_args+=(ifname "$DEVICE")
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  if [[ "$RESCAN" -eq 1 ]]; then
    printf 'nmcli'
    printf ' %q' "${rescan_args[@]}"
    printf '\n'
  fi
  if [[ "$REQUIRE_VISIBLE" -eq 1 ]]; then
    printf 'nmcli'
    printf ' %q' "${list_args[@]}"
    printf '\n'
  fi
  printf 'nmcli'
  for arg in "${connect_args[@]}"; do
    if [[ "$PASSWORD_SUPPLIED" -eq 1 && "$arg" == "$PASSWORD" ]]; then
      printf ' %q' "[redacted]"
    else
      printf ' %q' "$arg"
    fi
  done
  printf '\n'
  exit 0
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if [[ "$RESCAN" -eq 1 ]]; then
  RESCAN_STDERR="$TMP_DIR/rescan.err"
  set +e
  run_nmcli "${rescan_args[@]}" >/dev/null 2>"$RESCAN_STDERR"
  rescan_code="$?"
  set -e
  if [[ "$rescan_code" -ne 0 ]]; then
    if [[ "$PASSWORD_SUPPLIED" -eq 1 ]]; then
      echo "Wi-Fi rescan failed; nmcli output redacted because a password was supplied." >&2
    else
      cat "$RESCAN_STDERR" >&2
    fi
    echo "Wi-Fi rescan failed." >&2
    exit 4
  fi
fi

if [[ "$REQUIRE_VISIBLE" -eq 1 ]]; then
  SCAN_STDOUT="$TMP_DIR/scan.out"
  SCAN_STDERR="$TMP_DIR/scan.err"
  set +e
  run_nmcli "${list_args[@]}" >"$SCAN_STDOUT" 2>"$SCAN_STDERR"
  scan_code="$?"
  set -e
  if [[ "$scan_code" -ne 0 ]]; then
    if [[ "$PASSWORD_SUPPLIED" -eq 1 ]]; then
      echo "Wi-Fi scan failed; nmcli output redacted because a password was supplied." >&2
    else
      cat "$SCAN_STDERR" >&2
    fi
    echo "Wi-Fi scan failed." >&2
    exit 4
  fi
  if ! ssid_visible_in_scan "$(cat "$SCAN_STDOUT")"; then
    echo "Target Wi-Fi network is not visible in scan results." >&2
    exit 6
  fi
fi

CONNECT_STDOUT="$TMP_DIR/connect.out"
CONNECT_STDERR="$TMP_DIR/connect.err"

set +e
run_nmcli "${connect_args[@]}" >"$CONNECT_STDOUT" 2>"$CONNECT_STDERR"
connect_code="$?"
set -e

if [[ "$connect_code" -ne 0 ]]; then
  if [[ "$PASSWORD_SUPPLIED" -eq 1 ]]; then
    echo "Wi-Fi connection failed; nmcli output redacted because a password was supplied." >&2
  else
    cat "$CONNECT_STDERR" >&2
  fi
  exit 4
fi

if [[ "$PASSWORD_SUPPLIED" -eq 0 ]]; then
  cat "$CONNECT_STDOUT"
fi

if [[ "$REQUIRE_CONNECTED" -eq 1 ]]; then
  status="$(run_nmcli "${status_args[@]}" 2>/dev/null || true)"
  if [[ -n "$DEVICE" ]]; then
    if ! awk -F: -v device="$DEVICE" '$1 == device && $2 == "wifi" && $3 == "connected" { found = 1 } END { exit found ? 0 : 1 }' <<<"$status"; then
      echo "Wi-Fi device '$DEVICE' is not reported connected after connection attempt." >&2
      exit 5
    fi
  elif ! awk -F: '$2 == "wifi" && $3 == "connected" { found = 1 } END { exit found ? 0 : 1 }' <<<"$status"; then
    echo "no Wi-Fi device is reported connected after connection attempt." >&2
    exit 5
  fi
fi

if [[ "$VERIFY_INTERNET" -eq 1 ]]; then
  if ! ip route get 8.8.8.8 >/dev/null 2>&1; then
    echo "Wi-Fi connected, but no internet connectivity available." >&2
    exit 7
  fi
fi
