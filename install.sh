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

"$REPO_DIR/scripts/preflight.sh" --install
"$REPO_DIR/scripts/ensure-appliance-user.sh"

install -d -o "$USER_NAME" -g "$USER_NAME" "$INSTALL_DIR" "$INSTALL_DIR/releases" "$DATA_DIR" "$LOG_DIR"
install -d -o "$USER_NAME" -g "$USER_NAME" "$INSTALL_DIR/cache/artworks" "$INSTALL_DIR/cache/metadata" "$INSTALL_DIR/cache/fallback"

"$REPO_DIR/scripts/install-app-tree.sh" "$REPO_DIR" "$INSTALL_DIR/current" "$USER_NAME" "$USER_NAME"

ln -sfn "$INSTALL_DIR/current" "$INSTALL_DIR/app"

"$INSTALL_DIR/app/scripts/bootstrap.sh"

AUTOPOIESIS_APP_DIR="$INSTALL_DIR/app" \
  AUTOPOIESIS_INSTALL_DIR="$INSTALL_DIR" \
  AUTOPOIESIS_DATA_DIR="$DATA_DIR" \
  AUTOPOIESIS_LOG_DIR="$LOG_DIR" \
  AUTOPOIESIS_USER="$USER_NAME" \
  "$INSTALL_DIR/app/scripts/install-systemd-units.sh"

echo "Installed. Next steps:"
echo "  1. Configure kiosk OS mode (auto-login, screen blanking):"
echo "     sudo $INSTALL_DIR/app/scripts/configure-kiosk-os.sh"
echo "  2. Start the kiosk services:"
echo "     sudo systemctl start autopoiesis-setup.service autopoiesis-kiosk.service"
