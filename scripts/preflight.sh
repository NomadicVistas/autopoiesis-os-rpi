#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-}"
FAILURES=0
WARNINGS=0
MIN_FREE_MB="${AUTOPOIESIS_PREFLIGHT_MIN_FREE_MB:-1024}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="${AUTOPOIESIS_PREFLIGHT_APP_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

fail() {
  echo "FAIL: $*" >&2
  FAILURES=$((FAILURES + 1))
}

warn() {
  echo "WARN: $*" >&2
  WARNINGS=$((WARNINGS + 1))
}

pass() {
  echo "OK: $*"
}

require_command() {
  local command_name="$1"
  local hint="$2"
  if command -v "$command_name" >/dev/null 2>&1; then
    pass "$command_name found"
  else
    fail "$command_name is required. $hint"
  fi
}

require_copy_tool() {
  if command -v rsync >/dev/null 2>&1; then
    pass "rsync found for appliance app-tree copy"
  elif command -v tar >/dev/null 2>&1; then
    pass "tar found for appliance app-tree copy fallback"
  else
    fail "rsync or tar is required. Install rsync or tar before running the appliance installer."
  fi
}

require_path() {
  local kind="$1"
  local relative_path="$2"
  local full_path="$APP_ROOT/$relative_path"

  case "$kind" in
    dir)
      if [[ -d "$full_path" ]]; then
        pass "app tree contains $relative_path/"
      else
        fail "app tree is missing required directory: $relative_path"
      fi
      ;;
    file)
      if [[ -f "$full_path" ]]; then
        pass "app tree contains $relative_path"
      else
        fail "app tree is missing required file: $relative_path"
      fi
      ;;
    executable)
      if [[ -x "$full_path" && -f "$full_path" ]]; then
        pass "app tree contains executable $relative_path"
      elif [[ -f "$full_path" ]]; then
        fail "app tree file is not executable: $relative_path"
      else
        fail "app tree is missing required executable: $relative_path"
      fi
      ;;
  esac
}

check_app_tree() {
  if [[ ! -d "$APP_ROOT" ]]; then
    fail "appliance app tree does not exist: $APP_ROOT"
    return
  fi

  pass "checking appliance app tree at $APP_ROOT"

  local required_dirs=(
    config
    local-ui
    scripts
    services
    timers
  )

  local required_files=(
    VERSION
    config/defaults.json
    config/device.example.json
    config/autopoiesis-os.logrotate
    local-ui/package.json
    local-ui/server.js
    services/autopoiesis-setup.service
    services/autopoiesis-kiosk.service
    services/autopoiesis-heartbeat.service
    services/autopoiesis-command-executor.service
    services/autopoiesis-cache.service
    services/autopoiesis-updater.service
    services/autopoiesis-watchdog.service
    timers/autopoiesis-heartbeat.timer
    timers/autopoiesis-command-executor.timer
    timers/autopoiesis-cache.timer
    timers/autopoiesis-updater.timer
    timers/autopoiesis-watchdog.timer
  )

  local required_executables=(
    install.sh
    update.sh
    factory-reset.sh
    scripts/install-app-tree.sh
    scripts/install-app-tree-check.sh
    scripts/bootstrap.sh
    scripts/ensure-appliance-user.sh
    scripts/generate-device-id.sh
    scripts/install-systemd-units.sh
    scripts/start-setup.sh
    scripts/start-kiosk.sh
    scripts/hardware-profile-check.sh
    scripts/heartbeat.sh
    scripts/process-commands.sh
    scripts/cache-artworks.sh
    scripts/update-from-github.sh
    scripts/watchdog.sh
    scripts/configure-kiosk-os.sh
    scripts/feed-sync.sh
    scripts/remote-install-check.sh
  )

  local required_root_files=(
    remote-install.sh
  )

  local path
  for path in "${required_dirs[@]}"; do
    require_path dir "$path"
  done

  for path in "${required_files[@]}"; do
    require_path file "$path"
  done

  for path in "${required_executables[@]}"; do
    require_path executable "$path"
  done

  for path in "${required_root_files[@]}"; do
    require_path executable "$path"
  done

  if command -v node >/dev/null 2>&1 && [[ -f "$APP_ROOT/local-ui/server.js" ]]; then
    if node --check "$APP_ROOT/local-ui/server.js" >/dev/null 2>&1; then
      pass "local-ui/server.js parses"
    else
      fail "local-ui/server.js failed node --check"
    fi
  fi
}

is_positive_integer() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

existing_path_for_df() {
  local path="$1"
  while [[ ! -e "$path" && "$path" != "/" ]]; do
    path="$(dirname "$path")"
  done
  printf '%s\n' "$path"
}

check_free_space() {
  local label="$1"
  local target_path="$2"
  local min_mb="$3"

  if [[ "$min_mb" == "0" ]]; then
    warn "free-space check disabled for $label at $target_path"
    return
  fi

  if ! is_positive_integer "$min_mb"; then
    fail "AUTOPOIESIS_PREFLIGHT_MIN_FREE_MB must be a positive integer or 0 to disable."
    return
  fi

  local probe_path
  probe_path="$(existing_path_for_df "$target_path")"

  local available_mb
  available_mb="$(df -Pm "$probe_path" 2>/dev/null | awk 'NR == 2 { print $4 }')"
  if ! is_positive_integer "$available_mb"; then
    fail "could not determine free disk space for $label at $target_path."
    return
  fi

  if [[ "$available_mb" -lt "$min_mb" ]]; then
    fail "$label volume has ${available_mb} MB free for $target_path; at least ${min_mb} MB is required."
  else
    pass "$label volume has ${available_mb} MB free for $target_path (min ${min_mb} MB)"
  fi
}

