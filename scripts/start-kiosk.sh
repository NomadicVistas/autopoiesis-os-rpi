#!/usr/bin/env bash
set -euo pipefail

URL="${AUTOPOIESIS_LAUNCH_URL:-http://localhost:3030/launch}"
PROFILE_DIR="${AUTOPOIESIS_CHROMIUM_PROFILE:-/var/lib/autopoiesis-os/chromium}"

mkdir -p "$PROFILE_DIR"

CHROMIUM_BIN="$(command -v chromium-browser || command -v chromium || true)"
if [[ -z "$CHROMIUM_BIN" ]]; then
  echo "Chromium is not installed." >&2
  exit 1
fi

exec "$CHROMIUM_BIN" \
  --kiosk \
  --noerrdialogs \
  --disable-infobars \
  --disable-session-crashed-bubble \
  --autoplay-policy=no-user-gesture-required \
  --check-for-update-interval=31536000 \
  --user-data-dir="$PROFILE_DIR" \
  "$URL"
