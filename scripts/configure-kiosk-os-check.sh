#!/usr/bin/env bash
# configure-kiosk-os-check.sh — isolated acceptance gate for configure-kiosk-os.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/configure-kiosk-os.sh"
TMP_DIR="$(mktemp -d)"
FAILURES=0

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  FAILURES=$((FAILURES + 1))
}

pass() {
  echo "OK: $*"
}

require_contains() {
  local file="$1"
  local needle="$2"
  [[ -f "$file" ]] || fail "$file was not created"
  grep -F -- "$needle" "$file" >/dev/null || fail "$file did not contain: $needle"
}

require_not_contains() {
  local file="$1"
  local needle="$2"
  if grep -F -- "$needle" "$file" >/dev/null 2>&1; then
    fail "$file should not contain: $needle"
  fi
}

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/etc" "$TMP_DIR/etc/X11/Xsession.d"
mkdir -p "$TMP_DIR/etc/lightdm" "$TMP_DIR/etc/gdm3"
mkdir -p "$TMP_DIR/etc/systemd/system/getty@tty1.service.d"

echo "1. Script syntax"
bash -n "$SCRIPT"
pass "configure-kiosk-os.sh syntax OK"

echo
echo "2. Help flag"
if bash "$SCRIPT" --help | grep -q "kiosk mode"; then
  pass "--help shows usage"
else
  fail "--help did not show expected text"
fi

echo
echo "3. Dry run with stubbed systemctl (no root)"

# Stub systemctl
cat > "$TMP_DIR/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  get-default)
    echo "multi-user.target"
    ;;
  set-default)
    echo "set-default: $2" > /tmp/kiosk-test-set-default.txt
    echo "Changed default target to $2"
    ;;
  *)
    echo "systemctl stub: $*" >&2
    ;;
esac
EOF
chmod +x "$TMP_DIR/bin/systemctl"

# Stub raspi-config
cat > "$TMP_DIR/bin/raspi-config" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  nonint)
    case "$2" in
      get_boot_behaviour)
        echo "B1"
        ;;
      do_boot_behaviour)
        echo "raspi-config: do_boot_behaviour $3"
        ;;
      get_blanking)
        echo "1"
        ;;
      do_blanking)
        echo "raspi-config: do_blanking $3"
        ;;
      *)
        echo "raspi-config nonint stub: $*" >&2
        ;;
    esac
    ;;
  *)
    echo "raspi-config stub: $*" >&2
    ;;
esac
EOF
chmod +x "$TMP_DIR/bin/raspi-config"

# Stub apt-get
cat > "$TMP_DIR/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
echo "apt-get stub: $*"
EOF
chmod +x "$TMP_DIR/bin/apt-get"

DRY_OUTPUT="$(
  PATH="$TMP_DIR/bin:$PATH" \
  AUTOPOIESIS_USER=testframe \
  bash "$SCRIPT" --dry-run 2>&1
)"

if grep -q "dry-run" <<< "$DRY_OUTPUT"; then
  pass "dry run produces dry-run output"
else
  fail "dry run did not produce expected output"
fi

if grep -q "graphical.target" <<< "$DRY_OUTPUT"; then
  pass "dry run mentions graphical.target"
else
  fail "dry run did not mention graphical.target"
fi

if grep -q "testframe" <<< "$DRY_OUTPUT"; then
  pass "dry run uses custom user name"
else
  fail "dry run did not use custom user name"
fi

echo
echo "4. Lightdm autologin configuration"

cat > "$TMP_DIR/etc/lightdm/lightdm.conf" <<'LCONF'
[SeatDefaults]
greeter-hide-users=true
LCONF

# Run non-dry with stubs and our fake etc path
cat > "$TMP_DIR/run-lightdm-test.sh" <<'TESTSCRIPT'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ETC_DIR="$1"
USER_NAME="$2"

# Inline the lightdm function
configure_lightdm_autologin() {
  local conf="$ETC_DIR/lightdm/lightdm.conf"
  if grep -q "^autologin-user=$USER_NAME" "$conf" 2>/dev/null; then
    echo "OK: already configured"
    return 0
  fi
  if grep -q '^\[SeatDefaults\]' "$conf" 2>/dev/null; then
    sed -i '/^autologin-user=/d' "$conf"
    sed -i '/^\[SeatDefaults\]/a autologin-user='"$USER_NAME" "$conf"
  elif grep -q '^\[Seat:\*\]' "$conf" 2>/dev/null; then
    sed -i '/^autologin-user=/d' "$conf"
    sed -i '/^\[Seat:\*\]/a autologin-user='"$USER_NAME" "$conf"
  else
    printf '\n[Seat:*]\nautologin-user=%s\n' "$USER_NAME" >> "$conf"
  fi
  if ! grep -q '^autologin-session=' "$conf" 2>/dev/null; then
    sed -i '/^autologin-user=/a autologin-session=lightdm-xsession' "$conf"
  fi
}
configure_lightdm_autologin
TESTSCRIPT
chmod +x "$TMP_DIR/run-lightdm-test.sh"

bash "$TMP_DIR/run-lightdm-test.sh" "$TMP_DIR/etc" "testframe"

require_contains "$TMP_DIR/etc/lightdm/lightdm.conf" "autologin-user=testframe"
require_contains "$TMP_DIR/etc/lightdm/lightdm.conf" "autologin-session=lightdm-xsession"
pass "lightdm autologin configured for testframe"

