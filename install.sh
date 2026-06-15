#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${AUTOPOIESIS_INSTALL_DIR:-/opt/autopoiesis-os}"
DATA_DIR="${AUTOPOIESIS_DATA_DIR:-/var/lib/autopoiesis-os}"
LOG_DIR="${AUTOPOIESIS_LOG_DIR:-/var/log/autopoiesis-os}"
USER_NAME="${AUTOPOIESIS_USER:-frame}"

SKIP_KIOSK_CONFIG=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-kiosk-config)
      SKIP_KIOSK_CONFIG=true
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

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

if [[ "$SKIP_KIOSK_CONFIG" == false ]]; then
  echo "Configuring kiosk OS..."
  "$REPO_DIR/scripts/configure-kiosk-os.sh"
else
  echo "Skipping kiosk OS configuration (--skip-kiosk-config provided)."
fi

AUTOPOIESIS_APP_DIR="$INSTALL_DIR/app" \
  AUTOPOIESIS_INSTALL_DIR="$INSTALL_DIR" \
  AUTOPOIESIS_DATA_DIR="$DATA_DIR" \
  AUTOPOIESIS_LOG_DIR="$LOG_DIR" \
  AUTOPOIESIS_USER="$USER_NAME" \
  "$INSTALL_DIR/app/scripts/install-systemd-units.sh"

echo "Installed. Next steps:"
if [[ "$SKIP_KIOSK_CONFIG" == false ]]; then
  echo "  1. Reboot the system:"
  echo "     sudo reboot"
  echo "  2. After reboot, the appliance will start automatically via enabled autopoiesis.target."
else
  echo "  1. Configure kiosk OS mode (auto-login, screen blanking):"
  echo "     sudo $INSTALL_DIR/app/scripts/configure-kiosk-os.sh"
  echo "  2. Reboot the system:"
  echo "     sudo reboot"
  echo "  3. After reboot, start the appliance:"
  echo "     sudo systemctl start autopoiesis.target"
fi

# Post-install verification
run_post_install_check() {
  echo ""
  echo "Running post-install verification..."
  if [[ -x "$INSTALL_DIR/app/scripts/diagnostics.sh" ]]; then
    "$INSTALL_DIR/app/scripts/diagnostics.sh" --quick 2>&1 | tee -a "$LOG_DIR/install-verification.log" || true
    echo "Verification log written to $LOG_DIR/install-verification.log"
    # Extract summary line
    if tail -5 "$LOG_DIR/install-verification.log" | grep -q "Summary:"; then
      tail -5 "$LOG_DIR/install-verification.log" | grep "Summary:"
    else
      echo "Verification completed (see log for details)."
    fi
  else
    echo "Verification script not found; skipping."
  fi
}
run_post_install_check