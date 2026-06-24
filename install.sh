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

# Check for Chromium browser (required for kiosk)
if ! command -v chromium-browser &> /dev/null; then
  echo "Error: Chromium browser is not installed." >&2
  echo "The Autopoiesis OS appliance requires Chromium for the kiosk UI." >&2
  echo "Please install it with: sudo apt-get install -y chromium-browser" >&2
  exit 1
fi

# Check for Node.js (required for runtime)
if ! command -v node &> /dev/null; then
  echo "Error: Node.js is not installed." >&2
  echo "The Autopoiesis OS appliance requires Node.js (version >=18)." >&2
  echo "Please install it with: sudo apt-get install -y nodejs npm" >&2
  exit 1
fi

NODE_VERSION=$(node --version | cut -dv -f2)
REQUIRED_MAJOR=18
if [ "$(printf '%s\n' "$REQUIRED_MAJOR" "$NODE_VERSION" | sort -V | head -n1)" != "$REQUIRED_MAJOR" ]; then
  echo "Error: Node.js version $NODE_VERSION is too old. Required: >=$REQUIRED_MAJOR.0" >&2
  echo "Please upgrade Node.js." >&2
  exit 1
fi

# Check disk space for installation directories
check_disk_space() {
  local dir="$1"
  local min_bytes="$2"
  local check_dir="$dir"
  # If the directory doesn't exist, check its parent
  while [[ ! -e "$check_dir" && "$check_dir" != "/" ]]; do
    check_dir="$(dirname "$check_dir")"
  done
  # Now check_dir exists (at least as the root)
  local avail
  avail=$(df --output=avail -B1 "$check_dir" 2>/dev/null | tail -n1)
  if [[ -z "$avail" || "$avail" =~ [^0-9] ]]; then
    echo "Warning: Could not determine available space for $dir" >&2
    return 0  # Skip the check if we can't determine
  fi
  if (( avail < min_bytes )); then
    echo "Error: Insufficient disk space in $(df --output=target "$check_dir" | tail -n1)." >&2
    echo "  Available: $avail bytes, Required: $min_bytes bytes" >&2
    echo "  Please free up space and try again." >&2
    exit 1
  fi
}

# Require at least 1 GB free space for each of the installation directories
MIN_FREE_BYTES=1073741824  # 1 GB
check_disk_space "$INSTALL_DIR" "$MIN_FREE_BYTES"
check_disk_space "$DATA_DIR" "$MIN_FREE_BYTES"
check_disk_space "$LOG_DIR" "$MIN_FREE_BYTES"


"$REPO_DIR/scripts/ensure-appliance-user.sh"

install -d -o "$USER_NAME" -g "$USER_NAME" "$INSTALL_DIR" "$INSTALL_DIR/releases" "$DATA_DIR" "$LOG_DIR"
install -d -o "$USER_NAME" -g "$USER_NAME" "$INSTALL_DIR/cache/artworks" "$INSTALL_DIR/cache/metadata" "$INSTALL_DIR/cache/fallback"

"$REPO_DIR/scripts/install-app-tree.sh" "$REPO_DIR" "$INSTALL_DIR/current" "$USER_NAME" "$USER_NAME"

ln -sfn "$INSTALL_DIR/current" "$INSTALL_DIR/app"

"$INSTALL_DIR/app/scripts/bootstrap.sh"
# Check that the SQLite3 native module can be loaded, and attempt to fix if needed
if ! node -e "require('better-sqlite3')" 2>/dev/null; then
  echo "Warning: SQLite3 native module failed to load. Attempting to fix by running 'npm rebuild' in /app..." >&2
  if cd "$INSTALL_DIR/app" && npm rebuild --silent 2>/dev/null; then
    echo "SQLite3 native module rebuilt successfully." >&2
    # Verify the fix worked
    if node -e "require('better-sqlite3')" 2>/dev/null; then
      echo "SQLite3 native module now loads correctly." >&2
    else
      echo "Warning: SQLite3 native module still fails to load after rebuild." >&2
    fi
  else
    echo "Warning: Failed to rebuild SQLite3 native module. Manual intervention may be required." >&2
    echo "You can try running: cd /opt/autopoiesis-os/app && npm rebuild" >&2
  fi
fi

