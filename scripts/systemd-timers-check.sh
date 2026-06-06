#!/usr/bin/env bash
set -euo pipefail

SYSTEMCTL="${AUTOPOIESIS_SYSTEMCTL_BIN:-systemctl}"
ALLOW_UNAVAILABLE="${AUTOPOIESIS_TIMERS_ALLOW_UNAVAILABLE:-0}"

TIMERS=(
  autopoiesis-heartbeat.timer
  autopoiesis-command-executor.timer
  autopoiesis-cache.timer
  autopoiesis-updater.timer
  autopoiesis-watchdog.timer
)

fail() {
  echo "systemd timers check failed: $*" >&2
  exit 1
}

if ! command -v "$SYSTEMCTL" >/dev/null 2>&1; then
  if [[ "$ALLOW_UNAVAILABLE" == "1" ]]; then
    echo "systemd timers unavailable: $SYSTEMCTL not found"
    exit 0
  fi
  fail "$SYSTEMCTL not found"
fi

for timer in "${TIMERS[@]}"; do
  active="$("$SYSTEMCTL" is-active "$timer" 2>&1 || true)"
  enabled="$("$SYSTEMCTL" is-enabled "$timer" 2>&1 || true)"

  if grep -F "System has not been booted" <<<"$active$enabled" >/dev/null; then
    if [[ "$ALLOW_UNAVAILABLE" == "1" ]]; then
      echo "$timer unavailable outside systemd"
      continue
    fi
    fail "systemd is unavailable while checking $timer"
  fi

  [[ "$enabled" == "enabled" ]] || fail "$timer is not enabled: $enabled"
  [[ "$active" == "active" ]] || fail "$timer is not active: $active"
  echo "$timer active enabled"
done

echo "systemd timers check passed"