check_node_version() {
  if ! command -v node >/dev/null 2>&1; then
    fail "node is required. Install Node.js 20 or newer."
    return
  fi

  local major
  major="$(node -p "Number(process.versions.node.split('.')[0])" 2>/dev/null || echo 0)"
  if [[ "$major" -ge 20 ]]; then
    pass "node $(node -v) found"
  else
    fail "node $(node -v 2>/dev/null || echo unknown) is too old. Install Node.js 20 or newer."
  fi
}

check_hardware_profile() {
  local arch
  arch="$(uname -m)"
  local model=""
  if [[ -r /proc/device-tree/model ]]; then
    model="$(tr -d '\0' </proc/device-tree/model | sed 's/[[:space:]]*$//')"
  fi
  local total_mb
  total_mb="$(awk '/MemTotal:/ { printf "%d", $2 / 1024 }' /proc/meminfo 2>/dev/null || echo 0)"

  if [[ "$model" =~ Raspberry[[:space:]]Pi[[:space:]]5 ]]; then
    pass "hardware profile: Raspberry Pi 5 recommended target (${total_mb} MB RAM)"
  elif [[ "$model" =~ Raspberry[[:space:]]Pi[[:space:]]4 ]]; then
    pass "hardware profile: Raspberry Pi 4 supported baseline (${total_mb} MB RAM)"
  elif [[ "$model" =~ Raspberry[[:space:]]Pi ]]; then
    warn "hardware profile: $model is below the supported Chromium kiosk baseline; use Raspberry Pi 4+ or Pi 5 recommended."
  elif [[ "$arch" == "x86_64" || "$arch" == "amd64" ]]; then
    warn "hardware profile: x86_64 development/mini-PC host detected; Pi 5 remains the primary appliance target."
  else
    warn "hardware profile: unknown model on $arch; validate Chromium kiosk performance manually."
  fi

  if [[ "$total_mb" =~ ^[0-9]+$ && "$total_mb" -gt 0 && "$total_mb" -lt 2048 ]]; then
    warn "hardware profile: ${total_mb} MB RAM is below the 2 GB caution threshold for Chromium kiosk use."
  fi
}

echo "Autopoiesis OS appliance preflight"
echo "Date: $(date -Is)"
echo

check_app_tree

if [[ "$MODE" == "--install" && "$(id -u)" -ne 0 ]]; then
  fail "install mode requires root. Run: sudo ./install.sh"
fi

ARCH="$(uname -m)"
case "$ARCH" in
  aarch64|armv7l|armv6l)
    pass "Raspberry Pi-compatible architecture: $ARCH"
    ;;
  x86_64|amd64)
    warn "Architecture is $ARCH, which is useful for development but not the target Pi appliance."
    ;;
  *)
    warn "Untested architecture: $ARCH"
    ;;
esac

if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_LABEL="${PRETTY_NAME:-${ID:-unknown}}"
  case "${ID:-}" in
    debian|raspbian)
      pass "OS looks compatible: $OS_LABEL"
      ;;
    *)
      warn "OS is '$OS_LABEL'. Raspberry Pi OS or Debian is expected."
      ;;
  esac
else
  warn "/etc/os-release is missing; cannot identify OS."
fi

require_command bash "Install bash."
require_copy_tool
require_command curl "Install curl for local health checks, launch probing, and release downloads."
require_command systemctl "Install or boot into a systemd-based Raspberry Pi OS image."
check_node_version
check_hardware_profile

if command -v chromium-browser >/dev/null 2>&1 || command -v chromium >/dev/null 2>&1; then
  pass "Chromium found"
else
  warn "Chromium is not installed. The local UI can install, but kiosk launch will fail until chromium/chromium-browser is available."
fi

if command -v nmcli >/dev/null 2>&1; then
  pass "NetworkManager nmcli found"
else
  warn "nmcli is not installed. LAN/Wi-Fi setup pages will be limited until NetworkManager is available."
fi

if [[ "$MODE" == "--install" ]]; then
  USER_NAME="${AUTOPOIESIS_USER:-frame}"
  INSTALL_DIR="${AUTOPOIESIS_INSTALL_DIR:-/opt/autopoiesis-os}"
  DATA_DIR="${AUTOPOIESIS_DATA_DIR:-/var/lib/autopoiesis-os}"
  LOG_DIR="${AUTOPOIESIS_LOG_DIR:-/var/log/autopoiesis-os}"

  check_free_space "install" "$INSTALL_DIR" "$MIN_FREE_MB"
  check_free_space "data" "$DATA_DIR" "$MIN_FREE_MB"
  check_free_space "log" "$LOG_DIR" "$MIN_FREE_MB"

  if id -u "$USER_NAME" >/dev/null 2>&1; then
    pass "appliance user '$USER_NAME' exists"
  else
    warn "appliance user '$USER_NAME' does not exist yet; install will create it."
  fi
fi

echo
if [[ "$FAILURES" -gt 0 ]]; then
  echo "Preflight failed with $FAILURES failure(s) and $WARNINGS warning(s)." >&2
  exit 1
fi

echo "Preflight passed with $WARNINGS warning(s)."
