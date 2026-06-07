#!/usr/bin/env bash
# configure-kiosk-os.sh — configure Raspberry Pi OS for Autopoiesis kiosk mode
#
# Handles OS-level setup that install.sh doesn't cover:
#   1. Enable graphical.target as default systemd target
#   2. Enable auto-login for the appliance user
#   3. Disable console and X11 screen blanking
#   4. Hide the mouse cursor via unclutter (if available)
#
# Usage:
#   sudo scripts/configure-kiosk-os.sh [--dry-run] [--user=frame]
#
# Safe to re-run. All changes are idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${AUTOPOIESIS_APP_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
USER_NAME="${AUTOPOIESIS_USER:-frame}"
DRY_RUN=0
LOG_TAG="configure-kiosk-os"

for arg in "$@"; do
  case "$arg" in
    --dry-run|-n)
      DRY_RUN=1
      ;;
    --user=*)
      USER_NAME="${arg#--user=}"
      ;;
    -h|--help)
      cat <<'EOF'
Usage: sudo scripts/configure-kiosk-os.sh [--dry-run] [--user=USERNAME]

Configure Raspberry Pi OS for kiosk mode:
  - Enable graphical.target
  - Enable auto-login for the appliance user
  - Disable screen blanking (console + X11)
  - Install unclutter for cursor hiding

Options:
  --dry-run         Show what would be changed without modifying anything
  --user=NAME       Appliance user (default: frame)
  -h, --help        Show this help
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

log() {
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[dry-run] $*"
  else
    echo "$*"
  fi
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run with sudo: sudo $0" >&2
    exit 1
  fi
}

run_cmd() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log "would run: $*"
  else
    "$@"
  fi
}

write_file() {
  local target="$1"
  local content="$2"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "would write: $target"
    log "  content: $(echo "$content" | head -3)"
  else
    printf '%s\n' "$content" > "$target"
  fi
}

append_unless_present() {
  local file="$1"
  local line="$2"
  if [[ ! -f "$file" ]]; then
    write_file "$file" "$line"
    return
  fi
  if grep -qF "$line" "$file" 2>/dev/null; then
    return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    log "would append to $file: $line"
  else
    printf '%s\n' "$line" >> "$file"
  fi
}

# ─── 1. Enable graphical.target ─────────────────────────────────────────────

configure_graphical_target() {
  local current_target
  current_target="$(systemctl get-default 2>/dev/null || echo "unknown")"

  if [[ "$current_target" == "graphical.target" ]]; then
    log "OK: graphical.target is already the default"
    return 0
  fi

  log "Current default target: $current_target"
  log "Setting graphical.target as default"
  run_cmd systemctl set-default graphical.target
}

# ─── 2. Enable auto-login ───────────────────────────────────────────────────

configure_autologin() {
  local autologin_configured=0

  # Method 1: raspi-config (Raspberry Pi OS standard)
  if command -v raspi-config >/dev/null 2>&1; then
    local current_boot_behaviour
    current_boot_behaviour="$(raspi-config nonint get_boot_behaviour 2>/dev/null || echo "unknown")"

    # B2 = graphical autologin, B4 = text autologin
    # We want B2 (graphical autologin with X)
    if [[ "$current_boot_behaviour" == "B2" ]]; then
      log "OK: raspi-config autologin already enabled (B2 graphical autologin)"
      autologin_configured=1
    else
      log "raspi-config boot behaviour: $current_boot_behaviour"
      log "Enabling graphical autologin for user '$USER_NAME' via raspi-config"
      run_cmd raspi-config nonint do_boot_behaviour B2

      # raspi-config sets autologin for the default 'pi' user;
      # we need to switch it to the appliance user
      configure_autologin_user
      autologin_configured=1
    fi
  fi

  # Method 2: lightdm (Debian/Raspberry Pi OS Bullseye and earlier)
  if [[ "$autologin_configured" == "0" ]] && [[ -f /etc/lightdm/lightdm.conf ]]; then
    configure_lightdm_autologin
    autologin_configured=1
  fi

  # Method 3: gdm3 (Debian Bookworm with GNOME)
  if [[ "$autologin_configured" == "0" ]] && [[ -f /etc/gdm3/custom.conf ]]; then
    configure_gdm3_autologin
    autologin_configured=1
  fi

  if [[ "$autologin_configured" == "0" ]]; then
    log "WARN: Could not detect display manager for auto-login configuration"
    log "      Manual configuration may be required for graphical auto-login"
  fi
}

