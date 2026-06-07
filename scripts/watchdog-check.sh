#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
BIN_DIR="$TMP_DIR/bin"
LOG_DIR="$TMP_DIR/logs"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "watchdog check failed: $*" >&2
  exit 1
}

require_contains() {
  local file="$1"
  local expected="$2"
  [[ -f "$file" ]] || fail "missing log file $file"
  grep -Fq "$expected" "$file" || fail "$file does not contain: $expected"
}

require_not_contains() {
  local file="$1"
  local unexpected="$2"
  if [[ -f "$file" ]] && grep -Fq "$unexpected" "$file"; then
    fail "$file unexpectedly contains: $unexpected"
  fi
}

write_stubs() {
  mkdir -p "$BIN_DIR" "$LOG_DIR"

  cat >"$BIN_DIR/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AOS_STUB_SYSTEMCTL_LOG"
exit 0
EOF
  chmod +x "$BIN_DIR/systemctl"

  cat >"$BIN_DIR/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AOS_STUB_SLEEP_LOG"
exit 0
EOF
  chmod +x "$BIN_DIR/sleep"

  cat >"$BIN_DIR/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AOS_STUB_CURL_LOG"
url="${@: -1}"
mode="ok"
state_file="$AOS_STUB_STATE_DIR/curl-other.count"
case "$url" in
  */local/health*)
    mode="${AOS_STUB_HEALTH_MODE:-ok}"
    state_file="$AOS_STUB_STATE_DIR/curl-health.count"
    ;;
  */launch*)
    mode="${AOS_STUB_LAUNCH_MODE:-ok}"
    state_file="$AOS_STUB_STATE_DIR/curl-launch.count"
    ;;
esac
count=0
if [[ -f "$state_file" ]]; then
  count="$(cat "$state_file")"
fi
count=$((count + 1))
printf '%s' "$count" > "$state_file"
if [[ "$mode" == "fail" || ( "$mode" == "fail-once" && "$count" == "1" ) ]]; then
  echo "stub curl failure for $url" >&2
  exit 22
fi
if [[ " $* " == *" -I "* || " $* " == *" -fSI "* || " $* " == *" -fsSI "* ]]; then
  printf 'HTTP/1.1 200 OK\r\n\r\n'
else
  printf '{"ok":true,"url":"%s"}\n' "$url"
fi
EOF
  chmod +x "$BIN_DIR/curl"

  cat >"$BIN_DIR/pgrep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AOS_STUB_PGREP_LOG"
mode="${AOS_STUB_PGREP_MODE:-ok}"
state_file="$AOS_STUB_STATE_DIR/pgrep.count"
count=0
if [[ -f "$state_file" ]]; then
  count="$(cat "$state_file")"
fi
count=$((count + 1))
printf '%s' "$count" > "$state_file"
if [[ "$mode" == "missing" || ( "$mode" == "missing-once" && "$count" == "1" ) ]]; then
  exit 1
fi
printf '1234 /usr/bin/chromium --kiosk --disable-gpu --use-gl=swiftshader http://127.0.0.1:3999/launch\n'
EOF
  chmod +x "$BIN_DIR/pgrep"
}

reset_logs() {
  rm -rf "$LOG_DIR"
  mkdir -p "$LOG_DIR"
}

run_watchdog() {
  local scenario="$1"
  local health_mode="$2"
  local launch_mode="$3"
  local pgrep_mode="$4"
  local state_dir="$TMP_DIR/state-$scenario"
  mkdir -p "$state_dir"
  reset_logs
  PATH="$BIN_DIR:$PATH" \
    AOS_STUB_STATE_DIR="$state_dir" \
    AOS_STUB_SYSTEMCTL_LOG="$LOG_DIR/systemctl.log" \
    AOS_STUB_SLEEP_LOG="$LOG_DIR/sleep.log" \
    AOS_STUB_CURL_LOG="$LOG_DIR/curl.log" \
    AOS_STUB_PGREP_LOG="$LOG_DIR/pgrep.log" \
    AOS_STUB_HEALTH_MODE="$health_mode" \
    AOS_STUB_LAUNCH_MODE="$launch_mode" \
    AOS_STUB_PGREP_MODE="$pgrep_mode" \
    AUTOPOIESIS_SYSTEMCTL_BIN=systemctl \
    AUTOPOIESIS_LOCAL_URL="http://127.0.0.1:3999" \
    AUTOPOIESIS_LAUNCH_URL="http://127.0.0.1:3999/launch" \
    AUTOPOIESIS_WATCHDOG_WAIT_SECONDS=1 \
    "$ROOT_DIR/scripts/watchdog.sh" >"$LOG_DIR/$scenario.out" 2>"$LOG_DIR/$scenario.err"
}

write_stubs

run_watchdog healthy ok ok ok
require_not_contains "$LOG_DIR/systemctl.log" "restart"
require_contains "$LOG_DIR/healthy.out" "watchdog check passed"

run_watchdog health-recovery fail-once ok ok
require_contains "$LOG_DIR/systemctl.log" "restart autopoiesis-setup.service"
require_not_contains "$LOG_DIR/systemctl.log" "restart autopoiesis-kiosk.service"
require_contains "$LOG_DIR/health-recovery.out" "local setup UI is reachable"

run_watchdog launch-recovery ok fail-once ok
require_contains "$LOG_DIR/systemctl.log" "restart autopoiesis-setup.service"
require_not_contains "$LOG_DIR/systemctl.log" "restart autopoiesis-kiosk.service"
require_contains "$LOG_DIR/launch-recovery.out" "launch route is reachable"

run_watchdog kiosk-recovery ok ok missing-once
require_contains "$LOG_DIR/systemctl.log" "restart autopoiesis-kiosk.service"
require_not_contains "$LOG_DIR/systemctl.log" "restart autopoiesis-setup.service"
require_contains "$LOG_DIR/kiosk-recovery.out" "watchdog check passed"

echo "watchdog check passed: healthy no-op, setup HTTP recovery, launch recovery, and kiosk restart behavior verified"
