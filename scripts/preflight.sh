#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-}"
FAILURES=0
WARNINGS=0

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

echo "Autopoiesis OS appliance preflight"
echo "Date: $(date -Is)"
echo

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
require_command rsync "Install rsync before running the appliance installer."
require_command curl "Install curl for local health checks, launch probing, and release downloads."
require_command systemctl "Install or boot into a systemd-based Raspberry Pi OS image."
check_node_version

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
