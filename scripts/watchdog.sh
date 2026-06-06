#!/usr/bin/env bash
set -euo pipefail

LOCAL_URL="${AUTOPOIESIS_LOCAL_URL:-http://127.0.0.1:3030}"
LAUNCH_URL="${AUTOPOIESIS_LAUNCH_URL:-${LOCAL_URL%/}/launch}"
SETUP_SERVICE="${AUTOPOIESIS_SETUP_SERVICE:-autopoiesis-setup.service}"
KIOSK_SERVICE="${AUTOPOIESIS_KIOSK_SERVICE:-autopoiesis-kiosk.service}"
SYSTEMCTL="${AUTOPOIESIS_SYSTEMCTL_BIN:-systemctl}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WAIT_SECONDS="${AUTOPOIESIS_WATCHDOG_WAIT_SECONDS:-12}"
DRY_RUN="${AUTOPOIESIS_WATCHDOG_DRY_RUN:-0}"

log() {
  printf 'autopoiesis-watchdog: %s\n' "$*"
}

fail() {
  log "failed: $*" >&2
  exit 1
}

run_systemctl() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log "dry-run systemctl $*"
    return 0
  fi
  "$SYSTEMCTL" "$@"
}

require_systemctl() {
  if ! command -v "$SYSTEMCTL" >/dev/null 2>&1; then
    fail "systemctl command not found: $SYSTEMCTL"
  fi
}

check_get() {
  curl -fsS --max-time 4 "$1" >/dev/null
}

check_head() {
  curl -fsSI --max-time 4 "$1" >/dev/null
}

wait_for_get() {
  local url="$1"
  local deadline=$((SECONDS + WAIT_SECONDS))
  while (( SECONDS <= deadline )); do
    if check_get "$url"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_head() {
  local url="$1"
  local deadline=$((SECONDS + WAIT_SECONDS))
  while (( SECONDS <= deadline )); do
    if check_head "$url"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

restart_setup() {
  log "restarting $SETUP_SERVICE"
  run_systemctl restart "$SETUP_SERVICE"
}

restart_kiosk() {
  log "restarting $KIOSK_SERVICE"
  run_systemctl restart "$KIOSK_SERVICE"
}

require_systemctl

HEALTH_URL="${LOCAL_URL%/}/local/health"
if ! check_get "$HEALTH_URL"; then
  log "local health route is unreachable at $HEALTH_URL"
  restart_setup
  wait_for_get "$HEALTH_URL" || fail "local health route stayed unreachable after setup restart"
fi
log "local setup UI is reachable"

if ! check_head "$LAUNCH_URL"; then
  log "launch route is unreachable at $LAUNCH_URL"
  restart_setup
  wait_for_head "$LAUNCH_URL" || fail "launch route stayed unreachable after setup restart"
fi
log "launch route is reachable"

if ! AUTOPOIESIS_LOCAL_URL="$LOCAL_URL" \
     AUTOPOIESIS_LAUNCH_URL="$LAUNCH_URL" \
     AUTOPOIESIS_REQUIRE_KIOSK_PROCESS=1 \
     "$ROOT_DIR/scripts/kiosk-check.sh"; then
  log "kiosk check failed"
  restart_kiosk
  sleep 5
  AUTOPOIESIS_LOCAL_URL="$LOCAL_URL" \
    AUTOPOIESIS_LAUNCH_URL="$LAUNCH_URL" \
    AUTOPOIESIS_REQUIRE_KIOSK_PROCESS=1 \
    "$ROOT_DIR/scripts/kiosk-check.sh" || fail "kiosk check stayed unhealthy after kiosk restart"
fi

log "watchdog check passed"
