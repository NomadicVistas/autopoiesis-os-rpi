#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${AUTOPOIESIS_APP_DIR:-/opt/autopoiesis-os/app}"
INSTALL_DIR="${AUTOPOIESIS_INSTALL_DIR:-/opt/autopoiesis-os}"
DATA_DIR="${AUTOPOIESIS_DATA_DIR:-/var/lib/autopoiesis-os}"
CACHE_DIR="${AUTOPOIESIS_CACHE_DIR:-$DATA_DIR/cache}"
LOG_DIR="${AUTOPOIESIS_LOG_DIR:-/var/log/autopoiesis-os}"
SYSTEMCTL="${AUTOPOIESIS_SYSTEMCTL_BIN:-systemctl}"
ALLOW_NON_ROOT="${AUTOPOIESIS_ALLOW_NON_ROOT_FACTORY_RESET:-0}"
USER_NAME="${AUTOPOIESIS_USER:-frame}"
DRY_RUN=0
RESTART_SERVICES=1
KEEP_SUPPORT_HISTORY=0

usage() {
  cat <<'EOF'
Usage: sudo ./factory-reset.sh [--dry-run] [--no-restart] [--keep-support-history]

Clears local appliance identity, pairing, preferences, content/cache state,
pending commands, and rollout state, then bootstraps a fresh unpaired device.
App code and /var/log/autopoiesis-os are preserved.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=1
      ;;
    --no-restart)
      RESTART_SERVICES=0
      ;;
    --keep-support-history)
      KEEP_SUPPORT_HISTORY=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$(id -u)" -ne 0 && "$ALLOW_NON_ROOT" != "1" ]]; then
  echo "Run with sudo: sudo ./factory-reset.sh" >&2
  exit 1
fi

if [[ ! -x "$APP_DIR/scripts/bootstrap.sh" && -x "$SCRIPT_DIR/scripts/bootstrap.sh" ]]; then
  APP_DIR="$SCRIPT_DIR"
fi

if [[ ! -x "$APP_DIR/scripts/bootstrap.sh" ]]; then
  echo "Cannot find bootstrap.sh under $APP_DIR/scripts" >&2
  exit 2
fi

guard_path() {
  local label="$1"
  local value="$2"
  if [[ -z "$value" || "$value" == "/" ]]; then
    echo "Refusing to reset unsafe $label path: '$value'" >&2
    exit 2
  fi
}

log() {
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "dry-run: $*"
    return
  fi
  mkdir -p "$LOG_DIR"
  echo "$(date -Is) factory-reset: $*" >> "$LOG_DIR/factory-reset.log"
}

run_systemctl() {
  if command -v "$SYSTEMCTL" >/dev/null 2>&1; then
    "$SYSTEMCTL" "$@" || true
  fi
}

delete_file() {
  local file="$1"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "would remove file $file"
  else
    rm -f "$file"
  fi
}

reset_dir() {
  local dir="$1"
  guard_path "directory" "$dir"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "would reset directory $dir"
  else
    rm -rf "$dir"
    install -d "$dir"
  fi
}

chown_runtime_dirs() {
  if [[ "$(id -u)" -ne 0 ]]; then
    return
  fi
  if ! id -u "$USER_NAME" >/dev/null 2>&1; then
    return
  fi
  chown -R "$USER_NAME:$USER_NAME" "$DATA_DIR" "$CACHE_DIR"
  if [[ -d "$INSTALL_DIR/cache" ]]; then
    chown -R "$USER_NAME:$USER_NAME" "$INSTALL_DIR/cache"
  fi
}

guard_path "data" "$DATA_DIR"
guard_path "cache" "$CACHE_DIR"
guard_path "log" "$LOG_DIR"
guard_path "install" "$INSTALL_DIR"

IDENTITY_FILES=(
  device.json
  device-id
  pairing.json
)

RUNTIME_FILES=(
  preferences.json
  state.json
  network.json
  commands.json
  current-broadcast.json
  feed.json
  feed-cache.json
  cache-index.json
  event-cursor.json
  release.json
  release-state.json
  release-rollback.json
)

SUPPORT_HISTORY_FILES=(
  diagnostics.json
  command-audit.json
  delivery-log.json
  release-log.json
)

echo "Factory resetting Autopoiesis OS local appliance state..."
log "starting reset dataDir=$DATA_DIR cacheDir=$CACHE_DIR"

if [[ "$RESTART_SERVICES" == "1" ]]; then
  run_systemctl stop autopoiesis.target
  # Verify target is stopped before proceeding
  if command -v systemctl >/dev/null 2>&1; then
    local target_state
    target_state="$(systemctl is-active autopoiesis.target 2>/dev/null || echo "unknown")"
    if [[ "$target_state" != "inactive" && "$target_state" != "failed" ]]; then
      echo "Warning: autopoiesis.target did not stop cleanly (state: $target_state)" >&2
    fi
  fi
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "would ensure data directory $DATA_DIR"
else
  install -d "$DATA_DIR"
fi

for file in "${IDENTITY_FILES[@]}" "${RUNTIME_FILES[@]}"; do
  delete_file "$DATA_DIR/$file"
done

if [[ "$KEEP_SUPPORT_HISTORY" == "1" ]]; then
  echo "Keeping local support history files."
else
  for file in "${SUPPORT_HISTORY_FILES[@]}"; do
    delete_file "$DATA_DIR/$file"
  done
fi

reset_dir "$CACHE_DIR"
if [[ "$INSTALL_DIR/cache" != "$CACHE_DIR" ]]; then
  reset_dir "$INSTALL_DIR/cache"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "would run $APP_DIR/scripts/bootstrap.sh"
  if [[ "$RESTART_SERVICES" == "1" ]]; then
    echo "would reinstall systemd units and restart setup/kiosk services"
  fi
  echo "Factory reset dry run complete."
  exit 0
fi

"$APP_DIR/scripts/bootstrap.sh"
chown_runtime_dirs

if [[ "$RESTART_SERVICES" == "1" ]]; then
  if [[ -x "$APP_DIR/scripts/install-systemd-units.sh" ]]; then
    AUTOPOIESIS_APP_DIR="$APP_DIR" "$APP_DIR/scripts/install-systemd-units.sh"
  fi
  run_systemctl start autopoiesis.target
  # Verify target is started successfully
  if command -v systemctl >/dev/null 2>&1; then
    local target_state
    target_state="$(systemctl is-active autopoiesis.target 2>/dev/null || echo "unknown")"
    if [[ "$target_state" != "active" ]]; then
      echo "Error: autopoiesis.target failed to start (state: $target_state)" >&2
      echo "Try: systemctl --failed" >&2
      exit 1
    fi
  fi
fi

log "completed reset"
echo "Factory reset complete. Device identity and pairing state have been regenerated locally."

# Post-reset verification
run_post_reset_check() {
  echo ""
  echo "Running post-reset verification..."
  if [[ -x "$INSTALL_DIR/app/scripts/diagnostics.sh" ]]; then
    "$INSTALL_DIR/app/scripts/diagnostics.sh" --quick 2>&1 | tee -a "$LOG_DIR/factory-reset-verification.log" || true
    echo "Verification log written to $LOG_DIR/factory-reset-verification.log"
    # Extract summary line
    if tail -5 "$LOG_DIR/factory-reset-verification.log" | grep -q "Summary:"; then
      tail -5 "$LOG_DIR/factory-reset-verification.log" | grep "Summary:"
    else
      echo "Verification completed (see log for details)."
    fi
  else
    echo "Verification script not found; skipping."
  fi
}
run_post_reset_check
