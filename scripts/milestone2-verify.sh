#!/usr/bin/env bash
set -euo pipefail

URL="${AUTOPOIESIS_LAUNCH_URL:-http://localhost:3030/launch}"
SETUP_URL="${AUTOPOIESIS_SETUP_URL:-http://localhost:3030/setup}"
LOCAL_BASE_URL="${AUTOPOIESIS_LOCAL_BASE_URL:-http://localhost:3030}"

echo "Autopoiesis OS Milestone 2 verification"
echo "Date: $(date -Is)"
echo

if ! command -v systemctl >/dev/null 2>&1; then
  echo "systemctl is required for Milestone 2 verification." >&2
  exit 1
fi

echo "1. Service status"
systemctl is-active --quiet autopoiesis-setup.service
echo "   autopoiesis-setup.service active"
systemctl is-active --quiet autopoiesis-kiosk.service
echo "   autopoiesis-kiosk.service active"
systemctl is-enabled --quiet autopoiesis-watchdog.timer
echo "   autopoiesis-watchdog.timer enabled"
"$(dirname "$0")/install-app-tree-check.sh"
"$(dirname "$0")/release-app-tree-copy-check.sh"
"$(dirname "$0")/systemd-units-install-check.sh"
"$(dirname "$0")/setup-launcher-check.sh"

echo
echo "2. Local launcher HTTP"
curl -fsS "$SETUP_URL" >/dev/null
echo "   setup UI responds at $SETUP_URL"
curl -fsSI "$URL" >/dev/null
echo "   launch route responds at $URL"
curl -fsS "$LOCAL_BASE_URL/local/frame-state" >/dev/null
echo "   local frame-state responds at $LOCAL_BASE_URL/local/frame-state"
"$(dirname "$0")/frame-state-check.sh"
curl -fsS "$LOCAL_BASE_URL/frame" >/dev/null
echo "   local frame route responds at $LOCAL_BASE_URL/frame"
AUTOPOIESIS_REQUIRE_RUNTIME_STORAGE=1 "$(dirname "$0")/runtime-storage-check.sh"
"$(dirname "$0")/stream-playback-check.sh"
"$(dirname "$0")/feed-targeting-check.sh"
"$(dirname "$0")/broadcast-command-check.sh"

echo
echo "3. Network status"
if command -v nmcli >/dev/null 2>&1; then
  nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status
else
  echo "   nmcli unavailable"
fi
"$(dirname "$0")/network-check.sh"

echo
echo "3b. Touchscreen/input"
"$(dirname "$0")/hardware-profile-fixture-check.sh"
AUTOPOIESIS_REQUIRE_SUPPORTED_HARDWARE=1 "$(dirname "$0")/hardware-profile-check.sh"
AUTOPOIESIS_REQUIRE_TOUCHSCREEN=1 "$(dirname "$0")/touchscreen-check.sh"

echo
echo "4. Kiosk process"
if pgrep -af 'chromium|chromium-browser' >/dev/null; then
  pgrep -af 'chromium|chromium-browser'
else
  echo "Chromium kiosk process not found." >&2
  exit 1
fi

AUTOPOIESIS_REQUIRE_KIOSK_PROCESS=1 "$(dirname "$0")/kiosk-check.sh"
echo
echo "4b. Appliance watchdog"
"$(dirname "$0")/systemd-timers-check.sh"
AUTOPOIESIS_REQUIRE_CLOCK_SYNC=1 "$(dirname "$0")/clock-check.sh"
"$(dirname "$0")/watchdog-check.sh"
"$(dirname "$0")/watchdog.sh"

echo
echo "5. Restart behavior"
sudo systemctl restart autopoiesis-setup.service autopoiesis-kiosk.service
sleep 5
systemctl is-active --quiet autopoiesis-setup.service
systemctl is-active --quiet autopoiesis-kiosk.service
curl -fsS "$SETUP_URL" >/dev/null
echo "   services restart cleanly and setup UI still responds"

echo
echo "6. Local health probe"
"$(dirname "$0")/health-check.sh"

echo
echo "7. Local readiness probe"
"$(dirname "$0")/readiness-check.sh"

echo
echo "8. Local admin capabilities contract"
"$(dirname "$0")/admin-capabilities-check.sh"

echo
echo "9. Admin device snapshot contract"
"$(dirname "$0")/support-bundle-check.sh"
"$(dirname "$0")/admin-device-snapshot-check.sh"

echo
echo "10. Command acknowledgement retry contract"
"$(dirname "$0")/command-ack-retry-check.sh"

echo
echo "11. Settings sync conflict contract"
"$(dirname "$0")/settings-sync-check.sh"

echo
echo "12. Local event export contract"
"$(dirname "$0")/events-export-check.sh"

echo
echo "13. Heartbeat event ingestion cursor contract"
"$(dirname "$0")/heartbeat-runner-check.sh"
"$(dirname "$0")/events-ingestion-check.sh"

echo
echo "14. Factory reset contract"
"$(dirname "$0")/factory-reset-check.sh"

echo
echo "Milestone 2 verification passed."
