#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_URL="${AUTOPOIESIS_LOCAL_URL:-http://localhost:3030}"
LAUNCH_URL="${AUTOPOIESIS_LAUNCH_URL:-${LOCAL_URL%/}/launch}"
REQUIRE_PROCESS="${AUTOPOIESIS_REQUIRE_KIOSK_PROCESS:-0}"
CHECK_HTTP="${AUTOPOIESIS_KIOSK_CHECK_HTTP:-1}"
TMP_PROFILE="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_PROFILE"
}
trap cleanup EXIT

fail() {
  echo "kiosk check failed: $*" >&2
  exit 1
}

if [[ "$CHECK_HTTP" == "1" ]]; then
  curl -fsSI "$LAUNCH_URL" >/dev/null || fail "launch route is not reachable at $LAUNCH_URL"
fi

DRY_RUN_COMMAND="$(
  AUTOPOIESIS_CHROMIUM_BIN="${AUTOPOIESIS_CHROMIUM_BIN:-/usr/bin/chromium}" \
  AUTOPOIESIS_CHROMIUM_PROFILE="$TMP_PROFILE" \
  AUTOPOIESIS_KIOSK_WAIT_SECONDS=0 \
  AUTOPOIESIS_KIOSK_DRY_RUN=1 \
  AUTOPOIESIS_LAUNCH_URL="$LAUNCH_URL" \
    "$ROOT_DIR/scripts/start-kiosk.sh"
)"

for flag in \
  "--kiosk" \
  "--disable-gpu" \
  "--disable-gpu-compositing" \
  "--disable-accelerated-2d-canvas" \
  "--use-gl=swiftshader" \
  "--enable-unsafe-swiftshader"; do
  if ! grep -F -- "$flag" <<<"$DRY_RUN_COMMAND" >/dev/null; then
    fail "launcher dry run is missing $flag"
  fi
done

if ! grep -F -- "$LAUNCH_URL" <<<"$DRY_RUN_COMMAND" >/dev/null; then
  fail "launcher dry run is missing launch URL $LAUNCH_URL"
fi

PROCESS_LINES="$(pgrep -af 'chromium|chromium-browser' || true)"
KIOSK_PROCESS_LINES="$(grep -F -- "$LAUNCH_URL" <<<"$PROCESS_LINES" || true)"

if [[ "$REQUIRE_PROCESS" == "1" && -z "$KIOSK_PROCESS_LINES" ]]; then
  fail "running Chromium kiosk process for $LAUNCH_URL was not found"
fi

if [[ -n "$KIOSK_PROCESS_LINES" ]]; then
  for flag in "--kiosk" "--disable-gpu" "--use-gl=swiftshader"; do
    if ! grep -F -- "$flag" <<<"$KIOSK_PROCESS_LINES" >/dev/null; then
      fail "running kiosk process is missing $flag; restart autopoiesis-kiosk.service"
    fi
  done
fi

echo "kiosk check passed: launcher includes Pi-safe Chromium flags"
if [[ -n "$KIOSK_PROCESS_LINES" ]]; then
  echo "running kiosk process includes required flags"
fi