configure_autologin_user() {
  # After raspi-config enables autologin, switch the user from 'pi' to the
  # appliance user.  Handles lightdm, gdm3, and the getty override.

  # Getty autologin (console auto-login used by raspi-config B4)
  local getty_override="/etc/systemd/system/getty@tty1.service.d/autologin.conf"
  if [[ -f "$getty_override" ]]; then
    if grep -q -- '--autologin.*\bpi\b' "$getty_override" 2>/dev/null; then
      log "Switching getty autologin from 'pi' to '$USER_NAME'"
      if [[ "$DRY_RUN" != "1" ]]; then
        sed -i "s/--autologin pi/--autologin $USER_NAME/g" "$getty_override"
      fi
    elif grep -q -- "--autologin.*$USER_NAME" "$getty_override" 2>/dev/null; then
      log "OK: getty autologin already configured for '$USER_NAME'"
    fi
  fi

  # Lightdm autologin-user
  if [[ -f /etc/lightdm/lightdm.conf ]]; then
    if grep -q "autologin-user=pi" /etc/lightdm/lightdm.conf 2>/dev/null; then
      log "Switching lightdm autologin from 'pi' to '$USER_NAME'"
      if [[ "$DRY_RUN" != "1" ]]; then
        sed -i "s/^autologin-user=pi/autologin-user=$USER_NAME/" /etc/lightdm/lightdm.conf
      fi
    fi
  fi
}

configure_lightdm_autologin() {
  local conf="/etc/lightdm/lightdm.conf"

  if grep -q "^autologin-user=$USER_NAME" "$conf" 2>/dev/null; then
    log "OK: lightdm autologin already configured for '$USER_NAME'"
    return 0
  fi

  log "Configuring lightdm autologin for '$USER_NAME'"

  if [[ "$DRY_RUN" != "1" ]]; then
    # Ensure [SeatDefaults] or [Seat:*] section exists with autologin-user
    if grep -q '^\[Seat:\*\]' "$conf" 2>/dev/null; then
      # Remove any existing autologin-user line and add ours
      sed -i '/^autologin-user=/d' "$conf"
      sed -i '/^\[Seat:\*\]/a autologin-user='"$USER_NAME" "$conf"
    elif grep -q '^\[SeatDefaults\]' "$conf" 2>/dev/null; then
      sed -i '/^autologin-user=/d' "$conf"
      sed -i '/^\[SeatDefaults\]/a autologin-user='"$USER_NAME" "$conf"
    else
      # Add section and setting
      printf '\n[Seat:*]\nautologin-user=%s\n' "$USER_NAME" >> "$conf"
    fi

    # Also ensure autologin-session is set
    if ! grep -q '^autologin-session=' "$conf" 2>/dev/null; then
      sed -i '/^autologin-user=/a autologin-session=lightdm-xsession' "$conf"
    fi
  else
    log "would configure $conf with autologin-user=$USER_NAME"
  fi
}

configure_gdm3_autologin() {
  local conf="/etc/gdm3/custom.conf"

  if grep -q "^AutomaticLoginEnable=true" "$conf" 2>/dev/null && \
     grep -q "^AutomaticLogin=$USER_NAME" "$conf" 2>/dev/null; then
    log "OK: gdm3 autologin already configured for '$USER_NAME'"
    return 0
  fi

  log "Configuring gdm3 autologin for '$USER_NAME'"

  if [[ "$DRY_RUN" != "1" ]]; then
    # Ensure [daemon] section has AutomaticLogin settings
    if grep -q '^\[daemon\]' "$conf" 2>/dev/null; then
      # Remove existing lines and add ours
      sed -i '/^AutomaticLoginEnable=/d; /^AutomaticLogin=/d' "$conf"
      sed -i '/^\[daemon\]/a AutomaticLoginEnable=true\nAutomaticLogin='"$USER_NAME" "$conf"
    else
      printf '\n[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=%s\n' "$USER_NAME" >> "$conf"
    fi
  else
    log "would configure $conf with AutomaticLogin=$USER_NAME"
  fi
}

