#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${AUTOPOIESIS_APP_DIR:-/opt/autopoiesis-os/app}"
LOG_DIR="${AUTOPOIESIS_LOG_DIR:-/var/log/autopoiesis-os}"

if [[ ! -d "$APP_DIR/.git" ]]; then
  echo "$(date -Is) updater skipped: installed app is not a git checkout" >> "$LOG_DIR/update.log"
  exit 0
fi

cd "$APP_DIR"
git fetch origin main
if git diff --quiet HEAD origin/main; then
  echo "$(date -Is) updater: already current" >> "$LOG_DIR/update.log"
  exit 0
fi

git pull --ff-only origin main
"$APP_DIR/scripts/bootstrap.sh"
if [[ "$(id -u)" -eq 0 ]]; then
  "$APP_DIR/scripts/install-systemd-units.sh"
fi
systemctl restart autopoiesis-setup.service autopoiesis-kiosk.service
echo "$(date -Is) updater: updated to $(git rev-parse --short HEAD)" >> "$LOG_DIR/update.log"
