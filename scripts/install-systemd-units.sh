#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${AUTOPOIESIS_APP_DIR:-/opt/autopoiesis-os/app}"
INSTALL_DIR="${AUTOPOIESIS_INSTALL_DIR:-/opt/autopoiesis-os}"
DATA_DIR="${AUTOPOIESIS_DATA_DIR:-/var/lib/autopoiesis-os}"
LOG_DIR="${AUTOPOIESIS_LOG_DIR:-/var/log/autopoiesis-os}"
USER_NAME="${AUTOPOIESIS_USER:-frame}"
USER_HOME="${AUTOPOIESIS_USER_HOME:-}"
SYSTEMD_DIR="${AUTOPOIESIS_SYSTEMD_DIR:-/etc/systemd/system}"
START_TIMERS="${AUTOPOIESIS_START_TIMERS:-1}"
SYSTEMCTL="${AUTOPOIESIS_SYSTEMCTL_BIN:-systemctl}"
ALLOW_NON_ROOT="${AUTOPOIESIS_ALLOW_NON_ROOT_SYSTEMD_INSTALL:-0}"

if [[ "$(id -u)" -ne 0 && "$ALLOW_NON_ROOT" != "1" ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

if [[ ! -d "$APP_DIR/services" || ! -d "$APP_DIR/timers" ]]; then
  echo "Missing systemd unit directories under $APP_DIR" >&2
  exit 2
fi

trim_trailing_slash() {
  local value="$1"
  value="${value%/}"
  printf '%s' "${value:-/}"
}

sed_escape() {
  printf '%s' "$1" | sed 's/[&#\\]/\\&/g'
}

render_unit() {
  local source="$1"
  local target="$2"
  sed \
    -e "s#/opt/autopoiesis-os/app#$(sed_escape "$APP_DIR")#g" \
    -e "s#/opt/autopoiesis-os#$(sed_escape "$INSTALL_DIR")#g" \
    -e "s#/var/lib/autopoiesis-os#$(sed_escape "$DATA_DIR")#g" \
    -e "s#/var/log/autopoiesis-os#$(sed_escape "$LOG_DIR")#g" \
    -e "s#/home/frame#$(sed_escape "$USER_HOME")#g" \
    -e "s#AUTOPOIESIS_USER=frame#AUTOPOIESIS_USER=$(sed_escape "$USER_NAME")#g" \
    -e "s#^User=frame\$#User=$(sed_escape "$USER_NAME")#" \
    -e "s#^Group=frame\$#Group=$(sed_escape "$USER_NAME")#" \
    "$source" >"$target"
  chmod 0644 "$target"
}

APP_DIR="$(trim_trailing_slash "$APP_DIR")"
INSTALL_DIR="$(trim_trailing_slash "$INSTALL_DIR")"
DATA_DIR="$(trim_trailing_slash "$DATA_DIR")"
LOG_DIR="$(trim_trailing_slash "$LOG_DIR")"
if [[ -z "$USER_HOME" ]]; then
  USER_HOME="$(getent passwd "$USER_NAME" 2>/dev/null | cut -d: -f6 || true)"
fi
USER_HOME="${USER_HOME:-/home/$USER_NAME}"

install -d -m 0755 "$SYSTEMD_DIR"

for unit in "$APP_DIR/services/"*.service; do
  render_unit "$unit" "$SYSTEMD_DIR/$(basename "$unit")"
done

for timer in "$APP_DIR/timers/"*.timer; do
  install -m 0644 "$timer" "$SYSTEMD_DIR/"
done

"$SYSTEMCTL" daemon-reload

"$SYSTEMCTL" enable \
  autopoiesis-setup.service \
  autopoiesis-kiosk.service \
  autopoiesis-heartbeat.timer \
  autopoiesis-command-executor.timer \
  autopoiesis-updater.timer \
  autopoiesis-cache.timer \
  autopoiesis-watchdog.timer

if [[ "$START_TIMERS" == "1" ]]; then
  "$SYSTEMCTL" start \
    autopoiesis-heartbeat.timer \
    autopoiesis-command-executor.timer \
    autopoiesis-updater.timer \
    autopoiesis-cache.timer \
    autopoiesis-watchdog.timer
fi

# Install logrotate configuration with custom paths
LOGROTATE_SRC="$APP_DIR/config/autopoiesis-os.logrotate"
LOGROTATE_DST="/etc/logrotate.d/autopoiesis-os"
if [[ -f "$LOGROTATE_SRC" ]]; then
  sed \
    -e "s#/var/log/autopoiesis-os#$(sed_escape "$LOG_DIR")#g" \
    "$LOGROTATE_SRC" >"$LOGROTATE_DST"
  chmod 0644 "$LOGROTATE_DST"
fi
