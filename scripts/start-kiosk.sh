#!/usr/bin/env bash
set -euo pipefail

URL="${AUTOPOIESIS_LAUNCH_URL:-http://localhost:3030/launch}"
PROFILE_DIR="${AUTOPOIESIS_CHROMIUM_PROFILE:-/var/lib/autopoiesis-os/chromium}"
WAIT_SECONDS="${AUTOPOIESIS_KIOSK_WAIT_SECONDS:-30}"
EXTRA_CHROMIUM_FLAGS="${AUTOPOIESIS_CHROMIUM_FLAGS:-}"

mkdir -p "$PROFILE_DIR"

if command -v curl >/dev/null 2>&1; then
  for ((i = 0; i < WAIT_SECONDS; i++)); do
    if curl -fsS --max-time 2 "$URL" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
fi

CHROMIUM_BIN="$(command -v chromium-browser || command -v chromium || true)"
if [[ -z "$CHROMIUM_BIN" ]]; then
  echo "Chromium is not installed." >&2
  exit 1
fi

CHROMIUM_FLAGS=(
  --kiosk
  --noerrdialogs
  --disable-infobars
  --disable-session-crashed-bubble
  --autoplay-policy=no-user-gesture-required
  --check-for-update-interval=31536000
  --user-data-dir="$PROFILE_DIR"
  # Raspberry Pi 3 class GPUs often fail Chromium's GLES3 path. Prefer a
  # deterministic software path over a blank kiosk.
  --disable-gpu
  --disable-gpu-compositing
  --disable-accelerated-2d-canvas
  --use-gl=swiftshader
  --enable-unsafe-swiftshader
)

if [[ -n "$EXTRA_CHROMIUM_FLAGS" ]]; then
  # shellcheck disable=SC2206
  EXTRA_FLAGS=( $EXTRA_CHROMIUM_FLAGS )
  CHROMIUM_FLAGS+=("${EXTRA_FLAGS[@]}")
fi

exec "$CHROMIUM_BIN" \
  "${CHROMIUM_FLAGS[@]}" \
  "$URL"