if [[ "$SKIP_KIOSK_CONFIG" == false ]]; then
  echo "Configuring kiosk OS..."
  "$REPO_DIR/scripts/configure-kiosk-os.sh"
  
  # Verify kiosk OS configuration
  verify_kiosk_os_config() {
    echo ""
    echo "Verifying kiosk OS configuration..."
    
    local checks_passed=0
    local checks_failed=0
    
    # 1. Check graphical.target is set as default
    if systemctl get-default | grep -q "graphical.target"; then
      echo "  ✓ graphical.target is set as default"
      ((checks_passed++))
    else
      echo "  ✗ graphical.target is NOT set as default" >&2
      echo "    Current: $(systemctl get-default)" >&2
      ((checks_failed++))
    fi
    
    # 2. Check auto-login configuration
    local autologin_ok=0
    
    # Check lightdm
    if [[ -f /etc/lightdm/lightdm.conf ]] && grep -q "^autologin-user=$USER_NAME" /etc/lightdm/lightdm.conf; then
      echo "  ✓ lightdm autologin configured for user '$USER_NAME'"
      ((checks_passed++))
      autologin_ok=1
    fi
    
    # Check gdm3
    if [[ -f /etc/gdm3/custom.conf ]] && grep -q "^AutomaticLoginEnable=true" /etc/gdm3/custom.conf && grep -q "^AutomaticLogin=$USER_NAME" /etc/gdm3/custom.conf; then
      echo "  ✓ gdm3 autologin configured for user '$USER_NAME'"
      ((checks_passed++))
      autologin_ok=1
    fi
    
    # Check getty override (for raspi-config text autologin, though we use graphical)
    local getty_override="/etc/systemd/system/getty@tty1.service.d/autologin.conf"
    if [[ -f "$getty_override" ]] && grep -q "--autologin $USER_NAME" "$getty_override"; then
      echo "  ✓ getty autologin configured for user '$USER_NAME'"
      ((checks_passed++))
      autologin_ok=1
    fi
    
    if [[ $autologin_ok -eq 0 ]]; then
      echo "  ✗ autologin NOT configured for user '$USER_NAME'" >&2
      echo "    Checked lightdm, gdm3, and getty override" >&2
      ((checks_failed++))
    fi
    
    # 3. Check screen blanking disabled
    local blanking_ok=0
    
    # Check console blanking
    if [[ -f /etc/kbd/config ]] && grep -q "^BLANK_TIME=0" /etc/kbd/config; then
      echo "  ✓ console blanking disabled (BLANK_TIME=0 in /etc/kbd/config)"
      ((checks_passed++))
      blanking_ok=1
    elif command -v raspi-config >/dev/null 2>&1 && [[ "$(raspi-config nonint get_blanking 2>/dev/null || echo "1")" == "0" ]]; then
      echo "  ✓ console blanking disabled via raspi-config"
      ((checks_passed++))
      blanking_ok=1
    else
      echo "  ✗ console blanking may NOT be disabled" >&2
      echo "    Checked /etc/kbd/config and raspi-config" >&2
    fi
    
    # Check X11 screen blanking disable
    local x_dpms_file="/etc/X11/Xsession.d/99-autopoiesis-disable-blanking"
    if [[ -f "$x_dpms_file" ]]; then
      local x_dpms_content
      x_dpms_content="$(cat <<'EOF'
# Autopoiesis kiosk: disable X11 screen blanking and DPMS
xset s off         2>/dev/null || true
xset -dpms         2>/dev/null || true
xset s noblank     2>/dev/null || true
EOF
)"
      if diff -q <(echo "$x_dpms_content") "$x_dpms_file" >/dev/null; then
        echo "  ✓ X11 blanking drop-in present and correct at $x_dpms_file"
        ((checks_passed++))
        blanking_ok=1
      else
        echo "  ✗ X11 blanking drop-in at $x_dpms_file has incorrect content" >&2
        ((checks_failed++))
      fi
    else
      echo "  ✗ X11 blanking drop-in NOT found at $x_dpms_file" >&2
      ((checks_failed++))
    fi
    
    if [[ $blanking_ok -eq 0 ]]; then
      ((checks_failed++)) # Count as failed if either console or X11 check failed
    fi
    
    # 4. Check cursor hiding (unclutter installed)
    if command -v unclutter >/dev/null 2>&1; then
      echo "  ✓ unclutter installed for cursor hiding"
      ((checks_passed++))
    else
      echo "  ✗ unclutter NOT installed - cursor may be visible in kiosk mode" >&2
      ((checks_failed++))
    fi
    
    echo ""
    if [[ $checks_failed -eq 0 ]]; then
      echo "Kiosk OS configuration verification: ALL CHECKS PASSED ($checks_passed checks)"
      return 0
    else
      echo "Kiosk OS configuration verification: $checks_failed FAILED, $checks_passed passed" >&2
      return 1
    fi
  }
  
  if ! verify_kiosk_os_config; then
    echo ""
    echo "WARNING: Kiosk OS configuration verification failed!" >&2
    echo "The appliance may not start correctly in kiosk mode after reboot." >&2
    echo "You can manually run verification with:" >&2
    echo "  sudo $REPO_DIR/scripts/configure-kiosk-os.sh && /opt/autopoiesis-os/app/scripts/diagnostics.sh" >&2
    echo ""
    # Don't fail the installation - continue but warn the user
  fi
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