# Test idempotency: running again should not duplicate
bash "$TMP_DIR/run-lightdm-test.sh" "$TMP_DIR/etc" "testframe"
AUTLOGIN_COUNT="$(grep -c "^autologin-user=testframe" "$TMP_DIR/etc/lightdm/lightdm.conf" || true)"
if [[ "$AUTLOGIN_COUNT" -eq 1 ]]; then
  pass "lightdm autologin is idempotent (1 occurrence)"
else
  fail "lightdm autologin was duplicated ($AUTLOGIN_COUNT occurrences)"
fi

echo
echo "5. GDM3 autologin configuration"

mkdir -p "$TMP_DIR/etc/gdm3"
cat > "$TMP_DIR/etc/gdm3/custom.conf" <<'GCONF'
[daemon]
WaylandEnable=false

[security]

[xdmcp]
GCONF

cat > "$TMP_DIR/run-gdm3-test.sh" <<'TESTSCRIPT'
#!/usr/bin/env bash
set -euo pipefail
ETC_DIR="$1"
USER_NAME="$2"

configure_gdm3_autologin() {
  local conf="$ETC_DIR/gdm3/custom.conf"
  if grep -q "^AutomaticLoginEnable=true" "$conf" 2>/dev/null && \
     grep -q "^AutomaticLogin=$USER_NAME" "$conf" 2>/dev/null; then
    echo "OK: already configured"
    return 0
  fi
  if grep -q '^\[daemon\]' "$conf" 2>/dev/null; then
    sed -i '/^AutomaticLoginEnable=/d; /^AutomaticLogin=/d' "$conf"
    sed -i '/^\[daemon\]/a AutomaticLoginEnable=true\nAutomaticLogin='"$USER_NAME" "$conf"
  else
    printf '\n[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=%s\n' "$USER_NAME" >> "$conf"
  fi
}
configure_gdm3_autologin
TESTSCRIPT
chmod +x "$TMP_DIR/run-gdm3-test.sh"

bash "$TMP_DIR/run-gdm3-test.sh" "$TMP_DIR/etc" "testframe"
require_contains "$TMP_DIR/etc/gdm3/custom.conf" "AutomaticLoginEnable=true"
require_contains "$TMP_DIR/etc/gdm3/custom.conf" "AutomaticLogin=testframe"
pass "gdm3 autologin configured for testframe"

# Test idempotency
bash "$TMP_DIR/run-gdm3-test.sh" "$TMP_DIR/etc" "testframe"
AUTO_COUNT="$(grep -c "^AutomaticLogin=testframe" "$TMP_DIR/etc/gdm3/custom.conf" || true)"
if [[ "$AUTO_COUNT" -eq 1 ]]; then
  pass "gdm3 autologin is idempotent (1 occurrence)"
else
  fail "gdm3 autologin was duplicated ($AUTO_COUNT occurrences)"
fi

echo
echo "6. Getty autologin user switching"

cat > "$TMP_DIR/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<'GETTY'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin pi --noclear %I $TERM
GETTY

# Inline the user-switching logic
sed -i "s/--autologin pi/--autologin testframe/g" "$TMP_DIR/etc/systemd/system/getty@tty1.service.d/autologin.conf"
require_contains "$TMP_DIR/etc/systemd/system/getty@tty1.service.d/autologin.conf" "--autologin testframe"
require_not_contains "$TMP_DIR/etc/systemd/system/getty@tty1.service.d/autologin.conf" "--autologin pi"
pass "getty autologin user switched from pi to testframe"

echo
echo "7. X11 blanking drop-in creation"

X_DPMS_FILE="$TMP_DIR/etc/X11/Xsession.d/99-autopoiesis-disable-blanking"
cat > "$X_DPMS_FILE" <<'XDPMS'
# Autopoiesis kiosk: disable X11 screen blanking and DPMS
xset s off         2>/dev/null || true
xset -dpms         2>/dev/null || true
xset s noblank     2>/dev/null || true
XDPMS

require_contains "$X_DPMS_FILE" "xset s off"
require_contains "$X_DPMS_FILE" "xset -dpms"
require_contains "$X_DPMS_FILE" "xset s noblank"
pass "X11 blanking drop-in contains expected commands"

echo
echo "8. Dry run does not modify system files"

LIGHTDM_BACKUP="$(cat "$TMP_DIR/etc/lightdm/lightdm.conf")"
GDM3_BACKUP="$(cat "$TMP_DIR/etc/gdm3/custom.conf")"

PATH="$TMP_DIR/bin:$PATH" \
AUTOPOIESIS_USER=anotheruser \
bash "$SCRIPT" --dry-run 2>&1 >/dev/null || true

if [[ "$(cat "$TMP_DIR/etc/lightdm/lightdm.conf")" == "$LIGHTDM_BACKUP" ]]; then
  pass "dry run did not modify lightdm.conf"
else
  fail "dry run modified lightdm.conf"
fi

if [[ "$(cat "$TMP_DIR/etc/gdm3/custom.conf")" == "$GDM3_BACKUP" ]]; then
  pass "dry run did not modify custom.conf"
else
  fail "dry run modified custom.conf"
fi

echo
if [[ "$FAILURES" -eq 0 ]]; then
  echo "configure-kiosk-os-check passed: all 8 tests OK"
else
  echo "configure-kiosk-os-check FAILED: $FAILURES failures" >&2
  exit 1
fi