# ─── 3. Disable screen blanking ─────────────────────────────────────────────

configure_screen_blanking() {
  # Console blanking: kernel parameter + kbd config
  local console_blank_ok=0

  # Method 1: raspi-config (standard on Raspberry Pi OS)
  if command -v raspi-config >/dev/null 2>&1; then
    local current_blanking
    current_blanking="$(raspi-config nonint get_blanking 2>/dev/null || echo "unknown")"

    if [[ "$current_blanking" == "0" ]]; then
      log "OK: raspi-config screen blanking already disabled"
      console_blank_ok=1
    else
      log "Disabling screen blanking via raspi-config"
      run_cmd raspi-config nonint do_blanking 0
      console_blank_ok=1
    fi
  fi

  # Method 2: /etc/kbd/config (Debian console blanking)
  if [[ "$console_blank_ok" == "0" ]] && [[ -f /etc/kbd/config ]]; then
    if grep -q '^BLANK_TIME=0' /etc/kbd/config 2>/dev/null; then
      log "OK: kbd console blanking already disabled"
      console_blank_ok=1
    else
      log "Disabling console blanking in /etc/kbd/config"
      if [[ "$DRY_RUN" != "1" ]]; then
        sed -i 's/^BLANK_TIME=.*/BLANK_TIME=0/' /etc/kbd/config
      fi
    fi
  fi

  # X11 DPMS and screensaver: via Xsession.d drop-in
  local x_dpms_file="/etc/X11/Xsession.d/99-autopoiesis-disable-blanking"
  local x_dpms_content
  x_dpms_content="$(cat <<'XDPMS'
# Autopoiesis kiosk: disable X11 screen blanking and DPMS
xset s off         2>/dev/null || true
xset -dpms         2>/dev/null || true
xset s noblank     2>/dev/null || true
XDPMS
)"

  if [[ -f "$x_dpms_file" ]]; then
    log "OK: X11 blanking drop-in already present at $x_dpms_file"
  else
    log "Creating X11 blanking disable drop-in at $x_dpms_file"
    write_file "$x_dpms_file" "$x_dpms_content"
    if [[ "$DRY_RUN" != "1" ]]; then
      chmod 0644 "$x_dpms_file"
    fi
  fi
}

# ─── 4. Cursor hiding ───────────────────────────────────────────────────────

configure_cursor_hiding() {
  # Chromium --kiosk mode hides the cursor within the browser,
  # but the desktop cursor is still visible on the frame between restarts
  # or if the window loses focus.

  if command -v unclutter >/dev/null 2>&1; then
    log "OK: unclutter is installed for cursor hiding"
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    log "Installing unclutter for cursor hiding"
    if [[ "$DRY_RUN" != "1" ]]; then
      apt-get update -qq && apt-get install -y -qq unclutter 2>/dev/null || {
        log "WARN: unclutter installation failed; cursor may be visible in kiosk mode"
      }
    fi
  else
    log "WARN: apt-get not found; install unclutter manually for cursor hiding"
  fi
}

# ─── main ────────────────────────────────────────────────────────────────────

if [[ "$DRY_RUN" != "1" ]]; then
  require_root
fi

echo "Configuring Raspberry Pi OS for Autopoiesis kiosk mode..."
echo "User: $USER_NAME"
echo "Dry run: $DRY_RUN"
echo

configure_graphical_target
echo

configure_autologin
echo

configure_screen_blanking
echo

configure_cursor_hiding
echo

if [[ "$DRY_RUN" == "1" ]]; then
  echo "Dry run complete. No changes were made."
else
  echo "Kiosk OS configuration complete."
  echo "Reboot to apply: sudo reboot"
fi
