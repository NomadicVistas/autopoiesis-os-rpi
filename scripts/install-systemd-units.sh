#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${AUTOPOIESIS_APP_DIR:-/opt/autopoiesis-os/app}"
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

install -m 0644 "$APP_DIR/services/"*.service "$SYSTEMD_DIR/"
install -m 0644 "$APP_DIR/timers/"*.timer "$SYSTEMD_DIR/"

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
