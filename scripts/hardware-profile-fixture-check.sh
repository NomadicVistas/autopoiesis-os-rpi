#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_PORT="${AUTOPOIESIS_HARDWARE_FIXTURE_PORT_BASE:-3390}"
TMP_DIR="$(mktemp -d)"

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "hardware profile fixture check failed: $*" >&2
  exit 1
}

write_vcgencmd_stub() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat >"$bin_dir/vcgencmd" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "get_throttled" ]]; then
  printf 'throttled=%s\n' "${AOS_FAKE_THROTTLED:-0x0}"
  exit 0
fi
echo "unsupported vcgencmd call: $*" >&2
exit 1
EOF
  chmod +x "$bin_dir/vcgencmd"
}

wait_for_local_ui() {
  local url="$1"
  local log_file="$2"
  for _ in $(seq 1 80); do
    if curl -fsS "$url/local/health?services=0" >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
      sed -n '1,160p' "$log_file" >&2 || true
      fail "local UI exited before responding at $url"
    fi
    sleep 0.1
  done
  sed -n '1,160p' "$log_file" >&2 || true
  fail "local UI did not respond at $url"
}

stop_server() {
  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  SERVER_PID=""
}

run_case() {
  local name="$1"
  local model="$2"
  local throttle="$3"
  local expected_status="$4"
  local expected_supported="$5"
  local expected_recommended="$6"
  local expected_issues="$7"
  local require_supported="${8:-0}"
  local require_recommended="${9:-0}"
  local port=$((BASE_PORT + CASE_INDEX))
  CASE_INDEX=$((CASE_INDEX + 1))

  local case_dir="$TMP_DIR/$name"
  local bin_dir="$case_dir/bin"
  local model_path="$case_dir/device-tree-model"
  local log_file="$case_dir/server.log"
  local url="http://127.0.0.1:$port"
  mkdir -p "$case_dir/data" "$case_dir/cache" "$case_dir/logs"
  write_vcgencmd_stub "$bin_dir"

  if [[ "$model" == "__missing__" ]]; then
    rm -f "$model_path"
  else
    printf '%s\0' "$model" >"$model_path"
  fi

  AOS_FAKE_THROTTLED="$throttle" \
    AUTOPOIESIS_PORT="$port" \
    AUTOPOIESIS_DATA_DIR="$case_dir/data" \
    AUTOPOIESIS_CACHE_DIR="$case_dir/cache" \
    AUTOPOIESIS_LOG_DIR="$case_dir/logs" \
    AUTOPOIESIS_DEVICE_TREE_MODEL_PATH="$model_path" \
    AUTOPOIESIS_VCGENCMD_BIN="$bin_dir/vcgencmd" \
    node "$ROOT_DIR/local-ui/server.js" >"$log_file" 2>&1 &
  SERVER_PID="$!"
  wait_for_local_ui "$url" "$log_file"

  AUTOPOIESIS_LOCAL_URL="$url" \
    AUTOPOIESIS_REQUIRE_SUPPORTED_HARDWARE="$require_supported" \
    AUTOPOIESIS_REQUIRE_RECOMMENDED_HARDWARE="$require_recommended" \
    "$ROOT_DIR/scripts/hardware-profile-check.sh" >"$case_dir/check.out"

  curl -fsS "$url/local/diagnostics?services=0" >"$case_dir/diagnostics.json"
  curl -fsS "$url/local/health?services=0" >"$case_dir/health.json"
  curl -fsS "$url/local/readiness?services=0" >"$case_dir/readiness.json"
  curl -fsS "$url/local/support-bundle?services=0" >"$case_dir/support.json"

  node - "$case_dir/diagnostics.json" "$case_dir/health.json" "$case_dir/readiness.json" "$case_dir/support.json" "$expected_status" "$expected_supported" "$expected_recommended" "$expected_issues" "$name" <<'NODE'
const fs = require("fs");
const diagnosticsPayload = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const health = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const readiness = JSON.parse(fs.readFileSync(process.argv[4], "utf8"));
const support = JSON.parse(fs.readFileSync(process.argv[5], "utf8"));
const expectedStatus = process.argv[6];
const expectedSupported = process.argv[7] === "true";
const expectedRecommended = process.argv[8] === "true";
const expectedIssues = process.argv[9].split(",").filter(Boolean);
const caseName = process.argv[10];

function fail(message) {
  console.error("hardware profile fixture check failed for " + caseName + ": " + message);
  process.exit(1);
}

const diagnostics = diagnosticsPayload.diagnostics || diagnosticsPayload;
const hardware = diagnostics.hardware || {};
if (hardware.status !== expectedStatus) fail("expected diagnostics.hardware.status " + expectedStatus + ", got " + hardware.status);
if (hardware.supported !== expectedSupported) fail("expected diagnostics.hardware.supported " + expectedSupported + ", got " + hardware.supported);
if (hardware.recommended !== expectedRecommended) fail("expected diagnostics.hardware.recommended " + expectedRecommended + ", got " + hardware.recommended);

const readinessHardware = ((readiness.phases || {}).hardware || {});
if (readinessHardware.status !== expectedStatus) fail("expected readiness hardware status " + expectedStatus + ", got " + readinessHardware.status);
if (Boolean(readinessHardware.ready) !== expectedSupported) fail("expected readiness hardware ready " + expectedSupported + ", got " + readinessHardware.ready);

const supportHardware = ((support.summary || {}).hardware || {});
if (supportHardware.status !== expectedStatus) fail("expected support hardware status " + expectedStatus + ", got " + supportHardware.status);
if (supportHardware.supported !== expectedSupported) fail("expected support hardware supported " + expectedSupported + ", got " + supportHardware.supported);
if (supportHardware.recommended !== expectedRecommended) fail("expected support hardware recommended " + expectedRecommended + ", got " + supportHardware.recommended);

const issueCodes = (((health.health || {}).issues || [])).map(issue => issue.code).filter(Boolean);
const hardwareIssues = issueCodes.filter(code => code.startsWith("hardware_"));
for (const expected of expectedIssues) {
  if (!issueCodes.includes(expected)) fail("missing expected health issue " + expected + " from " + issueCodes.join(","));
}
if (expectedIssues.length === 0 && hardwareIssues.length > 0) {
  fail("unexpected hardware health issues: " + hardwareIssues.join(","));
}
NODE

  printf 'hardware fixture %-18s status=%s supported=%s recommended=%s issues=%s\n' \
    "$name" "$expected_status" "$expected_supported" "$expected_recommended" "${expected_issues:-none}"
  stop_server
}

command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v node >/dev/null 2>&1 || fail "node is required"

CASE_INDEX=0
SERVER_PID=""

run_case "pi5-clean" "Raspberry Pi 5 Model B Rev 1.0" "0x0" "recommended" "true" "true" "" "1" "1"
run_case "pi4-clean" "Raspberry Pi 4 Model B Rev 1.5" "0x0" "supported_baseline" "true" "false" "" "1" "0"
run_case "pi3-underpowered" "Raspberry Pi 3 Model B Plus Rev 1.3" "0x0" "underpowered" "false" "false" "hardware_underpowered" "0" "0"
run_case "pi5-throttled" "Raspberry Pi 5 Model B Rev 1.0" "0x50005" "recommended" "true" "true" "hardware_undervoltage,hardware_throttled" "1" "1"

echo "hardware profile fixture check passed: Pi 5, Pi 4, Pi 3, and throttling classifications verified"
