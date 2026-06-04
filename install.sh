#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${AUTOPOIESIS_INSTALL_DIR:-/opt/autopoiesis-os}"
DATA_DIR="${AUTOPOIESIS_DATA_DIR:-/var/lib/autopoiesis-os}"
LOG_DIR="${AUTOPOIESIS_LOG_DIR:-/var/log/autopoiesis-os}"
USER_NAME="${AUTOPOIESIS_USER:-frame}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run with sudo: sudo ./install.sh" >&2
  exit 1
fi

echo "Installing Autopoiesis OS appliance layer..."

install -d -o "$USER_NAME" -g "$USER_NAME" "$INSTALL_DIR" "$INSTALL_DIR/releases" "$DATA_DIR" "$LOG_DIR"
install -d -o "$USER_NAME" -g "$USER_NAME" "$INSTALL_DIR/cache/artworks" "$INSTALL_DIR/cache/metadata" "$INSTALL_DIR/cache/fallback"

rsync -a --delete \
  --exclude '.git' \
  --exclude 'logs/*' \
  --exclude 'node_modules' \
  "$REPO_DIR/" "$INSTALL_DIR/current/"

ln -sfn "$INSTALL_DIR/current" "$INSTALL_DIR/app"

"$INSTALL_DIR/app/scripts/bootstrap.sh"

install -m 0644 "$INSTALL_DIR/app/services/"*.service /etc/systemd/system/
install -m 0644 "$INSTALL_DIR/app/timers/"*.timer /etc/systemd/system/

systemctl daemon-reload
systemctl enable autopoiesis-setup.service
systemctl enable autopoiesis-kiosk.service
systemctl enable autopoiesis-heartbeat.timer
systemctl enable autopoiesis-updater.timer
systemctl enable autopoiesis-cache.timer

echo "Installed. Start now with:"
echo "  sudo systemctl start autopoiesis-setup.service autopoiesis-kiosk.service"
