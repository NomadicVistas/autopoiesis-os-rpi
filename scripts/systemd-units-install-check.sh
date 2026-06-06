#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

APP_DIR="$TMP_DIR/custom-app"
INSTALL_DIR="$TMP_DIR/custom-install"
DATA_DIR="$TMP_DIR/custom-data"
LOG_DIR="$TMP_DIR/custom-log"
SYSTEMD_DIR="$TMP_DIR/systemd"
SYSTEMCTL="$TMP_DIR/systemctl"
SYSTEMCTL_LOG="$TMP_DIR/systemctl.log"
USER_NAME="gallery"
USER_HOME="$TMP_DIR/gallery-home"

mkdir -p "$APP_DIR" "$INSTALL_DIR" "$DATA_DIR" "$LOG_DIR" "$USER_HOME"
cp -a "$ROOT_DIR/services" "$APP_DIR/services"
cp -a "$ROOT_DIR/timers" "$APP_DIR/timers"

printf '#!/usr/bin/env bash\nprintf '"'"'%%s\\n'"'"' "$*" >> %q\n' "$SYSTEMCTL_LOG" >"$SYSTEMCTL"
chmod +x "$SYSTEMCTL"

AUTOPOIESIS_ALLOW_NON_ROOT_SYSTEMD_INSTALL=1 \
  AUTOPOIESIS_APP_DIR="$APP_DIR" \
  AUTOPOIESIS_INSTALL_DIR="$INSTALL_DIR" \
  AUTOPOIESIS_DATA_DIR="$DATA_DIR" \
  AUTOPOIESIS_LOG_DIR="$LOG_DIR" \
  AUTOPOIESIS_USER="$USER_NAME" \
  AUTOPOIESIS_USER_HOME="$USER_HOME" \
  AUTOPOIESIS_SYSTEMD_DIR="$SYSTEMD_DIR" \
  AUTOPOIESIS_SYSTEMCTL_BIN="$SYSTEMCTL" \
  "$ROOT_DIR/scripts/install-systemd-units.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require_file() {
  local file="$1"
  [[ -f "$file" ]] || fail "missing rendered unit $file"
}

require_contains() {
  local file="$1"
  local expected="$2"
  grep -Fq "$expected" "$file" || fail "$file does not contain: $expected"
}

require_not_contains() {
  local file="$1"
  local unexpected="$2"
  if grep -Fq "$unexpected" "$file"; then
    fail "$file still contains hardcoded value: $unexpected"
  fi
}

for unit in \
  autopoiesis-setup.service \
  autopoiesis-kiosk.service \
  autopoiesis-heartbeat.service \
  autopoiesis-cache.service \
  autopoiesis-command-executor.service \
  autopoiesis-updater.service \
  autopoiesis-watchdog.service \
  autopoiesis-heartbeat.timer \
  autopoiesis-command-executor.timer \
  autopoiesis-cache.timer \
  autopoiesis-updater.timer \
  autopoiesis-watchdog.timer; do
  require_file "$SYSTEMD_DIR/$unit"
done

for service in "$SYSTEMD_DIR/"*.service; do
  require_not_contains "$service" "/opt/autopoiesis-os"
  require_not_contains "$service" "/var/lib/autopoiesis-os"
  require_not_contains "$service" "/var/log/autopoiesis-os"
  require_not_contains "$service" "/home/frame"
  require_not_contains "$service" "User=frame"
  require_not_contains "$service" "Group=frame"
done

require_contains "$SYSTEMD_DIR/autopoiesis-setup.service" "User=$USER_NAME"
require_contains "$SYSTEMD_DIR/autopoiesis-setup.service" "Group=$USER_NAME"
require_contains "$SYSTEMD_DIR/autopoiesis-setup.service" "Environment=AUTOPOIESIS_DATA_DIR=$DATA_DIR"
require_contains "$SYSTEMD_DIR/autopoiesis-setup.service" "Environment=AUTOPOIESIS_LOG_DIR=$LOG_DIR"
require_contains "$SYSTEMD_DIR/autopoiesis-setup.service" "Environment=AUTOPOIESIS_INSTALL_DIR=$INSTALL_DIR"
require_contains "$SYSTEMD_DIR/autopoiesis-setup.service" "Environment=AUTOPOIESIS_APP_DIR=$APP_DIR"
require_contains "$SYSTEMD_DIR/autopoiesis-setup.service" "WorkingDirectory=$APP_DIR/local-ui"
require_contains "$SYSTEMD_DIR/autopoiesis-setup.service" "ExecStart=$APP_DIR/scripts/start-setup.sh"

require_contains "$SYSTEMD_DIR/autopoiesis-kiosk.service" "Environment=XAUTHORITY=$USER_HOME/.Xauthority"
require_contains "$SYSTEMD_DIR/autopoiesis-kiosk.service" "Environment=AUTOPOIESIS_CHROMIUM_PROFILE=$DATA_DIR/chromium"
require_contains "$SYSTEMD_DIR/autopoiesis-kiosk.service" "ExecStart=$APP_DIR/scripts/start-kiosk.sh"

require_contains "$SYSTEMD_DIR/autopoiesis-cache.service" "Environment=AUTOPOIESIS_CACHE_DIR=$DATA_DIR/cache"
require_contains "$SYSTEMD_DIR/autopoiesis-cache.service" "ExecStart=$APP_DIR/scripts/cache-artworks.sh"
require_contains "$SYSTEMD_DIR/autopoiesis-heartbeat.service" "ExecStart=$APP_DIR/scripts/heartbeat.sh"
require_contains "$SYSTEMD_DIR/autopoiesis-command-executor.service" "User=root"
require_contains "$SYSTEMD_DIR/autopoiesis-command-executor.service" "Environment=AUTOPOIESIS_LOG_DIR=$LOG_DIR"
require_contains "$SYSTEMD_DIR/autopoiesis-updater.service" "User=root"
require_contains "$SYSTEMD_DIR/autopoiesis-updater.service" "Environment=AUTOPOIESIS_APP_DIR=$APP_DIR"
require_contains "$SYSTEMD_DIR/autopoiesis-updater.service" "Environment=AUTOPOIESIS_INSTALL_DIR=$INSTALL_DIR"
require_contains "$SYSTEMD_DIR/autopoiesis-updater.service" "Environment=AUTOPOIESIS_DATA_DIR=$DATA_DIR"
require_contains "$SYSTEMD_DIR/autopoiesis-updater.service" "Environment=AUTOPOIESIS_LOG_DIR=$LOG_DIR"
require_contains "$SYSTEMD_DIR/autopoiesis-updater.service" "Environment=AUTOPOIESIS_USER=$USER_NAME"
require_contains "$SYSTEMD_DIR/autopoiesis-watchdog.service" "ExecStart=$APP_DIR/scripts/watchdog.sh"

require_contains "$SYSTEMCTL_LOG" "daemon-reload"
require_contains "$SYSTEMCTL_LOG" "enable autopoiesis-setup.service autopoiesis-kiosk.service autopoiesis-heartbeat.timer autopoiesis-command-executor.timer autopoiesis-updater.timer autopoiesis-cache.timer autopoiesis-watchdog.timer"
require_contains "$SYSTEMCTL_LOG" "start autopoiesis-heartbeat.timer autopoiesis-command-executor.timer autopoiesis-updater.timer autopoiesis-cache.timer autopoiesis-watchdog.timer"

echo "Systemd unit install rendering check passed."
