#!/usr/bin/env bash
set -euo pipefail

APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
DATA_DIR="$TMP_DIR/data"
LOG_DIR="$TMP_DIR/logs"
BIN_DIR="$TMP_DIR/bin"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "heartbeat runner check failed: $*" >&2
  exit 1
}

require_contains() {
  local file="$1"
  local needle="$2"
  [[ -f "$file" ]] || fail "$file was not created"
  grep -F -- "$needle" "$file" >/dev/null || fail "$file did not contain: $needle"
}

write_curl() {
  local mode="$1"
  cat >"$BIN_DIR/curl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$TMP_DIR/curl-args.log"
if [[ "$mode" == "fail" ]]; then
  echo "mock curl failure" >&2
  exit 22
fi
printf '{"ok":true,"source":"mock-local-heartbeat"}'
EOF
  chmod +x "$BIN_DIR/curl"
}

mkdir -p "$DATA_DIR" "$LOG_DIR" "$BIN_DIR"

cat >"$DATA_DIR/device.json" <<'JSON'
{"deviceId":"frame-heartbeat-check"}
JSON
cat >"$DATA_DIR/state.json" <<'JSON'
{"currentMode":"online"}
JSON

write_curl success
PATH="$BIN_DIR:$PATH" \
AUTOPOIESIS_DATA_DIR="$DATA_DIR" \
AUTOPOIESIS_LOG_DIR="$LOG_DIR" \
AUTOPOIESIS_LOCAL_URL="http://127.0.0.1:3999/" \
"$APP_ROOT/scripts/heartbeat.sh"

require_contains "$LOG_DIR/heartbeat.log" "device=frame-heartbeat-check"
require_contains "$LOG_DIR/heartbeat.log" "mode=online"
require_contains "$LOG_DIR/heartbeat.log" '"source":"mock-local-heartbeat"'
require_contains "$TMP_DIR/curl-args.log" "-X POST http://127.0.0.1:3999/local/heartbeat"
[[ ! -s "$LOG_DIR/heartbeat-error.log" ]] || fail "successful heartbeat wrote errors"

rm -f "$TMP_DIR/curl-args.log"
write_curl fail
PATH="$BIN_DIR:$PATH" \
AUTOPOIESIS_DATA_DIR="$DATA_DIR" \
AUTOPOIESIS_LOG_DIR="$LOG_DIR" \
AUTOPOIESIS_LOCAL_URL="http://127.0.0.1:3999" \
"$APP_ROOT/scripts/heartbeat.sh"

require_contains "$LOG_DIR/heartbeat-error.log" "mock curl failure"
require_contains "$LOG_DIR/heartbeat-error.log" "local heartbeat failed"
require_contains "$TMP_DIR/curl-args.log" "-X POST http://127.0.0.1:3999/local/heartbeat"

rm -rf "$DATA_DIR" "$LOG_DIR"
mkdir -p "$DATA_DIR"
printf '{broken' >"$DATA_DIR/device.json"

write_curl success
PATH="$BIN_DIR:$PATH" \
AUTOPOIESIS_DATA_DIR="$DATA_DIR" \
AUTOPOIESIS_LOG_DIR="$LOG_DIR" \
"$APP_ROOT/scripts/heartbeat.sh"

require_contains "$LOG_DIR/heartbeat.log" "device=unknown"
require_contains "$LOG_DIR/heartbeat.log" "mode=unknown"

echo "heartbeat runner check passed: wrapper logs identity/mode, records local UI failures, and survives missing or malformed local state"
